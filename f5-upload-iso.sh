#!/usr/bin/env bash

#######################################
# METADATA
#######################################
SCRIPT_NAME="f5-upload-iso.sh"
SCRIPT_VERSION="1.0.0-GOLD"
SCRIPT_DATE="2026-01-13"

#######################################
# VERSION
#######################################
if [[ "${1:-}" == "-v" || "${1:-}" == "--version" ]]; then
  echo "$SCRIPT_NAME version $SCRIPT_VERSION ($SCRIPT_DATE)"
  exit 0
fi

#######################################
# SAFETY
#######################################
set -euo pipefail

#######################################
# CONFIG
#######################################
BIGIP_FILE="devices.txt"
CHUNK_SIZE=$((512 * 1024 * 1024))  # 512 MB

#######################################
# PRECHECKS
#######################################
command -v curl >/dev/null || { echo "❌ curl manquant"; exit 1; }
command -v jq   >/dev/null || { echo "❌ jq requis"; exit 1; }

[[ $# -eq 1 ]] || {
  echo "Usage: $0 <fichier.iso>"
  exit 1
}

ISO_PATH="$1"
[[ -f "$ISO_PATH" ]] || { echo "❌ ISO introuvable"; exit 1; }

ISO_NAME=$(basename "$ISO_PATH")
ISO_SIZE=$(stat -c%s "$ISO_PATH")

#######################################
# INPUTS
#######################################
read -p "Utilisateur API: " API_USER
read -s -p "Mot de passe API: " API_PASS
echo

#######################################
# FUNCTIONS
#######################################
get_ha_state() {
  curl -sSk \
    -u "${API_USER}:${API_PASS}" \
    "https://${1}/mgmt/tm/cm/failover-status" |
  jq -r '.entries[].nestedStats.entries.status.description'
}

#######################################
# MAIN LOOP
#######################################
echo
echo "📀 Upload ISO : $ISO_NAME"
echo "📦 Taille     : $ISO_SIZE octets"
echo "📦 Chunk size : $CHUNK_SIZE octets"
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
  echo "⬆️  Début upload ISO"

  OFFSET=0

  while [[ $OFFSET -lt $ISO_SIZE ]]; do
    END=$((OFFSET + CHUNK_SIZE - 1))
    [[ $END -ge $ISO_SIZE ]] && END=$((ISO_SIZE - 1))

    echo "   ➤ Chunk $OFFSET-$END"

    curl -sSk \
      -u "${API_USER}:${API_PASS}" \
      -X POST \
      -H "Content-Type: application/octet-stream" \
      -H "Content-Range: ${OFFSET}-${END}/${ISO_SIZE}" \
      --data-binary @"$ISO_PATH" \
      "https://${F5_HOST}/mgmt/shared/file-transfer/uploads/${ISO_NAME}" \
      >/dev/null

    OFFSET=$((END + 1))
  done

  echo "✅ Upload ISO terminé pour $F5_HOST"
  echo

done < "$BIGIP_FILE"

echo "🎯 Upload ISO terminé sur tous les BIG-IP actifs"
