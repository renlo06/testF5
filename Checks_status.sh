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
for bin in ssh sshpass awk sed sort date mkdir wc tr; do
  command -v "$bin" >/dev/null || { echo "❌ $bin requis"; exit 1; }
done

[[ -f "$DEVICES_FILE" ]] || { echo "❌ Fichier équipements introuvable : $DEVICES_FILE"; exit 1; }

#######################################
# INPUTS
#######################################
read -rp "Utilisateur SSH (compte qui arrive en tmsh): " SSH_USER
read -s -rp "Mot de passe SSH: " SSH_PASS
echo

RUN_DIR="${BASE_DIR}/${TS}"
mkdir -p "$RUN_DIR"

CSV_OUT="${RUN_DIR}/ha_status.csv"
TXT_OUT="${RUN_DIR}/ha_status.txt"

echo "host,mode,role,device_group,members_count,failover_state,sync_status" > "$CSV_OUT"
{
  echo "Run: $TS"
  echo
} > "$TXT_OUT"

echo "📁 Run dir : $RUN_DIR"
echo "📄 CSV     : $CSV_OUT"
echo "📝 TXT     : $TXT_OUT"
echo

#######################################
# REMOTE LOGIC
#######################################
REMOTE_BASH=$(cat <<'RB'
set -euo pipefail

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

HOST="$(hostname 2>/dev/null || echo UNKNOWN)"

DG_LINE="$(tmsh -c "list cm device-group one-line" 2>/dev/null | awk '$1=="cm" && $2=="device-group" {print; exit}' || true)"
DG="$(printf "%s" "$DG_LINE" | awk '{print $3}' || true)"
DG="$(trim "${DG:-}")"

MODE="standalone"
MEMBERS="0"
FAILOVER="unknown"
SYNC="unknown"

if [[ -n "${DG:-}" ]]; then
  MODE="cluster"

  DG_FULL="$(tmsh -c "list cm device-group ${DG} one-line" 2>/dev/null || true)"
  MEMBERS="$(printf "%s\n" "$DG_FULL" | grep -oE '/[^[:space:]}]+' | wc -l | awk '{print $1}')"
  MEMBERS="${MEMBERS:-0}"

  FO_RAW="$(tmsh -c "show cm failover-status" 2>/dev/null || true)"

  FAILOVER="$(printf "%s\n" "$FO_RAW" \
    | awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Status[[:space:]]*:/ {print $NF; exit}' \
    | tr '[:upper:]' '[:lower:]' || true)"

  if [[ -z "${FAILOVER:-}" ]]; then
    FAILOVER="$(printf "%s\n" "$FO_RAW" \
      | awk 'BEGIN{IGNORECASE=1} /active/ {print "active"; exit} /standby/ {print "standby"; exit}' || true)"
  fi

  FAILOVER="$(trim "${FAILOVER:-unknown}")"
  [[ "$FAILOVER" == "active" || "$FAILOVER" == "standby" ]] || FAILOVER="unknown"

  SY_RAW="$(tmsh -c "show cm sync-status" 2>/dev/null || true)"
  SYNC="$(printf "%s\n" "$SY_RAW" \
    | awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Status[[:space:]]*:/ {sub(/^[^:]*:[[:space:]]*/,""); print; exit}' \
    | sed 's/[[:space:]]\+/ /g' || true)"
  SYNC="$(trim "${SYNC:-unknown}")"
  [[ -n "$SYNC" ]] || SYNC="unknown"
fi

printf "HOST=%s\n" "$HOST"
printf "MODE=%s\n" "$MODE"
printf "DG=%s\n" "${DG:-none}"
printf "MEMBERS=%s\n" "$MEMBERS"
printf "FAILOVER=%s\n" "$FAILOVER"
printf "SYNC=%s\n" "$SYNC"
RB
)

#######################################
# MAIN LOOP
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0
FAILS=0

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  TARGET=$(printf "%s" "$LINE" | tr -d '\r' | xargs)
  [[ -z "$TARGET" || "$TARGET" =~ ^# ]] && continue

  COUNT=$((COUNT+1))
  echo "➡️  [$COUNT/$TOTAL] $TARGET"

  OUT=""
  if OUT=$(sshpass -p "$SSH_PASS" ssh -T \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o LogLevel=Error \
      "${SSH_USER}@${TARGET}" "run util bash -s" <<<"$REMOTE_BASH" 2>/dev/null); then

    MODE=$(printf "%s\n" "$OUT" | awk -F= '$1=="MODE"{print $2}')
    DG=$(printf "%s\n" "$OUT" | awk -F= '$1=="DG"{print $2}')
    MEMBERS=$(printf "%s\n" "$OUT" | awk -F= '$1=="MEMBERS"{print $2}')
    FAILOVER=$(printf "%s\n" "$OUT" | awk -F= '$1=="FAILOVER"{print $2}')
    SYNC=$(printf "%s\n" "$OUT" | awk -F= '$1=="SYNC"{print $2}')

    # role explicite
    ROLE="ha-unknown"
    if [[ "${MODE:-}" == "standalone" ]]; then
      ROLE="standalone"
    else
      case "${FAILOVER:-unknown}" in
        active)  ROLE="ha-active" ;;
        standby) ROLE="ha-standby" ;;
        *)       ROLE="ha-unknown" ;;
      esac
    fi

    printf "%s,%s,%s,%s,%s,%s,%s\n" \
      "${TARGET}" "${MODE:-unknown}" "${ROLE}" "${DG:-none}" "${MEMBERS:-0}" "${FAILOVER:-unknown}" "${SYNC:-unknown}" \
      >> "$CSV_OUT"

    {
      echo "Host: ${TARGET}"
      echo "  mode          : ${MODE:-unknown}"
      echo "  role          : ${ROLE}"
      echo "  device-group  : ${DG:-none}"
      echo "  members_count : ${MEMBERS:-0}"
      echo "  failover      : ${FAILOVER:-unknown}"
      echo "  sync-status   : ${SYNC:-unknown}"
      echo
    } >> "$TXT_OUT"

  else
    echo "❌ Échec SSH/TMSH : $TARGET"
    FAILS=$((FAILS+1))
    printf "%s,%s,%s,%s,%s,%s,%s\n" "$TARGET" "error" "error" "none" "0" "unknown" "unknown" >> "$CSV_OUT"
    {
      echo "Host: ${TARGET}"
      echo "  role : error"
      echo "  ERROR: SSH/TMSH failed"
      echo
    } >> "$TXT_OUT"
  fi
done < "$DEVICES_FILE"

echo
echo "🏁 Terminé"
echo "📁 Run dir : $RUN_DIR"
echo "❌ Échecs  : $FAILS"
echo "📄 CSV     : $CSV_OUT"
echo "📝 TXT     : $TXT_OUT"

(( FAILS == 0 )) || exit 1