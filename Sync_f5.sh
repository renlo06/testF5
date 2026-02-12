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
# ROLE / SYNC / DG (REST)
#######################################
get_failover_role_raw() {
  local host="$1"
  local js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/failover-status/stats" || true)"

  # On récupère une string contenant ACTIVE/STANDBY (ex: "ACTIVE FOR /Common/traffic-group-1")
  jq -r '
    def first_string($re):
      [ .. | strings | select(test($re;"i")) ][0] // empty;

    ( first_string("\\bACTIVE\\b") // first_string("\\bSTANDBY\\b") ) as $s
    | if $s == "" then "UNKNOWN" else $s end
  ' <<<"$js" 2>/dev/null | head -n 1
}

normalize_role() {
  local raw="$1"
  if grep -qi "\bACTIVE\b" <<<"$raw"; then
    echo "ACTIVE"
  elif grep -qi "\bSTANDBY\b" <<<"$raw"; then
    echo "STANDBY"
  else
    echo "UNKNOWN"
  fi
}

get_sync_status() {
  local host="$1"
  local js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/sync-status/stats" || true)"
  jq -r '
    def pick_sync:
      [ .. | strings
        | select(test("In Sync|Changes Pending|Not All Devices Synced|Out of Sync|out-of-sync";"i"))
      ][0] // empty;

    (pick_sync) as $s
    | if $s == "" then "UNKNOWN" else $s end
  ' <<<"$js" 2>/dev/null | head -n 1
}

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

  local payload
  payload="$(jq -n --arg dg "$dg" \
    '{command:"run", utilCmdArgs:("-lc tmsh run cm config-sync to-group \"" + $dg + "\"") }')"

  dbg "POST /mgmt/tm/util/bash (config-sync to-group \"$dg\") on $host"
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

  ROLE_RAW="$(get_failover_role_raw "$HOST" || true)"
  ROLE="$(normalize_role "${ROLE_RAW:-UNKNOWN}")"
  SYNC_STATUS="$(get_sync_status "$HOST" || true)"
  DG="$(get_sync_failover_device_group "$HOST" || true)"

  echo "Role        : ${ROLE_RAW:-UNKNOWN}"
  echo "Role (norm) : ${ROLE}"
  echo "Sync-status : ${SYNC_STATUS:-UNKNOWN}"
  echo "Device-group: ${DG:-NONE}"

  if [[ -z "${DG:-}" ]]; then
    echo "⚠️  Aucun device-group sync-failover détecté, skip."
    echo
    continue
  fi

  # ✅ CORRECTION: on se base sur ROLE normalisé, pas sur égalité stricte de la chaîne raw
  if [[ "$ROLE" != "ACTIVE" ]]; then
    echo "ℹ️  Non-ACTIVE => aucune proposition de synchro."
    echo
    continue
  fi

  # Proposer dès que ce n'est pas In Sync (peu importe Changes Pending / Not All Devices Synced / etc.)
  if grep -qi '^In Sync$' <<<"${SYNC_STATUS:-}"; then
    echo "✅ In Sync => aucune action."
    echo
    continue
  fi

  echo "⚠️  L'ACTIVE n'est pas In Sync."
  # Important: lire sur /dev/tty pour ne pas consommer devices.txt
  read -r -p "➡️  Lancer 'config-sync to-group ${DG}' depuis l'ACTIVE ? (y/n) : " ans </dev/tty || ans="n"

  case "${ans,,}" in
    y|yes)
      if run_config_sync_to_group "$HOST" "$DG"; then
        echo "🚀 Sync lancé."
        sleep 2
        NEW_SYNC="$(get_sync_status "$HOST" || true)"
        echo "Sync-status après : ${NEW_SYNC:-UNKNOWN}"
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
