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
for bin in ssh sshpass awk sed date mkdir wc tr; do
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

TXT_OUT="${RUN_DIR}/ha_status.txt"
: > "$TXT_OUT"

echo "📁 Run dir : $RUN_DIR"
echo "📝 TXT     : $TXT_OUT"
echo

#######################################
# REMOTE LOGIC (prints key=value lines)
#######################################
REMOTE_BASH=$(cat <<'RB'
set -euo pipefail

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

# --- DG / members ---
get_device_group() {
  tmsh -c "list cm device-group one-line" 2>/dev/null \
  | awk '$1=="cm" && $2=="device-group" {print $3; exit}' || true
}

get_members_count() {
  local dg="$1"
  local line
  line="$(tmsh -c "list cm device-group ${dg} one-line" 2>/dev/null || true)"
  printf "%s\n" "$line" | grep -oE '/[^[:space:]}]+' | wc -l | awk '{print $1}'
}

# --- FAILOVER (format validé chez toi) ---
get_failover_state() {
  local raw st

  # 1) show sys failover => "Failover active"
  raw="$(tmsh -c "show sys failover" 2>/dev/null || true)"
  st="$(printf "%s\n" "$raw" \
        | awk 'BEGIN{IGNORECASE=1} $1=="Failover" {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  if [[ "$st" == "active" || "$st" == "standby" ]]; then
    echo "$st"; return 0
  fi

  # 2) show cm failover-status => contient "Status ACTIVE"
  raw="$(tmsh -c "show cm failover-status" 2>/dev/null || true)"
  st="$(printf "%s\n" "$raw" \
        | awk 'BEGIN{IGNORECASE=1} $1=="Status" {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  if [[ "$st" == "active" || "$st" == "standby" ]]; then
    echo "$st"; return 0
  fi

  # 3) show cm traffic-group => "traffic-group-1 ... active|standby"
  raw="$(tmsh -c "show cm traffic-group" 2>/dev/null || true)"
  st="$(printf "%s\n" "$raw" \
        | awk 'BEGIN{IGNORECASE=1}
               $1 ~ /^traffic-group-1/ {
                 for(i=NF;i>=1;i--){
                   if(tolower($i)=="active"){print "active"; exit}
                   if(tolower($i)=="standby"){print "standby"; exit}
                 }
               }' || true)"
  st="$(trim "${st:-}")"
  if [[ "$st" == "active" || "$st" == "standby" ]]; then
    echo "$st"; return 0
  fi

  echo "unknown"
}

get_sync_status() {
  local raw s
  raw="$(tmsh -c "show cm sync-status" 2>/dev/null || true)"
  s="$(printf "%s\n" "$raw" \
      | awk 'BEGIN{IGNORECASE=1} $1=="Status" {sub(/^Status[[:space:]]*:[[:space:]]*/,""); print; exit}' \
      | sed 's/[[:space:]]\+/ /g' || true)"
  s="$(trim "${s:-}")"
  [[ -n "$s" ]] && echo "$s" || echo "unknown"
}

# --- compute ---
DG="$(get_device_group)"
DG="$(trim "${DG:-}")"

MODE="standalone"
MEMBERS="0"
FAILOVER="unknown"
SYNC="unknown"

if [[ -n "${DG:-}" ]]; then
  MODE="cluster"
  MEMBERS="$(get_members_count "$DG")"
  MEMBERS="${MEMBERS:-0}"
  FAILOVER="$(get_failover_state)"
  FAILOVER="$(trim "${FAILOVER:-unknown}")"
  SYNC="$(get_sync_status)"
  SYNC="$(trim "${SYNC:-unknown}")"
fi

ROLE="ha-unknown"
if [[ "$MODE" == "standalone" ]]; then
  ROLE="standalone"
else
  case "$FAILOVER" in
    active) ROLE="ha-active" ;;
    standby) ROLE="ha-standby" ;;
    *) ROLE="ha-unknown" ;;
  esac
fi

