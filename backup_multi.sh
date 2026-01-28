#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"
LOCAL_BACKUP_DIR="/backups/f5"
REMOTE_UCS_DIR="/var/local/ucs"

MAX_PARALLEL=4
JOB_DELAY=0.5
UCS_POLL_SLEEP=2
UCS_TIMEOUT_SEC=3600
STATUS_REFRESH_SEC=2

#######################################
# PRECHECKS
#######################################
for bin in ssh scp sshpass date; do
  command -v "$bin" >/dev/null || { echo "❌ $bin requis"; exit 1; }
done

[[ -f "$DEVICES_FILE" ]] || { echo "❌ Fichier équipements introuvable : $DEVICES_FILE"; exit 1; }
mkdir -p "$LOCAL_BACKUP_DIR"

#######################################
# INPUTS
#######################################
read -p "Utilisateur SSH (root recommandé): " SSH_USER
read -s -p "Mot de passe SSH: " SSH_PASS
echo

#######################################
# RUNTIME (répertoire unique pour tous les UCS)
#######################################
DATE=$(date +%Y%m%d-%H%M%S)

BACKUP_DIR="${LOCAL_BACKUP_DIR}/${DATE}"
LOG_DIR="${LOCAL_BACKUP_DIR}/logs/${DATE}"

mkdir -p "$BACKUP_DIR" "$LOG_DIR"

#######################################
# FUNCTIONS
#######################################
ssh_run() {
  local HOST="$1"; shift
  sshpass -p "$SSH_PASS" ssh -n \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o LogLevel=Error \
    "$SSH_USER@$HOST" "$@"
}

scp_get() {
  local HOST="$1" SRC="$2" DEST="$3"
  sshpass -p "$SSH_PASS" scp -q \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=30 \
    "$SSH_USER@$HOST:$SRC" \
    "$DEST/"
}

create_ucs() {
  local HOST="$1" UCS_NAME="$2"
  ssh_run "$HOST" "tmsh save sys ucs $UCS_NAME"
}

wait_for_ucs() {
  local HOST="$1" UCS_NAME="$2"
  local start now
  start=$(date +%s)

  while true; do
    # force bash shell on BIG-IP (avoid tmsh parsing "test")
    if ssh_run "$HOST" "bash -lc 'test -f ${REMOTE_UCS_DIR}/${UCS_NAME}'"; then
      return 0
    fi

    now=$(date +%s)
    (( now - start > UCS_TIMEOUT_SEC )) && return 1
    sleep "$UCS_POLL_SLEEP"
  done
}

backup_host() {
  local HOST="$1" DATE="$2"

  local UCS_NAME="${HOST}_${DATE}.ucs"
  local DEST_DIR="$BACKUP_DIR"
  local LOG="${LOG_DIR}/${HOST}.log"
  local STATUS_FILE="${LOG_DIR}/${HOST}.status"

  echo "RUNNING: create_ucs" > "$STATUS_FILE"

  {
    echo "======================================"
    echo "➡️  [$HOST] Démarrage sauvegarde"
    echo "UCS : $UCS_NAME"
    echo "Dest: $DEST_DIR"
    echo "======================================"

    echo "📦 [$HOST] Création UCS"
    create_ucs "$HOST" "$UCS_NAME"

    echo "RUNNING: wait_for_ucs" > "$STATUS_FILE"
    echo "⏳ [$HOST] Attente génération UCS (timeout ${UCS_TIMEOUT_SEC}s)"
    wait_for_ucs "$HOST" "$UCS_NAME"

    echo "RUNNING: scp" > "$STATUS_FILE"
    echo "⬇️  [$HOST] Transfert UCS"
    scp_get "$HOST" "${REMOTE_UCS_DIR}/${UCS_NAME}" "$DEST_DIR"

    echo "OK" > "$STATUS_FILE"
    echo "✅ [$HOST] UCS récupéré : $DEST_DIR/$UCS_NAME"
    echo
  } >"$LOG" 2>&1 || {
    echo "KO" > "$STATUS_FILE"
    exit 1
  }
}

print_status() {
  echo
  echo "====== Équipements en cours ======"
  for f in "$LOG_DIR"/*.status; do
    [[ -e "$f" ]] || continue
    host=$(basename "$f" .status)
    state=$(cat "$f" 2>/dev/null || echo "UNKNOWN")
    printf "%-30s %s\n" "$host" "$state"
  done
  echo "=================================="
}

#######################################
# MAIN
#######################################
echo
echo "📦 Sauvegarde UCS BIG-IP"
echo "Date          : $DATE"
echo "Parallélisme  : $MAX_PARALLEL équipements"
echo "Délai job     : ${JOB_DELAY}s"
echo "UCS ->        : $BACKUP_DIR"
echo "Logs ->       : $LOG_DIR"
echo

# Watcher (affichage périodique des hosts en cours)
WATCHER_PID=""
watcher() {
  while true; do
    print_status
    sleep "$STATUS_REFRESH_SEC"
  done
}
watcher &
WATCHER_PID=$!

cleanup() {
  [[ -n "${WATCHER_PID:-}" ]] && kill "$WATCHER_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(echo "$LINE" | tr -d '\r' | xargs)
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  backup_host "$HOST" "$DATE" &
  sleep "$JOB_DELAY"

  # Throttle portable (pas de wait -n)
  while (( $(jobs -p | wc -l) >= MAX_PARALLEL )); do
    sleep 1
  done

done < "$DEVICES_FILE"

# Attendre tous les jobs
wait

# Dernier affichage
print_status

echo "======================================"
echo "🎯 Sauvegarde UCS terminée"
echo "UCS  : $BACKUP_DIR"
echo "Logs : $LOG_DIR"
echo "======================================"
