#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"

# AS3 RPM
AS3_RPM_PATH="/apps/data/f5/as3/f5-appsvcs-3.49.0-1.noarch.rpm"
RPM_NAME=$(basename "$AS3_RPM_PATH")

# Upload tuning
RANGE_SIZE=5000000

# Curl options
CURL_BASE_OPTS="--silent --insecure"

#######################################
# PRECHECKS
#######################################
for bin in curl jq; do
  command -v "$bin" >/dev/null || {
    echo "❌ $bin requis"
    exit 1
  }
done

[[ -f "$DEVICES_FILE" ]] || {
  echo "❌ Fichier équipements introuvable : $DEVICES_FILE"
  exit 1
}

[[ -f "$AS3_RPM_PATH" ]] || {
  echo "❌ RPM AS3 introuvable : $AS3_RPM_PATH"
  exit 1
}

#######################################
# INPUTS
#######################################
read -p "Utilisateur API (ex: admin): " API_USER
read -s -p "Mot de passe API: " API_PASS
echo

CREDS="${API_USER}:${API_PASS}"

#######################################
# FUNCTIONS
#######################################
poll_task() {
  local TARGET="$1"
  local TASK_ID="$2"
  local STATUS="STARTED"

  while [[ "$STATUS" != "FINISHED" ]]; do
    sleep 1
    RESULT=$(curl $CURL_BASE_OPTS -u "$CREDS" \
      "https://${TARGET}/mgmt/shared/iapp/package-management-tasks/${TASK_ID}")

    STATUS=$(echo "$RESULT" | jq -r .status)

    if [[ "$STATUS" == "FAILED" ]]; then
      echo "❌ Échec :" \
        "$(echo "$RESULT" | jq -r .operation)" \
        "-" \
        "$(echo "$RESULT" | jq -r .errorMessage)"
      return 1
    fi
  done
}

wait_for_endpoint() {
  local TARGET="$1"
  local ENDPOINT="$2"
  local LABEL="$3"

  echo "🧪 Test $LABEL"
  until curl $CURL_BASE_OPTS -u "$CREDS" \
    --fail \
    "https://${TARGET}${ENDPOINT}" >/dev/null; do
    sleep 1
  done
}

show_as3_info() {
  local TARGET="$1"
  local INFO

  echo "🧪 AS3 /info (détails)"
  until INFO=$(curl $CURL_BASE_OPTS -u "$CREDS" \
    --fail \
    "https://${TARGET}/mgmt/shared/appsvcs/info"); do
    sleep 1
  done

  echo "$INFO" | jq .
}

#######################################
# MAIN LOOP
#######################################
echo
echo "🚀 Déploiement AS3 sur plusieurs BIG-IP"
echo "RPM : $RPM_NAME"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  TARGET=$(echo "$LINE" | tr -d '\r' | xargs)
  [[ -z "$TARGET" || "$TARGET" =~ ^# ]] && continue

  echo "======================================"
  echo "➡️  BIG-IP : $TARGET"
  echo "======================================"

  ###################################
  # QUERY existing AS3 packages
  ###################################
  echo "🔎 Recherche AS3 existant"
  TASK=$(curl $CURL_BASE_OPTS -u "$CREDS" \
    -H "Content-Type: application/json" \
    -X POST \
    "https://${TARGET}/mgmt/shared/iapp/package-management-tasks" \
    -d '{"operation":"QUERY"}')

  TASK_ID=$(echo "$TASK" | jq -r .id)
  poll_task "$TARGET" "$TASK_ID"

  AS3_PKGS=$(echo "$RESULT" | jq -r \
    '.queryResponse[].packageName | select(startswith("f5-appsvcs"))')

  ###################################
  # UNINSTALL existing AS3
  ###################################
  for PKG in $AS3_PKGS; do
    echo "🗑️  Désinstallation $PKG"
    DATA="{\"operation\":\"UNINSTALL\",\"packageName\":\"$PKG\"}"

    TASK=$(curl $CURL_BASE_OPTS -u "$CREDS" \
      -H "Content-Type: application/json" \
      -X POST \
      "https://${TARGET}/mgmt/shared/iapp/package-management-tasks" \
      -d "$DATA")

    poll_task "$TARGET" "$(echo "$TASK" | jq -r .id)"
  done

  ###################################
  # UPLOAD RPM (chunked)
  ###################################
  echo "⬆️  Upload AS3 RPM"
  LEN=$(wc -c "$AS3_RPM_PATH" | awk '{print $1}')
  CHUNKS=$(( LEN / RANGE_SIZE ))

  for i in $(seq 0 "$CHUNKS"); do
    START=$(( i * RANGE_SIZE ))
    END=$(( START + RANGE_SIZE ))
    END=$(( LEN < END ? LEN : END ))
    OFFSET=$(( START + 1 ))

    curl $CURL_BASE_OPTS -u "$CREDS" \
      -X POST \
      "https://${TARGET}/mgmt/shared/file-transfer/uploads/${RPM_NAME}" \
      --data-binary @<(tail -c +$OFFSET "$AS3_RPM_PATH") \
      -H "Content-Type: application/octet-stream" \
      -H "Content-Range: ${START}-$((END - 1))/${LEN}" \
      -H "Content-Length: $((END - START))" \
      -o /dev/null
  done

  ###################################
  # INSTALL AS3
  ###################################
  echo "📦 Installation AS3"
  DATA="{\"operation\":\"INSTALL\",\"packageFilePath\":\"/var/config/rest/downloads/${RPM_NAME}\"}"

  TASK=$(curl $CURL_BASE_OPTS -u "$CREDS" \
    -H "Content-Type: application/json" \
    -X POST \
    "https://${TARGET}/mgmt/shared/iapp/package-management-tasks" \
    -d "$DATA")

  poll_task "$TARGET" "$(echo "$TASK" | jq -r .id)"

  ###################################
  # TESTS AS3
  ###################################
  show_as3_info "$TARGET"
  wait_for_endpoint "$TARGET" "/mgmt/shared/appsvcs/declare/" "AS3 /declare"
  wait_for_endpoint "$TARGET" "/mgmt/shared/service-discovery/task" "Service Discovery"

  echo "✅ AS3 pleinement opérationnel sur $TARGET"
  echo

done < "$DEVICES_FILE"

echo "🎯 Déploiement AS3 terminé sur tous les équipements"
