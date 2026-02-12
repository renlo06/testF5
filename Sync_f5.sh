#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"

# Curl "lecture" (rapide)
CURL_OPTS=(-k -sS --connect-timeout 10 --max-time 25)

# Poll sync
SYNC_POLL_SLEEP=3
SYNC_POLL_TIMEOUT=300  # 5 min

DEBUG=0
if [[ "${1:-}" == "--debug" || "${1:-}" == "-d" ]]; then
  DEBUG=1
fi

#######################################
# PRECHECKS
#######################################
for bin in curl jq awk tr grep wc date; do
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

rest_get_or_empty() {
  local host="$1" path="$2" out rc
  set +e
  out="$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" "https://${host}${path}")"
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
# ROLE / SYNC / DG
#######################################
get_failover_role_raw() {
  local host="$1" js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/failover-status/stats" || true)"
  jq -r '
    def first_string($re):
      [ .. | strings | select(test($re;"i")) ][0] // empty;
    ( first_string("\\bACTIVE\\b") // first_string("\\bSTANDBY\\b") ) as $s
    | if $s == "" then "UNKNOWN" else $s end
  ' <<<"$js" 2>/dev/null | head -n 1
}

normalize_role() {
  local raw="${1:-}"
  if grep -qi "\bACTIVE\b" <<<"$raw"; then
    echo "ACTIVE"
  elif grep -qi "\bSTANDBY\b" <<<"$raw"; then
    echo "STANDBY"
  else
    echo "UNKNOWN"
  fi
}

get_sync_status() {
  local host="$1" js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/sync-status/stats" || true)"
  jq -r '
    def pick:
      [ .. | strings
        | select(test("In Sync|Changes Pending|Not All Devices Synced|Out of Sync|out-of-sync";"i"))
      ][0] // empty;
    (pick) as $s
    | if $s == "" then "UNKNOWN" else $s end
  ' <<<"$js" 2>/dev/null | head -n 1
}

# ✅ In Sync “robuste” (phrase longue OK)
is_in_sync() {
  local s="${1:-}"
  if grep -qi "In Sync" <<<"$s" \
     && ! grep -qi "Not All Devices Synced|Changes Pending|Out of Sync|out-of-sync" <<<"$s"; then
    return 0
  fi
  return 1
}

get_sync_failover_device_group() {
  local host="$1" js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/device-group?\$select=name,fullPath,type" || true)"
  jq -r '
    (.items // [])
    | map(select((.type // "") | test("sync-failover";"i")))
    | .[0].fullPath // .[0].name // empty
  ' <<<"$js" 2>/dev/null | head -n 1
}

#######################################
# ACTION: Config-Sync (REST, non bloquant)
#######################################
run_config_sync_to_group_async() {
  local host="$1" dg="$2"

  # ✅ Important : on background la commande tmsh pour que l'API réponde tout de suite
  # et éviter le timeout curl.
  local cmd payload
  cmd="nohup tmsh run cm config-sync to-group \"${dg}\" >/dev/null 2>&1 &"

  payload="$(jq -n --arg cmd "$cmd" \
    '{command:"run", utilCmdArgs:("-lc " + $cmd)}')"

  dbg "POST util/bash async config-sync on $host to-group=$dg"
  curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$payload" \
    "https://${host}/mgmt/tm/util/bash" >/dev/null
}

poll_until_in_sync() {
  local host="$1"
  local start now
  start="$(date +%s)"

  while true; do
    local s
    s="$(get_sync_status "$host" || true)"
    dbg "poll sync-status: $s"

    if is_in_sync "$s"; then
      echo "✅ Sync-status : $s"
      return 0
    fi

    now="$(date +%s)"
    if (( now - start >= SYNC_POLL_TIMEOUT )); then
      echo "⏱️  Timeout (${SYNC_POLL_TIMEOUT}s) — dernier sync-status : $s"
      return 1
    fi

    sleep "$SYNC_POLL_SLEEP"
  done
}

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0
FAILS=0

echo
echo "🔁 HA Sync helper — propose la synchro UNIQUEMENT sur l'ACTIVE si sync-status ≠ In Sync"
echo "Poll : ${SYNC_POLL_TIMEOUT}s (sleep ${SYNC_POLL_SLEEP}s)"
echo "Debug: $([[ $DEBUG -eq 1 ]] && echo ON || echo OFF)"
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

  # ✅ Proposition uniquement sur l'ACTIVE
  if [[ "$ROLE" != "ACTIVE" ]]; then
    echo "ℹ️  Non-ACTIVE => aucune proposition de synchro."
    echo
    continue
  fi

  # ✅ Si déjà In Sync => rien
  if is_in_sync "${SYNC_STATUS:-}"; then
    echo "✅ In Sync => aucune action."
    echo
    continue
  fi

  echo "⚠️  L'ACTIVE n'est pas In Sync."
  read -r -p "➡️  Lancer 'config-sync to-group ${DG}' depuis l'ACTIVE ? (y/n) : " ans </dev/tty || ans="n"

  case "${ans,,}" in
    y|yes)
      if run_config_sync_to_group_async "$HOST" "$DG"; then
        echo "🚀 Sync lancée (async). Attente retour In Sync..."
        if ! poll_until_in_sync "$HOST"; then
          echo "❌ Sync non confirmée In Sync dans le délai."
          FAILS=$((FAILS+1))
        fi
      else
        echo "❌ Échec lancement sync (appel REST)."
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
