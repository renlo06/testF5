#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
BIGIP_FILE="devices.txt"
REMOTE_DIR="/shared/images"

#######################################
# USAGE
#######################################
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <BIGIP.iso> <HOTFIX.hf>"
  exit 1
fi

ISO_PATH="$1"
HF_PATH="$2"

ISO_NAME=$(basename "$ISO_PATH")
HF_NAME=$(basename "$HF_PATH")

[[ -f "$ISO_PATH" ]] || { echo "❌ ISO introuvable"; exit 1; }
[[ -f "$HF_PATH" ]]  || { echo "❌ Hotfix introuvable"; exit 1; }

#######################################
# INPUTS
#######################################
read -p "Utilisateur SSH (root recommandé): " SSH_USER
read -s -p "Mot de passe SSH: " SSH_PASS
echo

#######################################
# TOOLS
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
get_ha_state() {
  curl -sSk \
    -u "${SSH_USER}:${SSH_PASS}" \
    "https://${1}/mgmt/tm/cm/failover-status" |
  jq -r '.entries[].nestedStats.entries.status.description'
}

remote_file_exists() {
  sshpass -p "$SSH_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o LogLevel=Error \
    "$SSH_USER@$1" \
    "test -f ${REMOTE_DIR}/$2"
}

scp_upload() {
  sshpass -p "$SSH_PASS" scp \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=20 \
    "$2" \
    "$SSH_USER@$1:${REMOTE_DIR}/$3"
}

#######################################
# MAIN
#######################################
echo
echo "📦 Workflow ISO + Hotfix"
echo "ISO    : $ISO_NAME"
echo "Hotfix : $HF_NAME"
echo

while IFS= read -r F5_HOST; do
  [[ -z "$F5_HOST" || "$F5_HOST" =~ ^# ]] && continue
  F5_HOST=${F5_HOST//$'\r'/}

  echo "======================================"
  echo "➡️  BIG-IP : $F5_HOST"
  echo "======================================"

  HA_STATE=$(get_ha_state "$F5_HOST")

  if [[ "$HA_STATE" != "ACTIVE" ]]; then
    echo "⏭️  État HA : $HA_STATE → ignoré"
    echo
    continue
  fi

  echo "✅ État HA : ACTIVE"

  # ISO
  if remote_file_exists "$F5_HOST" "$ISO_NAME"; then
    echo "✔ ISO déjà présent"
  else
    echo "⬆️  Upload ISO"
    scp_upload "$F5_HOST" "$ISO_PATH" "$ISO_NAME"
    echo "✔ ISO uploadé"
  fi

  # HOTFIX
  if remote_file_exists "$F5_HOST" "$HF_NAME"; then
    echo "✔ Hotfix déjà présent"
  else
    echo "⬆️  Upload Hotfix"
    scp_upload "$F5_HOST" "$HF_PATH" "$HF_NAME"
    echo "✔ Hotfix uploadé"
  fi

  echo "🎯 Uploads terminés pour $F5_HOST"
  echo

done < "$BIGIP_FILE"

echo "🏁 Workflow ISO + Hotfix terminé"
