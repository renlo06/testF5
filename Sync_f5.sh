#!/usr/bin/env bash
set -uo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"
CURL_BASE=(-k -sS)         # insecure + silent, errors still shown with -S
TIMEOUTS=(--connect-timeout 10 --max-time 30)

#######################################
# PRECHECKS
#######################################
for bin in curl jq awk sed grep wc tr; do
  command -v "$bin" >/dev/null || { echo "❌ $bin requis"; exit 1; }
done
[[ -f "$DEVICES_FILE" ]] || { echo "❌ Fichier équipements introuvable : $DEVICES_FILE"; exit 1; }

#######################################
# INPUTS
#######################################
read -rp "Utilisateur API (REST, ex: admin): " API_USER
read -s -rp "Mot de passe API (REST): " API_PASS
echo

AUTH=(-u "${API_USER}:${API_PASS}")

#######################################
# HELPERS
#######################################
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
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
      n|no|non|"") return 1 ;;
      *) echo "Répondre y/n" ;;
    esac
  done
}

api_get() {
  local host="$1" path="$2"
  curl "${CURL_BASE[@]}" "${TIMEOUTS[@]}" "${AUTH[@]}" \
    "https://${host}${path}"
}

api_bash_tmsh() {
  # Exécute une commande tmsh via util bash, renvoie stdout (champ .commandResult)
  local host="$1" tmsh_cmd="$2"

  # Important : -c 'tmsh ...' dans util bash
  # On évite les quotes difficiles : on passe tmsh_cmd tel quel dans une chaîne -c.
  local payload
  payload="$(jq -n --arg cmd "tmsh ${tmsh_cmd}" \
    '{command:"run", utilCmdArgs:("-c " + $cmd)}')"

  curl "${CURL_BASE[@]}" "${TIMEOUTS[@]}" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -X POST "https://${host}/mgmt/tm/util/bash" \
    -d "$payload" \
  | jq -r '.commandResult // empty'
}

# Récupère le premier device-group type sync-failover + nb devices
get_sync_failover_dg() {
  local host="$1" json name members

  json="$(api_get "$host" '/mgmt/tm/cm/device-group?$select=name,type,devices' 2>/dev/null || true)"
  [[ -z "$(trim "${json:-}")" ]] && return 1

  # 1er DG dont type == "sync-failover"
  name="$(jq -r '.items[]? | select(.type=="sync-failover") | .name' <<<"$json" | head -n1)"
  name="$(trim "${name:-}")"
  [[ -z "$name" || "$name" == "null" ]] && return 1

  members="$(jq -r --arg n "$name" '
      (.items[]? | select(.name==$n) | (.devices // [] ) | length) // 0
    ' <<<"$json" | head -n1)"
  members="$(trim "${members:-0}")"
  printf "%s|%s\n" "$name" "$members"
}

parse_failover() {
  # attend une sortie tmsh type:
  # "Failover active"
  # ou "Status ACTIVE"
  local raw="$1" st=""

  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Failover" {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  [[ "$st" == "active" || "$st" == "standby" ]] && { echo "$st"; return 0; }

  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Status" && ($2=="ACTIVE" || $2=="STANDBY") {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  [[ "$st" == "active" || "$st" == "standby" ]] && { echo "$st"; return 0; }

  echo "unknown"
}

parse_sync() {
  # ton format:
  # "Status In Sync"
  local raw="$1" s=""
  s="$(printf "%s\n" "$raw" | awk '
      BEGIN{IGNORECASE=1}
      /^[[:space:]]*Status[[:space:]]+/ {
        sub(/^[[:space:]]*Status[[:space:]]+/,"")
        gsub(/[[:space:]]+/," ")
        print
        exit
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

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0

echo
echo "🔎 Check HA via API (REST) + proposition config-sync"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST="$(printf "%s" "$LINE" | tr -d '\r' | awk '{$1=$1;print}')"
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  COUNT=$((COUNT+1))
  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  # 1) Device-group HA
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
  ROLE="standalone"
  SYNC="unknown"
  SYNC_NORM="unknown"

  if [[ "$MODE" == "cluster" ]]; then
    # 2) Failover (priorité show sys failover, fallback cm failover-status)
    SYS_FAIL_RAW="$(api_bash_tmsh "$HOST" 'show sys failover' || true)"
    FAILOVER="$(parse_failover "$SYS_FAIL_RAW")"
    if [[ "$FAILOVER" == "unknown" ]]; then
      CM_FAIL_RAW="$(api_bash_tmsh "$HOST" 'show cm failover-status' || true)"
      FAILOVER="$(parse_failover "$CM_FAIL_RAW")"
    fi

    case "$FAILOVER" in
      active) ROLE="ha-active" ;;
      standby) ROLE="ha-standby" ;;
      *) ROLE="ha-unknown" ;;
    esac

    # 3) Sync-status
    SYNC_RAW="$(api_bash_tmsh "$HOST" 'show cm sync-status' || true)"
    SYNC="$(parse_sync "$SYNC_RAW")"
    SYNC_NORM="$(norm_sync "$SYNC")"
  fi

  echo "mode         : $MODE"
  echo "role         : $ROLE"
  echo "device-group : $DG"
  echo "members      : $MEMBERS"
  echo "failover     : $FAILOVER"
  echo "sync-status  : $SYNC  ($SYNC_NORM)"

  # Proposition synchro
  if [[ "$MODE" == "cluster" && "$DG" != "none" && "$ROLE" == "ha-active" && "$SYNC_NORM" == "out-of-sync" ]]; then
    echo
    echo "⚠️  Device-group non synchronisé."
    if ask_yes_no "➡️  Lancer 'run cm config-sync to-group ${DG}' sur ${HOST} ?"; then
      echo "⏳ Lancement config-sync..."
      _="$(api_bash_tmsh "$HOST" "run cm config-sync to-group ${DG}" || true)"
      # Re-check sync
      SYNC_RAW="$(api_bash_tmsh "$HOST" 'show cm sync-status' || true)"
      SYNC="$(parse_sync "$SYNC_RAW")"
      SYNC_NORM="$(norm_sync "$SYNC")"
      echo "✅ Nouveau sync-status : $SYNC ($SYNC_NORM)"
    else
      echo "⏭️  Synchronisation ignorée."
    fi
  fi

  echo
done < "$DEVICES_FILE"

echo "🏁 Terminé"
