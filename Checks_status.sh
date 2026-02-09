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

#######################################
# HELPERS (local parsing)
#######################################
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

# Extract "active|standby" from:
#  - "Failover active"
#  - "Status ACTIVE"
parse_failover() {
  local raw="$1"
  local st=""

  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Failover" {print $2; exit}' | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  if [[ "$st" == "active" || "$st" == "standby" ]]; then
    echo "$st"; return 0
  fi

  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Status" {print $2; exit}' | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  if [[ "$st" == "active" || "$st" == "standby" ]]; then
    echo "$st"; return 0
  fi

  echo "unknown"
}

# Extract sync status from:
# "Status : In Sync"
parse_sync() {
  local raw="$1"
  local s=""
  s="$(printf "%s\n" "$raw" | awk '
      BEGIN{IGNORECASE=1}
      $1=="Status" {
        sub(/^Status[[:space:]]*:[[:space:]]*/,"")
        print
        exit
      }' | sed 's/[[:space:]]\+/ /g' || true)"
  s="$(trim "${s:-}")"
  [[ -n "$s" ]] && echo "$s" || echo "unknown"
}

#######################################
# SSH runner (tmsh interactive)
#######################################
tmsh_batch() {
  local host="$1"
  # On force un TTY (-tt) car tmsh interactive / prompts
  # On envoie des commandes tmsh + quit, et on capture stdout.
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

  # Ne pas casser tout le script si un host fail (malgré set -e)
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

  # Split raw sections (on garde brut en debug)
  SYS_FAIL="$(printf "%s\n" "$RAW" | awk 'BEGIN{p=0} /^show sys failover$/{p=1;next} /^show cm failover-status$/{p=0} p{print}' )"
  CM_FAIL="$(printf "%s\n" "$RAW" | awk 'BEGIN{p=0} /^show cm failover-status$/{p=1;next} /^show cm sync-status$/{p=0} p{print}' )"
  CM_SYNC="$(printf "%s\n" "$RAW" | awk 'BEGIN{p=0} /^show cm sync-status$/{p=1;next} /^list cm device-group one-line$/{p=0} p{print}' )"
  DG_LINE="$(printf "%s\n" "$RAW" | awk 'BEGIN{p=0} /^list cm device-group one-line$/{p=1;next} /^quit$/{p=0} p{print}' )"

  # Determine device-group existence => mode
  DG="$(printf "%s\n" "$DG_LINE" | awk '$1=="cm" && $2=="device-group" {print $3; exit}' || true)"
  DG="$(trim "${DG:-}")"

  MODE="standalone"
  if [[ -n "$DG" ]]; then
    MODE="cluster"
  fi

  # failover state (priority sys failover then cm failover)
  FAILOVER="$(parse_failover "$SYS_FAIL")"
  if [[ "$FAILOVER" == "unknown" ]]; then
    FAILOVER="$(parse_failover "$CM_FAIL")"
  fi

  # sync (only meaningful if cluster)
  SYNC="unknown"
  if [[ "$MODE" == "cluster" ]]; then
    SYNC="$(parse_sync "$CM_SYNC")"
  fi

  # role explicite
  ROLE="ha-unknown"
  if [[ "$MODE" == "standalone" ]]; then
    ROLE="standalone"
    FAILOVER="unknown"
    SYNC="unknown"
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
  echo "failover     : $FAILOVER"
  echo "sync-status  : $SYNC"
  echo "device-group : ${DG:-none}"

  # Écriture TXT
  {
    echo "Host: $HOST"
    echo "  mode         : $MODE"
    echo "  role         : $ROLE"
    echo "  failover     : $FAILOVER"
    echo "  sync-status  : $SYNC"
    echo "  device-group : ${DG:-none}"
    echo "  debug:"
    echo "    show sys failover      : $(printf "%s" "$SYS_FAIL" | tr '\n' '|' )"
    echo "    show cm failover-status: $(printf "%s" "$CM_FAIL" | tr '\n' '|' )"
    echo "    show cm sync-status    : $(printf "%s" "$CM_SYNC" | tr '\n' '|' )"
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