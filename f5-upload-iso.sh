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
# VALIDATION CONFIG
#######################################
ISO_NAME=$(basename "$ISO_PATH")
HF_NAME=$(basename "$HF_PATH")

[[ -f "$ISO_PATH" ]] || { echo "❌ ISO introuvable : $ISO_PATH"; exit 1; }
[[ -f "$HF_PATH" ]]  || { echo "❌ Hotfix introuvable : $HF_PATH"; exit 1; }

#######################################
# INPUTS
#######################################
read -p "Utilisateur SSH (root recommandé): " SSH_USER
read -s -p "Mot de passe SSH: " SSH_PASS
echo

#######################################
# TOOLS CHECK
#######################################
for bin in sshpass curl jq; do
  command -v "$bin" >/dev/null || {
    echo "❌ $bin requis"
    exit 1
  }
done

#######################################
# FUNCTIONS
#######################################

remote_file_exists() {
  sshpass -p "$SSH_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o LogLevel=Error \
    "$SSH_USER@$1" \
    "test -f ${REMOTE_DIR}/$2"
}

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
SKIPPED=0

echo
echo "📦 Upload ISO + Hotfix (variables internes)"
echo " ISO    : $ISO_NAME"
echo " Hotfix : $HF_NAME"
echo " Cibles : $TOTAL BIG-IP"
echo

while IFS= read -r F5_HOST; do
  [[ -z "$F5_HOST" || "$F5_HOST" =~ ^# ]] && continue
  
  # Supprime CR (Windows) et trim
  HOST=$(echo "$LINE" | tr -d '\r' | xargs)

  # Ignore ligne vide ou commentaire
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  COUNT=$((COUNT+1))

  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $F5_HOST"
  echo "======================================"

  if remote_file_exists "$F5_HOST" "$ISO_NAME"; then
    echo "✔ ISO déjà présent"
  else
    echo "⬆️  Upload ISO"
    scp_upload "$F5_HOST" "$ISO_PATH" "$ISO_NAME"
    echo "✔ ISO uploadé"
  fi

  if remote_file_exists "$F5_HOST" "$HF_NAME"; then
    echo "✔ Hotfix déjà présent"
  else
    echo "⬆️  Upload Hotfix"
    scp_upload "$F5_HOST" "$HF_PATH" "$HF_NAME"
    echo "✔ Hotfix uploadé"
  fi

  SUCCESS=$((SUCCESS+1))
  echo "🎯 $F5_HOST terminé"
  echo

done < "$BIGIP_FILE"

#######################################
# SUMMARY
#######################################
echo "======================================"
echo "🏁 Résumé"
echo " Cibles totales : $TOTAL"
echo " Traitées       : $SUCCESS"
echo " Ignorées (HA)  : $SKIPPED"
echo "======================================"
