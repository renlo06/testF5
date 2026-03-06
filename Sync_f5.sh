#!/usr/bin/env bash
set -euo pipefail

DEVICES_FILE="devices.txt"
CURL_OPTS="-sk"

read -p "Utilisateur API: " USER
read -s -p "Mot de passe: " PASS
echo

get_role() {

curl $CURL_OPTS -u "$USER:$PASS" \
https://$1/mgmt/tm/cm/failover-status/stats \
| jq -r '.. | strings | select(test("ACTIVE|STANDBY"))' \
| head -1

}

get_sync_status() {

curl $CURL_OPTS -u "$USER:$PASS" \
https://$1/mgmt/tm/cm/sync-status \
| jq -r '.entries[]?.nestedStats?.entries?.status?.description' 2>/dev/null

}

get_device_groups() {

curl $CURL_OPTS -u "$USER:$PASS" \
https://$1/mgmt/tm/cm/device-group \
| jq -r '.items[] | select(.type=="sync-failover") | .fullPath'

}

sync_group() {

HOST=$1
DG=$2

echo "🚀 Lancement sync : $DG"

curl $CURL_OPTS -u "$USER:$PASS" \
-H "Content-Type: application/json" \
-X POST \
-d "{\"command\":\"run\",\"utilCmdArgs\":\"config-sync to-group $DG\"}" \
https://$HOST/mgmt/tm/cm >/dev/null

}

echo

COUNT=0
TOTAL=$(grep -Ev '^#|^$' $DEVICES_FILE | wc -l)

while read HOST
do

[[ -z "$HOST" || "$HOST" =~ ^# ]] && continue
COUNT=$((COUNT+1))

echo "======================================"
echo "[$COUNT/$TOTAL] BIG-IP : $HOST"
echo "======================================"

ROLE=$(get_role $HOST)

echo "Role : $ROLE"

SYNC_STATUS=$(get_sync_status $HOST)

echo "Sync-status : $SYNC_STATUS"

DG_LIST=$(get_device_groups $HOST)

echo
echo "Device-groups :"

echo "$DG_LIST"

echo

if [[ "$ROLE" != *ACTIVE* ]]; then
    echo "ℹ️ Non ACTIVE → aucune synchro"
    echo
    continue
fi

case "$SYNC_STATUS" in

"In Sync")

echo "✅ Cluster synchronisé"
;;

"Awaiting Initial Sync")

echo "⚠ Awaiting Initial Sync"
for DG in $DG_LIST
do
read -p "Initial sync pour $DG ? (y/n): " A
[[ "$A" == "y" ]] && sync_group $HOST $DG
done
;;

"Changes Pending")

echo "⚠ Changes Pending"
for DG in $DG_LIST
do
read -p "Synchroniser $DG ? (y/n): " A
[[ "$A" == "y" ]] && sync_group $HOST $DG
done
;;

"Not All Devices Synced")

echo "⚠ Not All Devices Synced"
for DG in $DG_LIST
do
read -p "Relancer sync $DG ? (y/n): " A
[[ "$A" == "y" ]] && sync_group $HOST $DG
done
;;

*)

echo "Statut inconnu"

;;

esac

echo

done < $DEVICES_FILE

echo "Terminé"
