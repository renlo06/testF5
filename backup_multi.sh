#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"
LOCAL_BACKUP_DIR="/backups/f5"
REMOTE_UCS_DIR="/var/local/ucs"

MAX_PARALLEL=4
JOB_DELAY=0.5   # 500 ms entre chaque job
UCS_POLL_SLEEP=2
UCS_TIMEOUT_SEC=3600   # 1h (ajuste si besoin)

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

# Arrays for tracking
declare -A JOB_PID_BY_HOST
declare -A JOB_STATUS_BY_HOST   # OK/KO
declare -A JOB_MSG_BY_HOST

#######################################
# FUNCTIONS
#######################################
ssh_run() {
  local HOST="$1"; shift
  # -n : stdin -> /dev/null ; important for robustness
  sshpass -p "$SSH_PASS" ssh -n \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o LogLevel=Error \
    "$SSH_USER@$HOST" "$@"
}

scp_get() {
  local HOST="$1"; local SRC="$2"; local DEST_DIR="$3"
  sshpass -p "$SSH_PASS" scp -q \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=30 \
    "${SSH_USER}@${HOST}:${SRC}" \
    "${DEST_DIR}/"
}

create_ucs() {
  local HOST="$1"; local UCS_NAME="$2"
  ssh_run "$HOST" "tmsh save sys ucs $UCS_NAME"
}

wait_for_ucs() {
  local HOST="$1"; local UCS_NAME="$2"
  local start_ts now_ts

  start_ts=$(date +%s)
  while true; do
    if ssh_run "$HOST" "bash -lc 'test -f ${REMOTE_UCS_DIR}/${UCS_NAME}'"; then
      return 0
    fi

    now_ts=$(date +%s)
    if (( now_ts - start_ts > UCS_TIMEOUT_SEC )); then
      return 1
    fi

    sleep "$UCS_POLL_SLEEP"
  done
}

backup_host() {
  local HOST="$1"
  local DATE="$2"

  local UCS_NAME="${HOST}_${DATE}.ucs"
  local HOST_DIR="${LOCAL_BACKUP_DIR}/${HOST}"
  local HOST_LOG="${LOG_DIR}/${HOST}.log"

  mkdir -p "$HOST_DIR"

  {
    echo "======================================"
    echo "➡️  [$HOST] Démarrage sauvegarde"
    echo "UCS : $UCS_NAME"
    echo "======================================"

    echo "📦 [$HOST] Création UCS"
    create_ucs "$HOST" "$UCS_NAME"

    echo "⏳ [$HOST] Attente génération UCS (timeout ${UCS_TIMEOUT_SEC}s)"
    wait_for_ucs "$HOST" "$UCS_NAME"

    echo "⬇️  [$HOST] Récupération UCS"
    scp_get "$HOST" "${REMOTE_UCS_DIR}/${UCS_NAME}" "$HOST_DIR"

    echo "✅ [$HOST] UCS récupéré : $HOST_DIR/$UCS_NAME"
    echo
  } >"$HOST_LOG" 2>&1
}

#######################################
# MAIN
#######################################
echo
echo "📦 Sauvegarde UCS BIG-IP"
echo "Date            : $DATE"
echo "Parallélisme    : $MAX_PARALLEL équipements"
echo "Délai lancement : ${JOB_DELAY}s"
echo "Logs            : $LOG_DIR"
echo

JOB_COUNT=0

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(echo "$LINE" | tr -d '\r' | xargs)
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  # Launch job
  backup_host "$HOST" "$DATE" &
  pid=$!
  JOB_PID_BY_HOST["$HOST"]=$pid
  JOB_STATUS_BY_HOST["$HOST"]="RUNNING"
  JOB_COUNT=$((JOB_COUNT + 1))

  # Pause 500 ms
  sleep "$JOB_DELAY"

  # Keep at most MAX_PARALLEL jobs
  if (( JOB_COUNT >= MAX_PARALLEL )); then
    # wait -n returns exit status of finished job; must not kill script under set -e
    if ! wait -n; then
      :  # swallow error here; we'll mark host status below via per-host waits
    fi
    JOB_COUNT=$((JOB_COUNT - 1))
  fi
done < "$DEVICES_FILE"

# Wait for all remaining jobs and mark status by host
FAILS=0
for HOST in "${!JOB_PID_BY_HOST[@]}"; do
  pid="${JOB_PID_BY_HOST[$HOST]}"
  if wait "$pid"; then
    JOB_STATUS_BY_HOST["$HOST"]="OK"
  else
    JOB_STATUS_BY_HOST["$HOST"]="KO"
    JOB_MSG_BY_HOST["$HOST"]="Voir log: ${LOG_DIR}/${HOST}.log"
    FAILS=$((FAILS + 1))
  fi
done

echo "======================================"
echo "🏁 Résumé"
for HOST in "${!JOB_PID_BY_HOST[@]}"; do
  status="${JOB_STATUS_BY_HOST[$HOST]}"
  if [[ "$status" == "OK" ]]; then
    echo "✅ $HOST"
  else
    echo "❌ $HOST — ${JOB_MSG_BY_HOST[$HOST]}"
  fi
done
echo "Logs : $LOG_DIR"
echo "======================================"

# Return non-zero if any failure (useful for CI), but don't stop mid-run
if (( FAILS > 0 )); then
  echo "🎯 Terminé avec $FAILS échec(s)."
  exit 1
fi

echo "🎯 Sauvegarde UCS terminée pour tous les équipements"
