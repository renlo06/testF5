#!/usr/bin/env bash

#######################################
# SCRIPT METADATA
#######################################
SCRIPT_NAME="f5-upload-iso-hotfix.sh"
SCRIPT_VERSION="1.0.0-GOLD"
SCRIPT_DATE="2026-01-14"
SCRIPT_AUTHOR="ggggg"

#######################################
# BASH SAFETY
#######################################
set -euo pipefail

#######################################
# CONFIG
#######################################
BIGIP_FILE="devices.txt"
REMOTE_DIR="/shared/images"

#######################################
# PRECHECKS
#######################################
for bin in sshpass ssh scp; do
  command -v "$bin" >/dev/null || {
    echo "❌ Binaire manquant : $bin"
    exit 1
  }
done

[[ -f "$BIGIP_FILE" ]] || {
  echo "❌ Fichier $BIGIP_FILE introuvable"
  exit 1
}

#######################################
# HEADER
#######################################
echo "======================================"
echo " $SCRIPT_NAME"
echo " Version : $SCRIPT_VERSION"
echo " Date    : $SCRIPT_DATE"
echo " Auteur  : $SCRIPT_AUTHOR"
echo "======================================"
echo

#######################################
# INPUTS
#######################################
read -p "Utilisateur SSH (ex: root ou admin): " SSH_USER
read -s -p "Mot de passe SSH: " SSH_PASS
echo

read -e -p "Chemin ISO (ex: /data/BIGIP.iso): " ISO_PATH
read -e -p "Chemin Hotfix (optionnel): " HF_PATH

[[ -f "$ISO_PATH" ]] || { echo "❌ ISO introuvable"; exit 1; }
[[ -z "$HF_PATH" || -f "$HF_PATH" ]] || { echo "❌ Hotfix introuvable"; exit 1; }

ISO_NAME=$(basename "$ISO_PATH")
HF_NAME=$(basename "$HF_PATH")

#######################################
# FUNCTIONS
#######################################
log() {
  echo -e "$1"
}

remote_file_exists() {
  sshpass -p "$SSH_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o LogLevel=Error \
    "$SSH_USER@$1" \
    "test -f ${REMOTE_DIR}/$2" >/dev/null 2>&1 || return 1
}

scp_upload() {
  sshpass -p "$SSH_PASS" scp \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=30 \
    "$2" \
    "$SSH_USER@$1:${REMOTE_DIR}/"
}

#######################################
# MAIN LOOP
#######################################
echo "🚀 Début upload ISO / Hotfix"
echo

while IFS= read -r HOST; do
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue
  HOST=${HOST//$'\r'/}

  echo "======================================"
  echo "➡️  BIG-IP : $HOST"
  echo "======================================"

  # ISO
  log "📦 ISO : $ISO_NAME"
  if remote_file_exists "$HOST" "$ISO_NAME"; then
    log "✅ ISO déjà présent – skip"
  else
    log "⬆️  Upload ISO..."
    scp_upload "$HOST" "$ISO_PATH"
    log "✅ ISO uploadé"
  fi

  # HOTFIX
  if [[ -n "${HF_PATH:-}" ]]; then
    log "📦 Hotfix : $HF_NAME"
    if remote_file_exists "$HOST" "$HF_NAME"; then
      log "✅ Hotfix déjà présent – skip"
    else
      log "⬆️  Upload Hotfix..."
      scp_upload "$HOST" "$HF_PATH"
      log "✅ Hotfix uploadé"
    fi
  fi

  echo "🎯 $HOST terminé"
  echo

done < "$BIGIP_FILE"

echo "🏁 Upload terminé sur tous les équipements"
