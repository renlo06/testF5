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

ssh_tmsh_batch() {
  local host="$1"
  sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" <<'EOF' 2>/dev/null | tr -d '\r'
show sys failover
show cm failover-status
show cm sync-status
list cm device-group one-line
quit
EOF
}

parse_sync_failover_dg() {
  local raw="$1" line dg members
  line="$(printf "%s\n" "$raw" | awk '
      BEGIN{IGNORECASE=1}
      $1=="cm" && $2=="device-group" && $0 ~ /type[[:space:]]+sync-failover/ {print; exit}
    ' || true)"
  [[ -z "$(trim "${line:-}")" ]] && return 1

  dg="$(printf "%s\n" "$line" | awk '{print $3}' || true)"
  dg="$(trim "${dg:-}")"

  members="$(printf "%s\n" "$line" \
    | sed -n 's/.*devices[[:space:]]*{ *\([^}]*\) *}.*/\1/p' \
    | awk '{print NF}' || true)"
  members="${members:-0}"

  printf "%s|%s\n" "${dg:-none}" "$members"
}

parse_failover() {
  local raw="$1" st=""

  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Failover" {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  if [[ "$st" == "active" || "$st" == "standby" ]]; then
    echo "$st"; return 0
  fi

  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Status" && ($2=="ACTIVE" || $2=="STANDBY") {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  if [[ "$st" == "active" || "$st" == "standby" ]]; then
    echo "$st"; return 0
  fi

  echo "unknown"
}

parse_sync() {
  local raw="$1" s=""
  s="$(printf "%s\n" "$raw" | awk '
      BEGIN{IGNORECASE=1; block=0}
      /^CM::Sync[[:space:]]+Status/ { block=1; next }
      block==1 && /^[A-Z][A-Z0-9_-]*::/ { block=0 }
      block==1 && /Status[[:space:]]*:/ {
        line=$0
        sub(/^.*Status[[:space:]]*:[[:space:]]*/,"",line)
        gsub(/[[:space:]]+/," ",line)
        if(line!=""){ print line; exit }
      }
      block==1 && /^[[:space:]]*Status[[:space:]]+/ {
        line=$0
        sub(/^[[:space:]]*Status[[:space:]]+/,"",line)
        gsub(/[[:space:]]+/," ",line)
        if(line!=""){ print line; exit }
      }
    ' || true)"
  s="$(printf "%s" "$s" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$s" ]] && echo "$s" || echo "unknown"
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

ask_yes_no() {
  local prompt="$1" ans=""
  while true; do
    # read peut échouer (EOF) -> on considère "non"
    if ! read -rp "$prompt [y/n] : " ans; then
      echo
      return 1
    fi

    ans="$(printf "%s" "$ans" | tr '[:upper:]' '[:lower:]')"
    case "$ans" in
      y|yes|o|oui) return 0 ;;
      n|no|non|"") return 1 ;;   # entrée vide => non (évite boucle)
      *) echo "Répondre y/n" ;;
    esac
  done
}

config_sync_to_group() {
  local host="$1" dg="$2"
  sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" <<EOF 2>/dev/null | tr -d '\r'
run cm config-sync to-group ${dg}
show cm sync-status
quit
EOF
}

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0

echo
echo "🔎 Check HA + proposition de synchronisation (uniquement sur ACTIVE)"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(printf "%s" "$LINE" | tr -d '\r' | awk '{$1=$1;print}')
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  COUNT=$((COUNT+1))
  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  RAW="$(ssh_tmsh_batch "$HOST" || true)"
  if [[ -z "$(trim "${RAW:-}")" ]]; then
    echo "❌ Impossible de récupérer l'état HA"
    echo
    continue
  fi

  DG_INFO="$(parse_sync_failover_dg "$RAW" || true)"
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
    FAILOVER="$(parse_failover "$RAW")"
    SYNC="$(parse_sync "$RAW")"
    case "$FAILOVER" in
      active) ROLE="ha-active" ;;
      standby) ROLE="ha-standby" ;;
      *) ROLE="ha-unknown" ;;
    esac
  fi

  SYNC_NORM="$(norm_sync "$SYNC")"

  echo "mode         : $MODE"
  echo "role         : $ROLE"
  echo "device-group : $DG"
  echo "members      : $MEMBERS"
  echo "failover     : $FAILOVER"
  echo "sync-status  : $SYNC  ($SYNC_NORM)"

  # ✅ Proposer la synchro UNIQUEMENT sur ACTIVE + out-of-sync
  if [[ "$MODE" == "cluster" && "$DG" != "none" && "$SYNC_NORM" == "out-of-sync" ]]; then
    echo
    if [[ "$ROLE" != "ha-active" ]]; then
      echo "ℹ️  Non proposé: l'équipement n'est pas ACTIVE."
    else
      echo "⚠️  Device-group non synchronisé."
      if ask_yes_no "➡️  Lancer 'run cm config-sync to-group ${DG}' sur ${HOST} ?"; then
        echo "⏳ Lancement config-sync..."
        RES="$(config_sync_to_group "$HOST" "$DG" || true)"
        echo "✅ Commande envoyée. Nouveau sync-status (si visible) :"
        echo "--------------------------------------"
        echo "$RES" | sed -n '1,120p'
        echo "--------------------------------------"
      else
        echo "⏭️  Synchronisation ignorée."
      fi
    fi
  fi

  echo
done < "$DEVICES_FILE"

echo "🏁 Terminé"
