#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"
BASE_DIR="./checks"
TS=$(date +%Y%m%d-%H%M%S)

#######################################
# PRECHECKS
#######################################
for bin in ssh sshpass awk sed date mkdir wc tr grep; do
  command -v "$bin" >/dev/null || { echo "❌ $bin requis"; exit 1; }
done

[[ -f "$DEVICES_FILE" ]] || { echo "❌ Fichier équipements introuvable : $DEVICES_FILE"; exit 1; }

RUN_DIR="${BASE_DIR}/${TS}"
mkdir -p "$RUN_DIR"
TXT_OUT="${RUN_DIR}/ha_status.txt"
: > "$TXT_OUT"

#######################################
# INPUTS
#######################################
read -rp "Utilisateur SSH (compte qui arrive en tmsh): " SSH_USER
read -s -rp "Mot de passe SSH: " SSH_PASS
echo

echo "📁 Run dir : $RUN_DIR"
echo "📝 TXT     : $TXT_OUT"
echo

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

#######################################
# SSH runner (tmsh interactive)
#######################################
tmsh_batch() {
  local host="$1"
  sshpass -p "$SSH_PASS" ssh -tt \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o LogLevel=Error \
    "${SSH_USER}@${host}" <<'EOF' 2>/dev/null
show sys failover
show cm failover-status
show cm sync-status
list cm device-group one-line
quit
EOF
}

#######################################
# PARSERS (sur sortie brute)
#######################################
parse_failover() {
  local raw="$1" st=""

  # "Failover active"
  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Failover" {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  if [[ "$st" == "active" || "$st" == "standby" ]]; then
    echo "$st"; return 0
  fi

  # "Status ACTIVE"
  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Status" && ($2=="ACTIVE" || $2=="STANDBY") {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  if [[ "$st" == "active" || "$st" == "standby" ]]; then
    echo "$st"; return 0
  fi

  echo "unknown"
}

# ✅ Ton format: "Status In Sync" (sans :)
# + fallback "Status: In Sync" si jamais un device diffère
parse_sync() {
  local raw="$1" s=""

  s="$(printf "%s\n" "$raw" | awk '
      BEGIN{IGNORECASE=1}
      /Status[[:space:]]*:/ {
        sub(/^.*Status[[:space:]]*:[[:space:]]*/,"")
        gsub(/[[:space:]]+/," ")
        print
        exit
      }
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

# Device-group HA : prendre un DG de type sync-failover
# Retourne: "DG_NAME|MEMBERS_COUNT" ou vide
parse_sync_failover_dg() {
  local raw="$1"
  local line dg members

  line="$(printf "%s\n" "$raw" | awk '
      BEGIN{IGNORECASE=1}
      $1=="cm" && $2=="device-group" && $0 ~ /type[[:space:]]+sync-failover/ {print; exit}
    ' || true)"
  [[ -z "$(trim "${line:-}")" ]] && return 1

  dg="$(printf "%s\n" "$line" | awk '{print $3}' || true)"
  dg="$(trim "${dg:-}")"

  # Compte les devices dans "devices { ... }" sur la ligne one-line
  members="$(printf "%s\n" "$line" | sed -n 's/.*devices[[:space:]]*{ *\([^}]*\) *}.*/\1/p' \
            | awk '{print NF}' || true)"
  members="${members:-0}"

  printf "%s|%s\n" "${dg:-none}" "$members"
}

#######################################
# MAIN LOOP
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0
FAILS=0

{
  echo "Run: $TS"
  echo
} >> "$TXT_OUT"

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(printf "%s" "$LINE" | tr -d '\r' | awk '{$1=$1;print}')
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  COUNT=$((COUNT+1))
  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  set +e
  RAW="$(tmsh_batch "$HOST")"
  RC=$?
  set -e

  if [[ $RC -ne 0 || -z "$(trim "${RAW:-}")" ]]; then
    echo "❌ Échec récupération infos HA (SSH/TMSH) : $HOST"
    FAILS=$((FAILS+1))
    {
      echo "Host: $HOST"
      echo "  role : error"
      echo "  ERROR: SSH/TMSH failed or empty output"
      echo
    } >> "$TXT_OUT"
    echo
    continue
  fi

  # HA detection : DG sync-failover + members>=2 => cluster/HA
  DG_INFO="$(parse_sync_failover_dg "$RAW" || true)"
  DG="none"
  MEMBERS="0"
  MODE="standalone"

  if [[ -n "$(trim "${DG_INFO:-}")" ]]; then
    DG="${DG_INFO%%|*}"
    MEMBERS="${DG_INFO##*|}"
    MEMBERS="$(trim "$MEMBERS")"
    if [[ "${MEMBERS:-0}" =~ ^[0-9]+$ ]] && (( MEMBERS >= 2 )); then
      MODE="cluster"
    else
      MODE="standalone"
    fi
  fi

  FAILOVER="$(parse_failover "$RAW")"
  SYNC="unknown"
  if [[ "$MODE" == "cluster" ]]; then
    SYNC="$(parse_sync "$RAW")"
  else
    FAILOVER="unknown"
    SYNC="unknown"
  fi

  ROLE="ha-unknown"
  if [[ "$MODE" == "standalone" ]]; then
    ROLE="standalone"
  else
    case "$FAILOVER" in
      active)  ROLE="ha-active" ;;
      standby) ROLE="ha-standby" ;;
      *)       ROLE="ha-unknown" ;;
    esac
  fi

  # Affichage terminal
  echo "mode         : $MODE"
  echo "role         : $ROLE"
  echo "device-group : $DG"
  echo "members      : $MEMBERS"
  echo "failover     : $FAILOVER"
  echo "sync-status  : $SYNC"

  # TXT
  {
    echo "Host: $HOST"
    echo "  mode         : $MODE"
    echo "  role         : $ROLE"
    echo "  device-group : $DG"
    echo "  members      : $MEMBERS"
    echo "  failover     : $FAILOVER"
    echo "  sync-status  : $SYNC"
    echo
  } >> "$TXT_OUT"

  echo
done < "$DEVICES_FILE"

echo "======================================"
echo "🏁 Terminé"
echo "📁 Run dir : $RUN_DIR"
echo "📝 TXT     : $TXT_OUT"
echo "❌ Échecs  : $FAILS"
echo "======================================"

(( FAILS == 0 )) || exit 1