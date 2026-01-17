#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"
LOG_DIR="./logs"

#######################################
# PRECHECKS
#######################################
for bin in ssh sshpass date; do
  command -v "$bin" >/dev/null || {
    echo "❌ $bin requis"
    exit 1
  }
done

[[ -f "$DEVICES_FILE" ]] || {
  echo "❌ Fichier équipements introuvable : $DEVICES_FILE"
  exit 1
}

mkdir -p "$LOG_DIR"

#######################################
# INPUTS
#######################################
read -p "Utilisateur SSH (root recommandé): " SSH_USER
read -s -p "Mot de passe SSH: " SSH_PASS
echo

#######################################
# LOG FILE
#######################################
DATE=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/restjavad_iapplxrpm_${DATE}.log"

#######################################
# MAIN LOOP
#######################################
echo
echo "⚙️  Configuration iapplxrpm + redémarrage restjavad"
echo "Log : $LOG_FILE"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(echo "$LINE" | tr -d '\r' | xargs)
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  {
    echo "======================================"
    echo "BIG-IP : $HOST"
    echo "Date   : $(date)"
    echo "======================================"

    echo "➡️  Modification DB iapplxrpm.timeout"
    echo "cmd> modify sys db iapplxrpm.timeout value 300"

    sshpass -p "$SSH_PASS" ssh \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o LogLevel=Error \
      "$SSH_USER@$HOST" \
      "tmsh modify sys db iapplxrpm.timeout value 300"

    echo
    echo "➡️  Restart service restjavad"
    echo "cmd> restart sys service restjavad"

    sshpass -p "$SSH_PASS" ssh \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o LogLevel=Error \
      "$SSH_USER@$HOST" \
      "tmsh restart sys service restjavad"

    echo
    echo "⏳ Attente 1 seconde"
    sleep 1

    echo
    echo "📄 Vérification iapplxrpm.timeout"
    echo "cmd> list sys db iapplxrpm.timeout"
    sshpass -p "$SSH_PASS" ssh -n \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o LogLevel=Error \
      "$SSH_USER@$HOST" \
      "tmsh list sys db iapplxrpm.timeout"

    echo
    echo "📄 Vérification service restjavad"
    echo "cmd> show sys service restjavad"
    sshpass -p "$SSH_PASS" ssh \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o LogLevel=Error \
      "$SSH_USER@$HOST" \
      "tmsh show sys service restjavad"

    echo
    echo

  } | tee -a "$LOG_FILE"

done < "$DEVICES_FILE"

echo "🎯 Script terminé"
echo "📁 Résultats disponibles dans : $LOG_FILE"
