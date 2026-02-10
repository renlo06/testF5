#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"
SSH_OPTS=(-tt -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o LogLevel=Error)

#######################################
# PRECHECKS
#######################################
for bin in ssh sshpass awk sed grep wc tr; do
  command -v "$bin" >/dev/null || { echo "❌ $bin requis"; exit 1; }
done
[[ -f "$DEVICES_FILE" ]] || { echo "❌ Fichier équipements introuvable : $DEVICES_FILE"; exit 1; }

#######################################
# INPUTS
#######################################
read -rp "Utilisateur SSH (compte qui arrive en tmsh): " SSH_USER
read -s -rp "Mot de passe SSH: " SSH_PASS
echo

#######################################
# HELPERS
#######################################
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

ssh_tmsh_cmd() {
  local host="$1"
  local cmd="$2"
  sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$cmd" 2>/dev/null \
    | tr -d '\r'
}

ask_yes_no() {
  local prompt="$1" ans=""
  while true; do
    # Si read échoue (EOF) => non
    if ! read -rp "$prompt [y/n] : " ans; then
      echo
      return 1
    fi
    ans="$(printf "%s" "$ans" | tr '[:upper:]' '[:lower:]')"
    case "$ans" in
      y|yes|o|oui) return 0 ;;
      n|no|non|"") return 1 ;;   # entrée vide => non (anti boucle)
      *) echo "Répondre y/n" ;;
    esac
  done
}

# --- FAILOVER ---
parse_failover_from_raw() {
  local raw="$1" st=""

  # "Failover active"
  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Failover" {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  [[ "$st" == "active" || "$st" == "standby" ]] && { echo "$st"; return 0; }

  # "Status ACTIVE" (CM::Failover status)
  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Status" && ($2=="ACTIVE" || $2=="STANDBY") {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  [[ "$st" == "active" || "$st" == "standby" ]] && { echo "$st"; return 0; }

  echo "unknown"
}

get_failover_state() {
  local host="$1" raw st
  raw="$(ssh_tmsh_cmd "$host" 'show sys failover' || true)"
  st="$(parse_failover_from_raw "$raw")"
  if [[ "$st" != "unknown" ]]; then
    echo "$st"; return 0
  fi
  raw="$(ssh_tmsh_cmd "$host" 'show cm failover-status' || true)"
  parse_failover_from_raw "$raw"
}

# --- SYNC STATUS ---
parse_sync_from_raw() {
  local raw="$1" s=""
  # Ton format: "Status In Sync" (sans :)
  s="$(printf "%s\n" "$raw" | awk '
      BEGIN{IGNORECASE=1; block=0}
      /^CM::Sync[[:space:]]+Status/ { block=1; next }
      block==1 && /^[A-Z][A-Z0-9_-]*::/ { block=0 }
      block==1 && /^[[:space:]]*Status[[:space:]]+/ {
        line=$0
        sub(/^[[:space:]]*Status[[:space:]]+/,"",line)
        gsub(/[[:space:]]+/," ",line)
        if(line!=""){ print line; exit }
      }
      block==1 && /Status[[:space:]]*:/ {
        line=$0
        sub(/^.*Status[[:space:]]*:[[:space:]]*/,"",line)
        gsub(/[[:space:]]+/," ",line)
        if(line!=""){ print line; exit }
      }
    ' || true)"
  s="$(printf "%s" "$s" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$s" ]] && echo "$s" || echo "unknown"
}

get_sync_status() {
  local host="$1" raw
  raw="$(ssh_tmsh_cmd "$host" 'show cm sync-status' || true)"
  parse_sync_from_raw "$raw"
}

norm_sync() {
  local s
  s="$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')"
  if echo "$s" | grep -q "in sync"; then
    echo "in-sync"
  elif [[ "$s" == "unknown" || -z "$s" ]]; then
    echo "unknown"
  else
    echo "out-of-sync"
  fi
}

