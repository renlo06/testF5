#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"
LOCAL_BACKUP_DIR="/backups/f5"
REMOTE_UCS_DIR="/var/local/ucs"

BACKUP_DIR="${LOCAL_BACKUP_DIR}/backup"
LOG_DIR="${LOCAL_BACKUP_DIR}/logs"

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
mkdir -p "$BACKUP_DIR" "$LOG_DIR"

#######################################
# INPUTS
#######################################
read -p "Utilisateur SSH (root recommandé): " SSH_USER
read -s -p "Mot de passe SSH: " SSH_PASS
echo

#######################################
# FUNCTIONS
#######################################
ssh_run() {
  sshpass -p "$SSH_PASS" ssh -n \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o LogLevel=Error \
    "$SSH_USER@$1" "${@:2}"
}

scp_get() {
  sshpass -p "$SSH_PASS" scp -q \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=30 \
    "$SSH_USER@$1:$2" "$3/"
}

create_ucs() {
  ssh_run "$1" "bash -lc 'tmsh save sys ucs \"$2\"'"
}

wait_for_ucs() {
  local HOST="$1" UCS_NAME="$2"
  local start now
  start=$(date +%s)

  while true; do
    if ssh_run "$HOST" "bash -lc 'test -f \"${REMOTE_UCS_DIR}/${UCS_NAME}\"'"; then
      return 0
    fi
    now=$(date +%s)
    (( now - start > UCS_TIMEOUT_SEC )) && return 1
    sleep "$UCS_POLL_SLEEP"
  done
}

backup_host() {
  local HOST="$1"
  local UCS_NAME="${HOST}.ucs"
  local LOG="${LOG_DIR}/${HOST}.log"
  local STATUS_FILE="${LOG_DIR}/${HOST}.status"

  echo "RUNNING: create_ucs" > "$STATUS_FILE"

  {
    create_ucs "$HOST" "$UCS_NAME"

    echo "RUNNING: wait_for_ucs" > "$STATUS_FILE"
    wait_for_ucs "$HOST" "$UCS_NAME"

    echo "RUNNING: scp" > "$STATUS_FILE"
    scp_get "$HOST" "${REMOTE_UCS_DIR}/${UCS_NAME}" "$BACKUP_DIR"

    echo "OK" > "$STATUS_FILE"
  } >"$LOG" 2>&1 || {
    echo "KO" > "$STATUS_FILE"
    exit 1
  }
}

print_status() {
  clear
  echo "======================================"
  echo "📦 Sauvegarde UCS – état en cours"
  echo "UCS  -> $BACKUP_DIR"
  echo "Logs -> $LOG_DIR"
  echo "======================================"
  echo
  printf "%-30s %s\n" "Équipement" "Statut"
  printf "%-30s %s\n" "----------" "------"
  for f in "$LOG_DIR"/*.status; do
    [[ -e "$f" ]] || continue
    printf "%-30s %s\n" "$(basename "$f" .status)" "$(cat "$f" 2>/dev/null || echo UNKNOWN)"
  done
  echo
  echo "Actualisation toutes les ${STATUS_REFRESH_SEC}s"
}

# Nettoie la liste des PIDs : ne garde que ceux encore vivants
prune_pids() {
  local new=() pid
  for pid in "$@"; do
    if kill -0 "$pid" 2>/dev/null; then
      new+=("$pid")
    fi
  done
  # imprime la liste (pour réaffectation)
  echo "${new[*]-}"
}

# Compte les PIDs encore vivants
count_running_pids() {
  local c=0 pid
  for pid in "$@"; do
    if kill -0 "$pid" 2>/dev/null; then
      c=$((c+1))
    fi
  done
  echo "$c"
}

#######################################
# MAIN
#######################################
WATCHER_PID=""
watcher() {
  while true; do
    print_status
    sleep "$STATUS_REFRESH_SEC"
  done
}
watcher &
WATCHER_PID=$!
trap 'kill "$WATCHER_PID" 2>/dev/null || true' EXIT

PIDS=()

while IFS= read -r HOST || [[ -n "$HOST" ]]; do
  HOST=$(echo "$HOST" | tr -d '\r' | xargs)
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  # Nettoyage des PIDs terminés avant de décider
  pruned="$(prune_pids "${PIDS[@]}")"
  # reconstruire PIDS proprement (portable)
  PIDS=()
  for pid in $pruned; do PIDS+=("$pid"); done

  # Throttle: attendre tant qu'on a MAX_PARALLEL backups actifs
  while [[ "$(count_running_pids "${PIDS[@]}")" -ge "$MAX_PARALLEL" ]]; do
    sleep 1
    pruned="$(prune_pids "${PIDS[@]}")"
    PIDS=()
    for pid in $pruned; do PIDS+=("$pid"); done
  done

  backup_host "$HOST" &
  PIDS+=("$!")
  sleep "$JOB_DELAY"
done < "$DEVICES_FILE"

# Attendre tous les backups restants
FAILS=0
for pid in "${PIDS[@]}"; do
  if ! wait "$pid"; then
    FAILS=$((FAILS+1))
  fi
done

kill "$WATCHER_PID" 2>/dev/null || true
print_status

echo "======================================"
echo "🎯 Sauvegarde UCS terminée"
echo "UCS  : $BACKUP_DIR"
echo "Logs : $LOG_DIR"
echo "Échecs : $FAILS"
echo "======================================"

(( FAILS == 0 )) || exit 1
