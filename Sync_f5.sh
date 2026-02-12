#!/usr/bin/env bash
set -euo pipefail

DEVICES_FILE="devices.txt"
SYNC_TIMEOUT=300
SYNC_SLEEP=3

for bin in curl jq grep awk tr wc date; do
  command -v "$bin" >/dev/null || { echo "❌ $bin requis"; exit 1; }
done
[[ -f "$DEVICES_FILE" ]] || { echo "❌ devices.txt introuvable"; exit 1; }

read -rp "Utilisateur API : " API_USER
read -s -rp "Mot de passe API : " API_PASS
echo

AUTH=(-u "${API_USER}:${API_PASS}")
CURL=(-k -sS --connect-timeout 10 --max-time 30)

###############################################
get_role() {
  curl "${CURL[@]}" "${AUTH[@]}" \
  "https://$1/mgmt/tm/cm/failover-status/stats" \
  | jq -r '
    [..|strings|select(test("ACTIVE|STANDBY"))][0] // "UNKNOWN"
  '
}

get_sync_status() {
  curl "${CURL[@]}" "${AUTH[@]}" \
  "https://$1/mgmt/tm/cm/sync-status/stats" \
  | jq -r '
    [..|strings
     | select(test("In Sync|Changes Pending|Not All Devices Synced|Out of Sync";"i"))
    ][0] // "UNKNOWN"
  '
}

get_device_group() {
  curl "${CURL[@]}" "${AUTH[@]}" \
  "https://$1/mgmt/tm/cm/device-group?\$select=fullPath,type" \
  | jq -r '
    (.items[] | select(.type=="sync-failover") | .fullPath) | .'
}

###############################################
run_sync() {
  local host="$1"
  local dg="$2"

  echo "🚀 Lancement sync via API officielle..."

  curl "${CURL[@]}" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"command\":\"run\",\"utilCmdArgs\":\"config-sync to-group ${dg}\"}" \
    "https://${host}/mgmt/tm/cm" \
    >/dev/null

  echo "⏳ Attente retour In Sync..."

  local start now s
  start=$(date +%s)

  while true; do
    s=$(get_sync_status "$host")

    if grep -qi "In Sync" <<<"$s" \
       && ! grep -qi "Changes Pending|Not All Devices Synced|Out of Sync" <<<"$s"; then
      echo "✅ Sync confirmée : $s"
      return 0
    fi

    now=$(date +%s)
    if (( now - start >= SYNC_TIMEOUT )); then
      echo "❌ Timeout (${SYNC_TIMEOUT}s) — dernier status : $s"
      return 1
    fi

    sleep "$SYNC_SLEEP"
  done
}

###############################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l)
COUNT=0

while IFS= read -r HOST || [[ -n "$HOST" ]]; do
  HOST=$(echo "$HOST" | tr -d '\r' | awk '{$1=$1;print}')
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue
  COUNT=$((COUNT+1))

  echo "======================================"
  echo "[$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  ROLE_RAW=$(get_role "$HOST")
  ROLE="UNKNOWN"
  if grep -qi ACTIVE <<<"$ROLE_RAW"; then ROLE="ACTIVE"; fi
  if grep -qi STANDBY <<<"$ROLE_RAW"; then ROLE="STANDBY"; fi

  SYNC_STATUS=$(get_sync_status "$HOST")
  DG=$(get_device_group "$HOST")

  echo "Role        : $ROLE_RAW"
  echo "Sync-status : $SYNC_STATUS"
  echo "Device-group: $DG"

  if [[ "$ROLE" != "ACTIVE" ]]; then
    echo "ℹ️  Non-ACTIVE => aucune synchro proposée."
    echo
    continue
  fi

  if grep -qi "In Sync" <<<"$SYNC_STATUS" \
     && ! grep -qi "Changes Pending|Not All Devices Synced|Out of Sync" <<<"$SYNC_STATUS"; then
    echo "✅ Déjà In Sync."
    echo
    continue
  fi

  echo "⚠️  L'ACTIVE n'est pas In Sync."
  read -r -p "Lancer la synchro ? (y/n) : " ans </dev/tty || ans="n"

  if [[ "${ans,,}" == "y" ]]; then
    run_sync "$HOST" "$DG"
  else
    echo "⏭️  Synchronisation ignorée."
  fi

  echo
done < "$DEVICES_FILE"

echo "🏁 Terminé"
