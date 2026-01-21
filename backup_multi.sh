#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"
LOCAL_BACKUP_DIR="/backups/f5"
REMOTE_UCS_DIR="/var/local/ucs"

MAX_PARALLEL=4

#######################################
# PRECHECKS
#######################################
for bin in ssh scp sshpass date; do
  command -v "$bin" >/dev/null || {
    echo "❌ $bin requis"
    exit 1
  }
done

[[ -f "$DEVICES_FILE" ]] || {
  echo "❌ Fichier équipements introuvable : $DEVICES_FILE"
  exit 1
}

mkdir -p "$LOCAL_BACKUP_DIR"

#######################################
# INPUTS
#######################################
read -p "Utilisateur SSH (root recommandé): " SSH_USER
read -s -p "Mot de passe SSH: " SSH_PASS
echo

#######################################
# FUNCTIONS
#######################################
create_ucs() {
  local HOST="$1"
  local UCS_NAME="$2"

  sshpass -p "$SSH_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o LogLevel=Error \
    "$SSH_USER@$HOST" \
    "tmsh save sys ucs $UCS_NAME"
}

wait_for_ucs() {
  local HOST="$1"
  local UCS_NAME="$2"

  until sshpass -p "$SSH_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o LogLevel=Error \
    "$SSH_USER@$HOST" \
    "test -f ${REMOTE_UCS_DIR}/${UCS_NAME}"; do
    sleep 2
  done
}

scp_ucs() {
  local HOST="$1"
  local UCS_NAME="$2"
  local DEST="$3"

  sshpass -p "$SSH_PASS" scp \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=30 \
    "$SSH_USER@$HOST:${REMOTE_UCS_DIR}/${UCS_NAME}" \
    "$DEST/"
}

backup_host() {
  local HOST="$1"
  local DATE="$2"

  UCS_NAME="${HOST}_${DATE}.ucs"
  HOST_DIR="${LOCAL_BACKUP_DIR}/${HOST}"

  mkdir -p "$HOST_DIR"

  echo "======================================"
  echo "➡️  [$HOST] Démarrage sauvegarde"
  echo "======================================"

  echo "📦 [$HOST] Création UCS"
  create_ucs "$HOST" "$UCS_NAME"

  echo "⏳ [$HOST] Attente génération UCS"
  wait_for_ucs "$HOST" "$UCS_NAME"

  echo "⬇️  [$HOST] Récupération UCS"
  scp_ucs "$HOST" "$UCS_NAME" "$HOST_DIR"

  echo "✅ [$HOST] UCS récupéré : $HOST_DIR/$UCS_NAME"
  echo
}

#######################################
# MAIN
#######################################
DATE=$(date +%Y%m%d-%H%M%S)
JOB_COUNT=0

echo
echo "📦 Sauvegarde UCS BIG-IP"
echo "Date : $DATE"
echo "Parallélisme : $MAX_PARALLEL équipements"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(echo "$LINE" | tr -d '\r' | xargs)
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  backup_host "$HOST" "$DATE" &

  JOB_COUNT=$((JOB_COUNT + 1))

  # Limite à MAX_PARALLEL jobs simultanés
  if (( JOB_COUNT >= MAX_PARALLEL )); then
    wait -n
    JOB_COUNT=$((JOB_COUNT - 1))
  fi

done < "$DEVICES_FILE"

# Attente de la fin de tous les jobs restants
wait

echo "======================================"
echo "🎯 Sauvegarde UCS terminée pour tous les équipements"
echo "======================================"