# --- DEVICE-GROUP (robuste via list multi-lignes) ---
# Retourne "DG_NAME|MEMBERS" du premier device-group "type sync-failover"
get_sync_failover_dg() {
  local host="$1" raw
  raw="$(ssh_tmsh_cmd "$host" 'list cm device-group' || true)"

  # Parse bloc "cm device-group <name> { ... }"
  # Cherche type sync-failover et compte les devices dans devices { ... }
  printf "%s\n" "$raw" | awk '
    BEGIN{IGNORECASE=1; inblk=0; isha=0; name=""; devs=""}
    $1=="cm" && $2=="device-group" && $4=="{" {
      inblk=1; isha=0; devs=""; name=$3; next
    }
    inblk==1 {
      if ($0 ~ /type[[:space:]]+sync-failover/) { isha=1 }
      # collect devices line(s)
      if ($0 ~ /devices[[:space:]]*{/) {
    # accumulate everything from "devices {" to matching "}"
        devs = devs " " $0
      } else if (devs != "" && $0 !~ /}/) {
        devs = devs " " $0
      } else if (devs != "" && $0 ~ /}/) {
        devs = devs " " $0
      }
      if ($1=="}") {
        if (isha==1) {
          # count /Common/xxx tokens inside devices content
          n=0
          while (match(devs, /\/[^[:space:]}]+/)) {
            n++
            devs=substr(devs, RSTART+RLENGTH)
          }
          if (n==0) n=0
          printf "%s|%d\n", name, n
          exit
        }
        inblk=0
      }
    }
  ' || true
}

# --- CONFIG-SYNC ---
config_sync_to_group() {
  local host="$1" dg="$2"
  ssh_tmsh_cmd "$host" "run cm config-sync to-group ${dg}"
  # re-check sync status after
  ssh_tmsh_cmd "$host" "show cm sync-status"
}

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0

echo
echo "🔎 Check HA + proposition de synchronisation (ACTIVE + out-of-sync)"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(printf "%s" "$LINE" | tr -d '\r' | awk '{$1=$1;print}')
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  COUNT=$((COUNT+1))
  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  DG_INFO="$(get_sync_failover_dg "$HOST" || true)"
  DG="none"; MEMBERS="0"; MODE="standalone"

  if [[ -n "$(trim "${DG_INFO:-}")" ]]; then
    DG="${DG_INFO%%|*}"
    MEMBERS="${DG_INFO##*|}"
    MEMBERS="$(trim "$MEMBERS")"
    if [[ "${MEMBERS:-0}" =~ ^[0-9]+$ ]] && (( MEMBERS >= 2 )); then
      MODE="cluster"
    fi
  fi

  FAILOVER="unknown"
  SYNC="unknown"
  ROLE="standalone"

  if [[ "$MODE" == "cluster" ]]; then
    FAILOVER="$(get_failover_state "$HOST")"
    SYNC="$(get_sync_status "$HOST")"
    case "$FAILOVER" in
      active)  ROLE="ha-active" ;;
      standby) ROLE="ha-standby" ;;
      *)       ROLE="ha-unknown" ;;
    esac
  fi

  SYNC_NORM="$(norm_sync "$SYNC")"

  echo "mode         : $MODE"
  echo "role         : $ROLE"
  echo "device-group : $DG"
  echo "members      : $MEMBERS"
  echo "failover     : $FAILOVER"
  echo "sync-status  : $SYNC  ($SYNC_NORM)"

  # ✅ Proposer la synchro UNIQUEMENT si ACTIVE + out-of-sync + DG valide
  if [[ "$MODE" == "cluster" && "$DG" != "none" && "$ROLE" == "ha-active" && "$SYNC_NORM" == "out-of-sync" ]]; then
    echo
    echo "⚠️  Device-group non synchronisé."
    if ask_yes_no "➡️  Lancer 'run cm config-sync to-group ${DG}' sur ${HOST} ?"; then
      echo "⏳ Lancement config-sync..."
      RES="$(config_sync_to_group "$HOST" "$DG" || true)"
      echo "✅ Commande envoyée. Sortie:"
      echo "--------------------------------------"
      echo "$RES" | sed -n '1,160p'
      echo "--------------------------------------"
    else
      echo "⏭️  Synchronisation ignorée."
    fi
  fi

  echo
done < "$DEVICES_FILE"

echo "🏁 Terminé"
