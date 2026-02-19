#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"

CURL_OPTS=(-k -sS --connect-timeout 10 --max-time 30)
SYNC_POLL_SLEEP=3
SYNC_POLL_TIMEOUT=300

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
# HA ROLE
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

#######################################
# DEVICE-GROUP sync-failover
#######################################
get_sync_failover_device_group() {
  local host="$1" js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/device-group?\$select=fullPath,type" || true)"
  jq -r '
    (.items // [])
    | map(select((.type // "") | test("sync-failover";"i")))
    | .[0].fullPath // empty
  ' <<<"$js" 2>/dev/null | head -n 1
}

#######################################
# SYNC STATUS + COLOR
#######################################
get_sync_stats_json() {
  local host="$1"
  rest_get_or_empty "$host" "/mgmt/tm/cm/sync-status/stats" || echo "{}"
}

get_sync_status_text() {
  local js="$1"
  jq -r '
    [ .. | strings
      | select(test("Changes Pending|In Sync|Not All Devices Synced|Out of Sync|out-of-sync";"i"))
    ][0] // "UNKNOWN"
  ' <<<"$js" 2>/dev/null | head -n 1
}

get_sync_color_desc() {
  local js="$1"
  jq -r '
    [ .. | objects | .color? | .description? ] | map(select(. != null)) | .[0] // "unknown"
  ' <<<"$js" 2>/dev/null | head -n 1
}

is_in_sync_text() {
  local s="${1:-}"
  if grep -qi "In Sync" <<<"$s" \
     && ! grep -qi "Changes Pending|Not All Devices Synced|Out of Sync|out-of-sync" <<<"$s"; then
    return 0
  fi
  return 1
}

#######################################
# ACTIONS (REST 100%)
#######################################
run_cm_config_sync() {
  local host="$1" dg="$2"
  curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"command\":\"run\",\"utilCmdArgs\":\"config-sync to-group ${dg}\"}" \
    "https://${host}/mgmt/tm/cm" >/dev/null
}

run_cm_force_full_load_push() {
  local host="$1" dg="$2"
  curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"command\":\"run\",\"utilCmdArgs\":\"config-sync force-full-load-push to-group ${dg}\"}" \
    "https://${host}/mgmt/tm/cm" >/dev/null
}

poll_until_in_sync() {
  local host="$1"
  local start now js status color

  start="$(date +%s)"
  while true; do
    js="$(get_sync_stats_json "$host")"
    status="$(get_sync_status_text "$js")"
    color="$(get_sync_color_desc "$js" | tr '[:upper:]' '[:lower:]')"

    dbg "poll status=$status color=$color"

    if is_in_sync_text "$status"; then
      echo "✅ In Sync confirmé (color=$color) : $status"
      return 0
    fi

    now="$(date +%s)"
    if (( now - start >= SYNC_POLL_TIMEOUT )); then
      echo "⏱️  Timeout (${SYNC_POLL_TIMEOUT}s) — dernier : status=$status color=$color"
      return 1
    fi

    sleep "$SYNC_POLL_SLEEP"
  done
}

#######################################
# DECISION ENGINE (3 règles)
#######################################
choose_sync_action() {
  # echo "FORCE" | "NORMAL" | "NONE"
  local status="$1" color="$2"

  # Règle 1 & 2: Changes Pending
  if grep -qi "Changes Pending" <<<"$status"; then
    if [[ "$color" == "red" ]]; then
      echo "FORCE"
    elif [[ "$color" == "yellow" ]]; then
      echo "NORMAL"
    else
      echo "NONE"
    fi
    return 0
  fi

  # ✅ Règle 3: Not All Devices Synced
  if grep -qi "Not All Devices Synced" <<<"$status"; then
    if [[ "$color" == "red" ]]; then
      echo "FORCE"
    elif [[ "$color" == "yellow" ]]; then
      echo "NORMAL"
    else
      # par défaut, on propose au moins un config-sync standard
      echo "NORMAL"
    fi
    return 0
  fi

  echo "NONE"
}

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0
FAILS=0

echo
echo "🔁 HA Sync (règles Status+Color) — proposition uniquement sur l'ACTIVE"
echo "Règles :"
echo "  1) Changes Pending + red    => force-full-load-push"
echo "  2) Changes Pending + yellow => config-sync standard"
echo "  3) Not All Devices Synced   => (red=>force, yellow=>standard, other=>standard)"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST="$(trim_line "$LINE")"
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue
  COUNT=$((COUNT+1))

  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  ROLE_RAW="$(get_failover_role_raw "$HOST" || true)"
  ROLE="$(normalize_role "$ROLE_RAW")"
  DG="$(get_sync_failover_device_group "$HOST" || true)"

  if [[ -z "${DG:-}" ]]; then
    echo "Role        : ${ROLE_RAW:-UNKNOWN}"
    echo "Device-group: NONE"
    echo "⚠️  Aucun device-group sync-failover => skip."
    echo
    continue
  fi

  JS="$(get_sync_stats_json "$HOST")"
  SYNC_STATUS="$(get_sync_status_text "$JS")"
  SYNC_COLOR="$(get_sync_color_desc "$JS" | tr '[:upper:]' '[:lower:]')"

  echo "Role        : ${ROLE_RAW:-UNKNOWN}"
  echo "Role (norm) : ${ROLE}"
  echo "Device-group: ${DG}"
  echo "Sync-status : ${SYNC_STATUS}"
  echo "Color       : ${SYNC_COLOR}"
  echo

  if [[ "$ROLE" != "ACTIVE" ]]; then
    echo "ℹ️  Non-ACTIVE => aucune proposition."
    echo
    continue
  fi

  if is_in_sync_text "$SYNC_STATUS"; then
    echo "✅ Déjà In Sync => aucune action."
    echo
    continue
  fi

  ACTION="$(choose_sync_action "$SYNC_STATUS" "$SYNC_COLOR")"

  case "$ACTION" in
    FORCE)
      echo "⚠️  Proposition : force-full-load-push (status=$SYNC_STATUS, color=$SYNC_COLOR)"
      read -r -p "Lancer 'force-full-load-push to-group ${DG}' ? (y/n) : " ans </dev/tty || ans="n"
      if [[ "${ans,,}" == "y" ]]; then
        echo "🚀 Lancement force-full-load-push..."
        if ! run_cm_force_full_load_push "$HOST" "$DG"; then
          echo "❌ Échec lancement (API)."
          FAILS=$((FAILS+1))
          echo
          continue
        fi
        echo "⏳ Attente In Sync..."
        poll_until_in_sync "$HOST" || FAILS=$((FAILS+1))
      else
        echo "⏭️  Action ignorée."
      fi
      ;;
    NORMAL)
      echo "⚠️  Proposition : config-sync standard (status=$SYNC_STATUS, color=$SYNC_COLOR)"
      read -r -p "Lancer 'config-sync to-group ${DG}' ? (y/n) : " ans </dev/tty || ans="n"
      if [[ "${ans,,}" == "y" ]]; then
        echo "🚀 Lancement config-sync..."
        if ! run_cm_config_sync "$HOST" "$DG"; then
          echo "❌ Échec lancement (API)."
          FAILS=$((FAILS+1))
          echo
          continue
        fi
        echo "⏳ Attente In Sync..."
        poll_until_in_sync "$HOST" || FAILS=$((FAILS+1))
      else
        echo "⏭️  Action ignorée."
      fi
      ;;
    NONE)
      echo "ℹ️  Aucun déclenchement selon les règles."
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