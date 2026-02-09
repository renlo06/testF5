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

# Exécute une commande et renvoie stdout (sans casser set -e)
run_cmd() {
  # shellcheck disable=SC2086
  sh -c "$1" 2>/dev/null || true
}

# Essaie plusieurs commandes, retourne la première sortie non vide
first_non_empty() {
  local out
  while [[ $# -gt 0 ]]; do
    out="$(run_cmd "$1")"
    if [[ -n "$(trim "${out:-}")" ]]; then
      printf "%s" "$out"
      return 0
    fi
    shift
  done
  return 1
}

# Device-group (1er trouvé)
get_device_group() {
  first_non_empty \
    'tmsh -c "list cm device-group one-line"' \
    'tmsh list cm device-group one-line' \
    'list cm device-group one-line' \
  | awk '$1=="cm" && $2=="device-group" {print $3; exit}' || true
}

get_members_count() {
  local dg="$1"
  local line=""
  line="$(first_non_empty \
      "tmsh -c \"list cm device-group ${dg} one-line\"" \
      "tmsh list cm device-group ${dg} one-line" \
      "list cm device-group ${dg} one-line" \
    || true)"

  printf "%s\n" "$line" | grep -oE '/[^[:space:]}]+' | wc -l | awk '{print $1}'
}

# --- FAILOVER (format validé : "Failover active" / "Status ACTIVE") ---
get_failover_raw_sys() {
  first_non_empty \
    'tmsh -c "show sys failover"' \
    'tmsh show sys failover' \
    'show sys failover' \
    || true
}

get_failover_raw_cm() {
  first_non_empty \
    'tmsh -c "show cm failover-status"' \
    'tmsh show cm failover-status' \
    'show cm failover-status' \
    || true
}

get_failover_raw_tg() {
  first_non_empty \
    'tmsh -c "show cm traffic-group"' \
    'tmsh show cm traffic-group' \
    'show cm traffic-group' \
    || true
}

get_failover_state() {
  local raw st

  raw="$(get_failover_raw_sys)"
  st="$(printf "%s\n" "$raw" \
        | awk 'BEGIN{IGNORECASE=1} $1=="Failover" {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  if [[ "$st" == "active" || "$st" == "standby" ]]; then
    echo "$st"; return 0
  fi

  raw="$(get_failover_raw_cm)"
  st="$(printf "%s\n" "$raw" \
        | awk 'BEGIN{IGNORECASE=1} $1=="Status" {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  if [[ "$st" == "active" || "$st" == "standby" ]]; then
    echo "$st"; return 0
  fi

  raw="$(get_failover_raw_tg)"
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
  raw="$(first_non_empty \
        'tmsh -c "show cm sync-status"' \
        'tmsh show cm sync-status' \
        'show cm sync-status' \
        || true)"

  # On prend "Status : xxx" si dispo, sinon unknown
  s="$(printf "%s\n" "$raw" \
      | awk 'BEGIN{IGNORECASE=1}
             $1=="Status" {
               sub(/^Status[[:space:]]*:[[:space:]]*/,"")
               print
               exit
             }' \
      | sed 's/[[:space:]]\+/ /g' || true)"
  s="$(trim "${s:-}")"
  [[ -n "$s" ]] && echo "$s" || echo "unknown"
}

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

# Debug bruts (toujours, pour diagnostic rapide)
DBG_SYS="$(get_failover_raw_sys | tr '\n' '|' || true)"
DBG_CM="$(get_failover_raw_cm  | tr '\n' '|' || true)"
DBG_TG="$(get_failover_raw_tg  | tr '\n' '|' || true)"

printf "MODE=%s\n" "$MODE"
printf "ROLE=%s\n" "$ROLE"
printf "DG=%s\n" "${DG:-none}"
printf "MEMBERS=%s\n" "$MEMBERS"
printf "FAILOVER=%s\n" "$FAILOVER"
printf "SYNC=%s\n" "$SYNC"
printf "DBG_SYS_FAILOVER=%s\n" "$DBG_SYS"
printf "DBG_CM_FAILOVER=%s\n" "$DBG_CM"
printf "DBG_TG=%s\n" "$DBG_TG"
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

    DBG_SYS=$(printf "%s\n" "$OUT" | awk -F= '$1=="DBG_SYS_FAILOVER"{print substr($0, index($0,"=")+1)}')
    DBG_CM=$(printf "%s\n" "$OUT" | awk -F= '$1=="DBG_CM_FAILOVER"{print substr($0, index($0,"=")+1)}')
    DBG_TG=$(printf "%s\n" "$OUT" | awk -F= '$1=="DBG_TG"{print substr($0, index($0,"=")+1)}')

    # Affichage terminal
    echo "mode          : ${MODE:-unknown}"
    echo "role          : ${ROLE:-unknown}"
    echo "device-group  : ${DG:-none}"
    echo "members_count : ${MEMBERS:-0}"
    echo "failover      : ${FAILOVER:-unknown}"
    echo "sync-status   : ${SYNC:-unknown}"

    # Écriture TXT
    {
      echo "Host: $HOST"
      echo "  mode          : ${MODE:-unknown}"
      echo "  role          : ${ROLE:-unknown}"
      echo "  device-group  : ${DG:-none}"
      echo "  members_count : ${MEMBERS:-0}"
      echo "  failover      : ${FAILOVER:-unknown}"
      echo "  sync-status   : ${SYNC:-unknown}"
      echo "  debug:"
      echo "    show sys failover      : ${DBG_SYS:-}"
      echo "    show cm failover-status: ${DBG_CM:-}"
      echo "    show cm traffic-group  : ${DBG_TG:-}"
      echo
    } >> "$TXT_OUT"

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