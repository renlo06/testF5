#!/usr/bin/env bash
set -euo pipefail

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
# OPTION A: Nettoyage des anciens statuts
#######################################
rm -f "$LOG_DIR"/*.status 2>/dev/null || true

#######################################
# OPTION B: Construire la liste des hôtes du run
#######################################
HOSTS_RUN_FILE="$(mktemp)"
while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  h=$(echo "$LINE" | tr -d '\r' | xargs)
  [[ -z "$h" || "$h" =~ ^# ]] && continue
  echo "$h"
done < "$DEVICES_FILE" > "$HOSTS_RUN_FILE"

#######################################
# (Bonus) Nettoyage des logs des hôtes absents du run
# (évite que des .log d’anciens hôtes s’accumulent)
#######################################
for old in "$LOG_DIR"/*.log; do
  [[ -e "$old" ]] || continue
  old_host=$(basename "$old" .log)
  if ! grep -Fxq "$old_host" "$HOSTS_RUN_FILE"; then
    rm -f "$old" 2>/dev/null || true
  fi
done

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

create_ucs() { ssh_run "$1" "bash -lc 'tmsh save sys ucs \"$2\"'"; }

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

  # OPTION B: afficher uniquement les hôtes du fichier devices.txt
  while IFS= read -r host || [[ -n "$host" ]]; do
    [[ -z "$host" ]] && continue
    status_file="$LOG_DIR/${host}.status"
    if [[ -f "$status_file" ]]; then
      state=$(cat "$status_file" 2>/dev/null || echo "UNKNOWN")
    else
      state="PENDING"
    fi
    printf "%-30s %s\n" "$host" "$state"
  done < "$HOSTS_RUN_FILE"

  echo
  echo "Actualisation toutes les ${STATUS_REFRESH_SEC}s"
}

# Nettoie la liste de PIDs (ne garde que ceux encore vivants)
prune_pids() {
  local new=() pid
  for pid in "$@"; do
    if kill -0 "$pid" 2>/dev/null; then
      new+=("$pid")
    fi
  done
  printf '%s\n' "${new[@]:-}"
}

count_running_pids() {
  local c=0 pid
  for pid in "$@"; do
    if kill -0 "$pid" 2>/dev/null; then
      c=$((c+1))
    fi
  done
  echo "$c"
}

# Watcher
WATCHER_PID=""
watcher() { while true; do print_status; sleep "$STATUS_REFRESH_SEC"; done; }
watcher &
WATCHER_PID=$!

cleanup() {
  rm -f "$HOSTS_RUN_FILE" 2>/dev/null || true
  kill "$WATCHER_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Déclare explicitement le tableau
declare -a PIDS=()

while IFS= read -r HOST || [[ -n "$HOST" ]]; do
  HOST=$(echo "$HOST" | tr -d '\r' | xargs)
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  # prune
  mapfile -t PIDS < <(prune_pids "${PIDS[@]:-}")

  # throttle
  while [[ "$(count_running_pids "${PIDS[@]:-}")" -ge "$MAX_PARALLEL" ]]; do
    sleep 1
    mapfile -t PIDS < <(prune_pids "${PIDS[@]:-}")
  done

  backup_host "$HOST" &
  PIDS+=("$!")
  sleep "$JOB_DELAY"
done < "$DEVICES_FILE"

FAILS=0
for pid in "${PIDS[@]:-}"; do
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
