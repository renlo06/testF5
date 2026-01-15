#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIGURATION
#######################################
AS3_RPM_PATH="/XXXXXX/f5-appsvcs-3.45.0-5.noarch.rpm"
RANGE_SIZE=5000000
CONTENT_TYPE_JSON="Content-Type: application/json"

#######################################
# PRÉREQUIS
#######################################
for bin in curl jq wc awk seq; do
  command -v "$bin" >/dev/null || {
    echo "❌ Binaire requis manquant : $bin"
    exit 1
  }
done

[[ -f "$DEVICES_FILE" ]] || { echo "❌ Fichier équipements introuvable : $DEVICES_FILE"; exit 1; }
[[ -f "$AS3_RPM_PATH" ]] || { echo "❌ RPM AS3 introuvable : $AS3_RPM_PATH"; exit 1; }

RPM_NAME=$(basename "$AS3_RPM_PATH")
RPM_SIZE=$(wc -c "$AS3_RPM_PATH" | awk '{print $1}')

#######################################
# AUTHENTIFICATION
#######################################
read -p "Utilisateur BIG-IP (admin recommandé): " API_USER
read -s -p "Mot de passe BIG-IP: " API_PASS
echo

CURL_AUTH="-u ${API_USER}:${API_PASS} --insecure --silent"

#######################################
# FUNCTIONS
#######################################
poll_task() {
  local host="$1"
  local task_id="$2"
  local status="STARTED"

  while [[ "$status" != "FINISHED" ]]; do
    sleep 1
    RESULT=$(curl $CURL_AUTH \
      "https://${host}/mgmt/shared/iapp/package-management-tasks/${task_id}")
    status=$(echo "$RESULT" | jq -r .status)

    if [[ "$status" == "FAILED" ]]; then
      echo "❌ Échec sur $host : $(echo "$RESULT" | jq -r .errorMessage)"
      return 1
    fi
  done
}

upload_rpm() {
  local host="$1"
  local chunks=$((RPM_SIZE / RANGE_SIZE))

  echo "⬆️  Upload RPM sur $host"

  for i in $(seq 0 "$chunks"); do
    local start=$((i * RANGE_SIZE))
    local end=$((start + RANGE_SIZE))
    (( end > RPM_SIZE )) && end="$RPM_SIZE"
    local offset=$((start + 1))

    curl $CURL_AUTH \
      "https://${host}/mgmt/shared/file-transfer/uploads/${RPM_NAME}" \
      --data-binary @<(tail -c +"$offset" "$AS3_RPM_PATH") \
      -H "Content-Type: application/octet-stream" \
      -H "Content-Range: ${start}-$((end - 1))/${RPM_SIZE}" \
      -H "Content-Length: $((end - start))" \
      -o /dev/null
  done
}

#######################################
# MAIN LOOP
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l)
COUNT=0

echo
echo "🚀 Installation AS3"
echo "RPM    : $RPM_NAME"
echo "Cibles : $TOTAL BIG-IP"
echo

while IFS= read -r HOST || [[ -n "$HOST" ]]; do
  HOST=$(echo "$HOST" | tr -d '\r' | xargs)
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  COUNT=$((COUNT + 1))
  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  # QUERY packages
  TASK=$(curl $CURL_AUTH -X POST \
    "https://${HOST}/mgmt/shared/iapp/package-management-tasks" \
    -H "$CONTENT_TYPE_JSON" \
    -d '{"operation":"QUERY"}')

  poll_task "$HOST" "$(echo "$TASK" | jq -r .id)"

  AS3_PKGS=$(echo "$RESULT" | jq -r '.queryResponse[].packageName | select(startswith("f5-appsvcs"))')

  # UNINSTALL anciens AS3
  for PKG in $AS3_PKGS; do
    echo "🧹 Désinstallation $PKG"
    TASK=$(curl $CURL_AUTH -X POST \
      "https://${HOST}/mgmt/shared/iapp/package-management-tasks" \
      -H "$CONTENT_TYPE_JSON" \
      -d "{\"operation\":\"UNINSTALL\",\"packageName\":\"$PKG\"}")
    poll_task "$HOST" "$(echo "$TASK" | jq -r .id)"
  done

  # UPLOAD
  upload_rpm "$HOST"

  # INSTALL
  echo "📦 Installation AS3"
  TASK=$(curl $CURL_AUTH -X POST \
    "https://${HOST}/mgmt/shared/iapp/package-management-tasks" \
    -H "$CONTENT_TYPE_JSON" \
    -d "{\"operation\":\"INSTALL\",\"packageFilePath\":\"/var/config/rest/downloads/$RPM_NAME\"}")

  poll_task "$HOST" "$(echo "$TASK" | jq -r .id)"

  # WAIT API
  echo "⏳ Attente disponibilité AS3 API"
  until curl $CURL_AUTH --fail \
    "https://${HOST}/mgmt/shared/appsvcs/info" >/dev/null 2>&1; do
    sleep 2
  done

  echo "✅ AS3 installé sur $HOST"
  echo

done < "$DEVICES_FILE"

echo "🏁 Installation AS3 terminée sur tous les équipements"
