#!/usr/bin/env bash
set -uo pipefail

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

# Exécute une commande (dans le shell tmsh du compte)
# Retourne stdout, et le code retour SSH via $?
ssh_tmsh() {
  local host="$1"
  local cmd="$2"
  sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$cmd" 2>/dev/null \
    | tr -d '\r'
}

ask_yes_no() {
  local prompt="$1" ans=""
  while true; do
    if ! read -rp "$prompt [y/n] : " ans; then
      echo
      return 1
    fi
    ans="$(printf "%s" "$ans" | tr '[:upper:]' '[:lower:]')"
    case "$ans" in
      y|yes|o|oui) return 0 ;;
      n|no|non|"") return 1 ;;   # entrée vide => non
      *) echo "Répondre y/n" ;;
    esac
  done
}

parse_failover() {
  local raw="$1" st=""

  # Format : "Failover active"
  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Failover" {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  [[ "$st" == "active" || "$st" == "standby" ]] && { echo "$st"; return 0; }

  # Format : "Status ACTIVE"
  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Status" && ($2=="ACTIVE" || $2=="STANDBY") {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  [[ "$st" == "active" || "$st" == "standby" ]] && { echo "$st"; return 0; }

  echo "unknown"
}

# Tu as : CM::Sync Status ... "Status In Sync"
parse_sync() {
  local raw="$1" s=""
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

# Récupère le 1er device-group de type sync-failover + nombre de devices
# Plus robuste que one-line (pas sensible au wrap)
get_sync_failover_dg() {
  local raw="$1"
  printf "%s\n" "$raw" | awk '
    BEGIN{IGNORECASE=1; inblk=0; isha=0; name=""; devcount=0; indev=0}

    $1=="cm" && $2=="device-group" && $4=="{" {
      inblk=1; isha=0; name=$3; devcount=0; indev=0; next
    }

    inblk==1 {
      if ($0 ~ /type[[:space:]]+sync-failover/) isha=1

      # devices { ... } peut être multi-lignes
      if ($0 ~ /^[[:space:]]*devices[[:space:]]*{/) { indev=1; next }
      if (indev==1 && $1=="}") { indev=0 }  # fin devices {}

      if (indev==1) {
        # compte /Common/deviceX ou /Partition/deviceX
        for (i=1;i<=NF;i++) if ($i ~ /^\/[^[:space:]}]+$/) devcount++
      }

      if ($1=="}") {
        if (isha==1) {
          printf "%s|%d\n", name, devcount
          exit
        }
        inblk=0
      }
    }
  '
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

  # 1) device-group (list multi-lignes)
  DG_RAW=""
  DG_RC=0
  set +e
  DG_RAW="$(ssh_tmsh "$HOST" 'list cm device-group')"
  DG_RC=$?
  set -e

  if [[ $DG_RC -ne 0 || -z "$(trim "${DG_RAW:-}")" ]]; then
    echo "❌ Impossible de lire 'list cm device-group' (SSH/TMSH KO)"
    echo
    continue
  fi

  DG_INFO="$(get_sync_failover_dg "$DG_RAW" || true)"
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
    # 2) failover
    SYS_FAIL=""
    CM_FAIL=""
    set +e
    SYS_FAIL="$(ssh_tmsh "$HOST" 'show sys failover')"
    SYS_RC=$?
    set -e
    if [[ $SYS_RC -eq 0 && -n "$(trim "${SYS_FAIL:-}")" ]]; then
      FAILOVER="$(parse_failover "$SYS_FAIL")"
    else
      set +e
      CM_FAIL="$(ssh_tmsh "$HOST" 'show cm failover-status')"
      CM_RC=$?
      set -e
      [[ $CM_RC -eq 0 ]] && FAILOVER="$(parse_failover "$CM_FAIL")"
    fi

    case "$FAILOVER" in
      active) ROLE="ha-active" ;;
      standby) ROLE="ha-standby" ;;
      *) ROLE="ha-unknown" ;;
    esac

    # 3) sync-status
    SYNC_RAW=""
    set +e
    SYNC_RAW="$(ssh_tmsh "$HOST" 'show cm sync-status')"
    SYNC_RC=$?
    set -e
    if [[ $SYNC_RC -eq 0 && -n "$(trim "${SYNC_RAW:-}")" ]]; then
      SYNC="$(parse_sync "$SYNC_RAW")"
    else
      SYNC="unknown"
    fi
  fi

  SYNC_NORM="$(norm_sync "$SYNC")"

  echo "mode         : $MODE"
  echo "role         : $ROLE"
  echo "device-group : $DG"
  echo "members      : $MEMBERS"
  echo "failover     : $FAILOVER"
  echo "sync-status  : $SYNC  ($SYNC_NORM)"

  # ✅ Proposition synchro uniquement ACTIVE + out-of-sync + DG valide
  if [[ "$MODE" == "cluster" && "$DG" != "none" && "$ROLE" == "ha-active" && "$SYNC_NORM" == "out-of-sync" ]]; then
    echo
    echo "⚠️  Device-group non synchronisé."
    if ask_yes_no "➡️  Lancer 'run cm config-sync to-group ${DG}' sur ${HOST} ?"; then
      echo "⏳ Lancement config-sync..."
      set +e
      RES1="$(ssh_tmsh "$HOST" "run cm config-sync to-group ${DG}")"
      RES2="$(ssh_tmsh "$HOST" "show cm sync-status")"
      set -e
      echo "✅ Commande envoyée."
      echo "Nouveau sync-status :"
      echo "--------------------------------------"
      echo "$RES2" | sed -n '1,120p'
      echo "--------------------------------------"
    else
      echo "⏭️  Synchronisation ignorée."
    fi
  fi

  echo
done < "$DEVICES_FILE"

echo "🏁 Terminé"
