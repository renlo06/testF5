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
# RUNTIME
#######################################
DATE=$(date +%Y%m%d-%H%M%S)
LOG_DIR="${LOCAL_BACKUP_DIR}/logs/${DATE}"
mkdir -p "$LOG_DIR"

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
    "$SSH_USER@$HOST:$SRC" "$DEST/"
}

create_ucs() {
  ssh_run "$1" "tmsh save sys ucs $2"
}

wait_for_ucs() {
  local HOST="$1" UCS_NAME="$2"
  local start now
  start=$(date +%s)

  while true; do
    if ssh_run "$HOST" "test -f ${REMOTE_UCS_DIR}/${UCS_NAME}"; then
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
  local HOST_DIR="${LOCAL_BACKUP_DIR}/${HOST}"
  local LOG="${LOG_DIR}/${HOST}.log"

  mkdir -p "$HOST_DIR"

  {
    echo "➡️  [$HOST] Démarrage sauvegarde"
    create_ucs "$HOST" "$UCS_NAME"
    wait_for_ucs "$HOST" "$UCS_NAME"
    scp_get "$HOST" "${REMOTE_UCS_DIR}/${UCS_NAME}" "$HOST_DIR"
    echo "✅ [$HOST] UCS récupéré"
  } >"$LOG" 2>&1
}

#######################################
# MAIN
#######################################
echo
echo "📦 Sauvegarde UCS BIG-IP"
echo "Date         : $DATE"
echo "Parallélisme : $MAX_PARALLEL"
echo "Logs         : $LOG_DIR"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(echo "$LINE" | tr -d '\r' | xargs)
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  backup_host "$HOST" "$DATE" &
  sleep "$JOB_DELAY"

  # --- LIMITE DE PARALLÉLISME (portable) ---
  while (( $(jobs -p | wc -l) >= MAX_PARALLEL )); do
    sleep 1
  done

done < "$DEVICES_FILE"

# Attendre tous les jobs restants
wait

echo "======================================"
echo "🎯 Sauvegarde UCS terminée"
echo "Logs : $LOG_DIR"
echo "======================================"