printf "MODE=%s\n" "$MODE"
printf "ROLE=%s\n" "$ROLE"
printf "DG=%s\n" "${DG:-none}"
printf "MEMBERS=%s\n" "$MEMBERS"
printf "FAILOVER=%s\n" "$FAILOVER"
printf "SYNC=%s\n" "$SYNC"

# debug lines to help diagnose parsing remotely
printf "DBG_SYS_FAILOVER=%s\n" "$(tmsh -c "show sys failover" 2>/dev/null | tr '\n' '|' || true)"
printf "DBG_CM_FAILOVER=%s\n" "$(tmsh -c "show cm failover-status" 2>/dev/null | tr '\n' '|' || true)"
RB
)

#######################################
# MAIN LOOP
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0
FAILS=0

echo "📋 Multi-équipements HA"
echo "📄 Devices file : $DEVICES_FILE"
echo "🔢 Total        : $TOTAL"
echo

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

  OUT=""
  if OUT=$(sshpass -p "$SSH_PASS" ssh -T \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o LogLevel=Error \
      "${SSH_USER}@${HOST}" "run util bash -s" <<<"$REMOTE_BASH" 2>&1); then

    MODE=$(printf "%s\n" "$OUT" | awk -F= '$1=="MODE"{print $2}')
    ROLE=$(printf "%s\n" "$OUT" | awk -F= '$1=="ROLE"{print $2}')
    DG=$(printf "%s\n" "$OUT" | awk -F= '$1=="DG"{print $2}')
    MEMBERS=$(printf "%s\n" "$OUT" | awk -F= '$1=="MEMBERS"{print $2}')
    FAILOVER=$(printf "%s\n" "$OUT" | awk -F= '$1=="FAILOVER"{print $2}')
    SYNC=$(printf "%s\n" "$OUT" | awk -F= '$1=="SYNC"{print $2}')

    # Print terminal
    echo "mode          : ${MODE:-unknown}"
    echo "role          : ${ROLE:-unknown}"
    echo "device-group  : ${DG:-none}"
    echo "members_count : ${MEMBERS:-0}"
    echo "failover      : ${FAILOVER:-unknown}"
    echo "sync-status   : ${SYNC:-unknown}"

    # Append to TXT
    {
      echo "Host: $HOST"
      echo "  mode          : ${MODE:-unknown}"
      echo "  role          : ${ROLE:-unknown}"
      echo "  device-group  : ${DG:-none}"
      echo "  members_count : ${MEMBERS:-0}"
      echo "  failover      : ${FAILOVER:-unknown}"
      echo "  sync-status   : ${SYNC:-unknown}"
      echo
    } >> "$TXT_OUT"

    # If still unknown, also log debug
    if [[ "${FAILOVER:-unknown}" == "unknown" ]]; then
      DBG1=$(printf "%s\n" "$OUT" | awk -F= '$1=="DBG_SYS_FAILOVER"{print substr($0, index($0,"=")+1)}')
      DBG2=$(printf "%s\n" "$OUT" | awk -F= '$1=="DBG_CM_FAILOVER"{print substr($0, index($0,"=")+1)}')
      {
        echo "  DEBUG:"
        echo "    show sys failover      : ${DBG1:-}"
        echo "    show cm failover-status: ${DBG2:-}"
        echo
      } >> "$TXT_OUT"
      echo "⚠️  DEBUG enregistré dans $TXT_OUT (failover=unknown)"
    fi

  else
    echo "❌ Échec SSH/TMSH : $HOST"
    FAILS=$((FAILS+1))
    {
      echo "Host: $HOST"
      echo "  ERROR: SSH/TMSH failed"
      echo "  Output:"
      echo "  $OUT"
      echo
    } >> "$TXT_OUT"
  fi

  echo
done < "$DEVICES_FILE"

echo "======================================"
echo "🏁 Terminé"
echo "📁 Run dir : $RUN_DIR"
echo "📝 TXT     : $TXT_OUT"
echo "❌ Échecs  : $FAILS"
echo "======================================"

(( FAILS == 0 )) || exit 1