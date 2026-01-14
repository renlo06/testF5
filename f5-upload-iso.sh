#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
BIGIP_FILE="devices.txt"
REMOTE_DIR="/shared/images"

# === CHEMINS DES FICHIERS ===
ISO_PATH="/apps/data/os_repository/F5/TMOS_17.1.3/BIGIP-17.1.3-0.0.11.iso"
HF_PATH="/apps/data/os_repository/F5/TMOS_17.1.3/Hotfix-BIGIP-17.1.3.0.176.11-ENG.iso"

#######################################
# VALIDATION DES FICHIERS
#######################################
ISO_NAME=$(basename "$ISO_PATH")
HF_NAME=$(basename "$HF_PATH")

[[ -f "$ISO_PATH" ]] || { echo "❌ ISO introuvable : $ISO_PATH"; exit 1; }
[[ -f "$HF_PATH"  ]] || { echo "❌ Hotfix introuvable : $HF_PATH"; exit 1; }

#######################################
# INPUTS
#######################################
read -p "Utilisateur SSH (root recommandé): " SSH_USER
read -s -p "Mot de passe SSH: " SSH_PASS
echo

#######################################
# TOOLS CHECK
#######################################
for bin in sshpass ssh scp; do
  command -v "$bin" >/dev/null || {
    echo "❌ $bin requis"
    exit 1
  }
done

#######################################
# FUNCTIONS
#######################################

# Vérifie si un fichier existe sur le BIG-IP
# IMPORTANT : neutralise set -e
remote_file_exists() {
  sshpass -p "$SSH_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o LogLevel=Error \
    "$SSH_USER@$1" \
    "test -f ${REMOTE_DIR}/$2" >/dev/null 2>&1 || return 1
}

# Upload SCP
scp_upload() {
  sshpass -p "$SSH_PASS" scp \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=30 \
    "$2" \
    "$SSH_USER@$1:${REMOTE_DIR}/$3"
}

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$BIGIP_FILE" | wc -l)
COUNT=0
SUCCESS=0

echo
echo "📦 Upload ISO + Hotfix (sans gestion HA)"
echo "ISO    : $ISO_NAME"
echo "Hotfix : $HF_NAME"
echo "Cibles : $TOTAL BIG-IP"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(echo "$LINE" | tr -d '\r' | xargs)
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  COUNT=$((COUNT + 1))
  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  # ISO
  if remote_file_exists "$HOST" "$ISO_NAME"; then
    echo "✔ ISO déjà présent"
  else
    echo "⬆️  Upload ISO"
    scp_upload "$HOST" "$ISO_PATH" "$ISO_NAME"
    echo "✔ ISO uploadé"
  fi

  # HOTFIX
  if remote_file_exists "$HOST" "$HF_NAME"; then
    echo "✔ Hotfix déjà présent"
  else
    echo "⬆️  Upload Hotfix"
    scp_upload "$HOST" "$HF_PATH" "$HF_NAME"
    echo "✔ Hotfix uploadé"
  fi

  SUCCESS=$((SUCCESS + 1))
  echo "🎯 $HOST terminé"
  echo

done < "$BIGIP_FILE"

#######################################
# SUMMARY
#######################################
echo "======================================"
echo "🏁 Résumé final"
echo "Cibles totales : $TOTAL"
echo "Traitées       : $SUCCESS"
echo "======================================"
