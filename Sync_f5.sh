#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"
CURL_OPTS=(-k -sS --connect-timeout 10 --max-time 25)
DEBUG=0

if [[ "${1:-}" == "--debug" || "${1:-}" == "-d" ]]; then
  DEBUG=1
fi

#######################################
# PRECHECKS
#######################################
for bin in curl jq awk tr grep wc; do
  command -v "$bin" >/dev/null || { echo "❌ $bin requis"; exit 1; }
done
[[ -f "$DEVICES_FILE" ]] || { echo "❌ Fichier équipements introuvable : $DEVICES_FILE"; exit 1; }

#######################################
# INPUTS
#######################################
read -rp "Utilisateur API (REST, ex: admin): " API_USER
read -s -rp "Mot de passe API (REST): " API_PASS
echo
AUTH=(-u "${API_USER}:${API_PASS}")

dbg() { (( DEBUG == 1 )) && echo "🟦 [DEBUG] $*" >&2 || true; }

trim_line() { printf "%s" "$1" | tr -d '\r' | awk '{$1=$1;print}'; }

rest_get() {
  local host="$1" path="$2"
  curl "${CURL_OPTS[@]}" "${AUTH[@]}" "https://${host}${path}"
}

rest_get_or_empty() {
  local host="$1" path="$2" out rc
  set +e
  out="$(rest_get "$host" "$path")"
  rc=$?
  set -e
  if [[ $rc -ne 0 || -z "${out:-}" ]]; then
    echo "{}"
    return 1
  fi
  echo "$out"
  return 0
}

#######################################
# PARSERS (robustes)
#######################################
# Extrait la valeur "Status" depuis un payload stats cm::* (ACTIVE/STANDBY) ou "In Sync" etc.
extract_cm_status() {
  jq -r '
    def scan_status:
      [ .. | objects
        | to_entries[]
        | select(.key|tostring|test("^status$|^Status$"))
        | .value
        | ( .description? // .value? // . )
        | select(type=="string" and .!="")
      ][0] // empty;

    def scan_status_label:
      [ .. | objects
        | to_entries[]
        | select(.key|tostring|test("^status$|^Status$"))
        | .value.description?
        | select(type=="string" and .!="")
      ][0] // empty;

    # Cas le plus fréquent: nestedStats.entries.Status.description
    (
      .entries? // .nestedStats? // .
    ) as $root
    | (
        $root | scan_status
      ) // empty
  ' 2>/dev/null
}

# Récupère le rôle ACTIVE/STANDBY via failover-status
get_failover_role() {
  local host="$1"
  local js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/failover-status/stats" || true)"
  # on cherche le premier "Status" qui ressemble à ACTIVE/STANDBY
  jq -r '
    def first_string($re):
      [ .. | strings | select(test($re;"i")) ][0] // empty;
    # essais: "ACTIVE"/"STANDBY" présents dans les strings
    ( first_string("\\bACTIVE\\b") // first_string("\\bSTANDBY\\b") // first_string("\\bSTANDBY\\b") ) as $s
    | if $s == "" then "UNKNOWN" else ($s | ascii_upcase) end
  ' <<<"$js" 2>/dev/null | head -n 1
}

# Récupère le sync-status (In Sync / Changes Pending / Not All Devices Synced ...)
get_sync_status() {
  local host="$1"
  local js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/sync-status/stats" || true)"
  # on cherche une string type "In Sync", "Changes Pending", "Not All Devices Synced"
  jq -r '
    def pick_sync:
      [ .. | strings
        | select(test("In Sync|Changes Pending|Not All Devices Synced";"i"))
      ][0] // empty;

    (pick_sync) as $s
    | if $s == "" then "UNKNOWN" else $s end
  ' <<<"$js" 2>/dev/null | head -n 1
}

# Choisit automatiquement le 1er device-group de type sync-failover
get_sync_failover_device_group() {
  local host="$1"
  local js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/device-group?\$select=name,fullPath,type" || true)"
  jq -r '
    (.items // [])
    | map(select((.type // "") | test("sync-failover";"i")))
    | .[0].fullPath // .[0].name // empty
  ' <<<"$js" 2>/dev/null | head -n 1
}

#######################################
# ACTION: Config-Sync (REST util/bash)
#######################################
run_config_sync_to_group() {
  local host="$1" dg="$2"

  # tmsh: run cm config-sync to-group <dg>
  # via REST: /mgmt/tm/util/bash
  local payload
  payload=$(jq -n --arg dg "$dg" \
    '{command:"run", utilCmdArgs:("-lc tmsh run cm config-sync to-group \"" + $dg + "\"") }')

  dbg "run config-sync on $host to-group=$dg"
  curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$payload" \
    "https://${host}/mgmt/tm/util/bash" >/dev/null
}

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0
FAILS=0

echo
echo "🔁 HA Sync helper — propose la synchro UNIQUEMENT sur l'ACTIVE si sync-status ≠ In Sync"
echo "Debug : $([[ $DEBUG -eq 1 ]] && echo ON || echo OFF)"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST="$(trim_line "$LINE")"
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue
  COUNT=$((COUNT+1))

  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  ROLE="$(get_failover_role "$HOST" || true)"
  SYNC_STATUS="$(get_sync_status "$HOST" || true)"
  DG="$(get_sync_failover_device_group "$HOST" || true)"

  echo "Role       : ${ROLE}"
  echo "Sync-status : ${SYNC_STATUS}"
  echo "Device-group: ${DG:-NONE}"

  # si pas de DG -> rien à faire
  if [[ -z "${DG:-}" ]]; then
    echo "⚠️  Aucun device-group sync-failover détecté, skip."
    echo
    continue
  fi

  # Proposer UNIQUEMENT sur l'ACTIVE
  if [[ "$ROLE" != "ACTIVE" ]]; then
    echo "ℹ️  Non-ACTIVE => aucune proposition de synchro."
    echo
    continue
  fi

  # Proposer dès que ce n'est pas In Sync (quel que soit le message)
  if grep -qi '^In Sync$' <<<"$SYNC_STATUS"; then
    echo "✅ In Sync => aucune action."
    echo
    continue
  fi

  echo "⚠️  L'ACTIVE n'est pas In Sync."
  # prompt sur /dev/tty (sinon boucle/lecture du fichier)
  read -r -p "➡️  Lancer 'config-sync to-group ${DG}' depuis l'ACTIVE ? (y/n) : " ans </dev/tty || ans="n"
  case "${ans,,}" in
    y|yes)
      if run_config_sync_to_group "$HOST" "$DG"; then
        echo "🚀 Sync lancé."
        sleep 2
        NEW_SYNC="$(get_sync_status "$HOST" || true)"
        echo "Sync-status après : ${NEW_SYNC}"
      else
        echo "❌ Échec lancement sync."
        FAILS=$((FAILS+1))
      fi
      ;;
    *)
      echo "⏭️  Sync non lancée."
      ;;
  esac

  echo
done < "$DEVICES_FILE"

echo "======================================"
echo "🏁 Terminé"
echo "Équipements traités : $COUNT"
echo "Erreurs            : $FAILS"
echo "======================================"
(( FAILS == 0 )) || exit 1
