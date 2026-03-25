#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"
CURL_OPTS=(-k -sS --connect-timeout 10 --max-time 30)

SYNC_POLL_SLEEP=3
SYNC_POLL_TIMEOUT=120
SYNC_RETRY_FORCE_ON_FAILURE=1

DEBUG=0
if [[ "${1:-}" == "--debug" || "${1:-}" == "-d" ]]; then
  DEBUG=1
fi

LOG_FILE="./ha_sync_debug_$(date +%Y%m%d-%H%M%S).log"

#######################################
# INPUTS
#######################################
read -rp "Utilisateur API: " USER
read -s -rp "Mot de passe API: " PASS
echo
AUTH=(-u "${USER}:${PASS}")

#######################################
# PRECHECKS
#######################################
for bin in curl jq awk tr grep wc date tee head; do
  command -v "$bin" >/dev/null || { echo "❌ $bin requis"; exit 1; }
done
[[ -f "$DEVICES_FILE" ]] || { echo "❌ Fichier $DEVICES_FILE introuvable"; exit 1; }

#######################################
# LOG / DEBUG
#######################################
log() {
  local msg="$*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

dbg() {
  (( DEBUG == 1 )) || return 0
  local msg="[DEBUG] $*"
  echo "$msg" >&2
  echo "$msg" >> "$LOG_FILE"
}

dump_json() {
  local title="$1"
  local json="$2"
  (( DEBUG == 1 )) || return 0
  {
    echo "----- DEBUG JSON: $title -----"
    printf "%s\n" "$json" | jq . 2>/dev/null || printf "%s\n" "$json"
    echo "----- END DEBUG JSON: $title -----"
  } >> "$LOG_FILE"
}

trim_line() {
  printf "%s" "$1" | tr -d '\r' | awk '{$1=$1;print}'
}

#######################################
# REST
#######################################
rest_get_or_empty() {
  local host="$1" path="$2" out rc
  dbg "GET https://${host}${path}"
  set +e
  out="$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" "https://${host}${path}")"
  rc=$?
  set -e
  dbg "GET rc=$rc path=$path"

  if [[ $rc -ne 0 || -z "${out:-}" ]]; then
    echo "{}"
    return 1
  fi

  echo "$out"
  return 0
}

rest_post_config_sync() {
  local host="$1" util_args="$2" payload out rc

  payload="$(jq -n --arg a "$util_args" '{command:"run", utilCmdArgs:$a}')"

  dbg "POST https://${host}/mgmt/tm/cm/config-sync"
  dbg "POST payload: $payload"

  set +e
  out="$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$payload" \
    "https://${host}/mgmt/tm/cm/config-sync")"
  rc=$?
  set -e

  dbg "POST rc=$rc"
  dump_json "POST /mgmt/tm/cm/config-sync response (${host})" "$out"

  if [[ $rc -ne 0 ]]; then
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
  dump_json "failover-status/stats (${host})" "$js"

  jq -r '
    [ .. | strings | select(test("\\bACTIVE\\b|\\bSTANDBY\\b";"i")) ][0] // "UNKNOWN"
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
# DEVICE-GROUPS
#######################################
get_all_device_groups_tsv() {
  local host="$1" js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/device-group?\$select=fullPath,type" || true)"
  dump_json "device-group (${host})" "$js"

  jq -r '
    (.items // [])[]
    | [.fullPath, .type] | @tsv
  ' <<<"$js" 2>/dev/null || true
}

normalize_dg_name() {
  local dg="${1:-}"
  dg="${dg##*/}"
  printf "%s" "$dg"
}

#######################################
# SYNC STATUS / COLOR
#######################################
get_sync_stats_json() {
  local host="$1" js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/sync-status/stats" || echo "{}")"
  dump_json "sync-status/stats (${host})" "$js"
  echo "$js"
}

get_global_sync_status_from_json() {
  local js="$1"
  jq -r '
    [ .. | objects | .status? | .description? ]
    | map(select(type=="string" and .!=""))
    | .[0] // "UNKNOWN"
  ' <<<"$js" 2>/dev/null
}

get_sync_color_from_json() {
  local js="$1"
  jq -r '
    [ .. | objects | .color? | .description? ]
    | map(select(type=="string" and .!=""))
    | .[0] // "unknown"
  ' <<<"$js" 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

get_dg_status_from_sync_json() {
  local dg_full="$1"
  local js="$2"
  local dg_short

  dg_short="$(normalize_dg_name "$dg_full")"

  jq -r --arg dg_full "$dg_full" --arg dg_short "$dg_short" '
    def allowed: "In Sync|Awaiting Initial Sync|Changes Pending|Not All Devices Synced|Syncing";

    [
      .. | objects | .description? // empty
      | select(type=="string")
      | select(
          test("(^|/)" + ($dg_short|gsub("\\\\";"\\\\\\\\")) + "\\s*\\((" + allowed + ")\\)"; "i")
          or
          test(($dg_full|gsub("\\\\";"\\\\\\\\")) + "\\s*\\((" + allowed + ")\\)"; "i")
        )
      | capture("(?<st>" + allowed + ")")
      | .st
    ][0] // "UNKNOWN"
  ' <<<"$js" 2>/dev/null
}

#######################################
# RULES
#######################################
decide_action() {
  local status="$1"
  local color="$2"

  case "${status}|${color}" in
    "Awaiting Initial Sync|blue")
      echo "sync"
      ;;
    "Changes Pending|yellow")
      echo "force"
      ;;
    "Changes Pending|red")
      echo "force"
      ;;
    "Not All Devices Synced|yellow")
      echo "sync"
      ;;
    "Not All Devices Synced|red")
      echo "force"
      ;;
    "Syncing|green")
      echo "none"
      ;;
    "In Sync|"*)
      echo "none"
      ;;
    *)
      echo "none"
      ;;
  esac
}

build_status_prompt() {
  local dg="$1"
  local dg_type="$2"
  local status="$3"
  local color="$4"
  local action="$5"

  case "$action" in
    force)
      printf "DG '%s' (%s) : color=%s, status=%s. Forcer la synchronisation ? (y/n) : " \
        "$dg" "$dg_type" "$color" "$status"
      ;;
    sync)
      printf "DG '%s' (%s) : color=%s, status=%s. Lancer la synchronisation ? (y/n) : " \
        "$dg" "$dg_type" "$color" "$status"
      ;;
    *)
      printf "DG '%s' (%s) : color=%s, status=%s. Aucune action requise. " \
        "$dg" "$dg_type" "$color" "$status"
      ;;
  esac
}

#######################################
# ACTIONS
#######################################
run_config_sync_to_group() {
  local host="$1" dg="$2"
  local resp result

  resp="$(rest_post_config_sync "$host" "to-group $dg")" || return 1
  result="$(jq -r '.commandResult // empty' <<<"$resp" 2>/dev/null || true)"
  [[ -n "${result:-}" ]] && log "ℹ️  Retour API : $result"
  return 0
}

run_force_full_load_push_to_group() {
  local host="$1" dg="$2"
  local resp result

  resp="$(rest_post_config_sync "$host" "force-full-load-push to-group $dg")" || return 1
  result="$(jq -r '.commandResult // empty' <<<"$resp" 2>/dev/null || true)"
  [[ -n "${result:-}" ]] && log "ℹ️  Retour API : $result"
  return 0
}

#######################################
# POLLING
#######################################
poll_dg_until_in_sync() {
  local host="$1"
  local dg_full="$2"
  local dg_type="$3"

  local start now js dg_status global_status color

  start="$(date +%s)"

  while true; do
    js="$(get_sync_stats_json "$host")"
    dg_status="$(get_dg_status_from_sync_json "$dg_full" "$js")"
    global_status="$(get_global_sync_status_from_json "$js")"
    color="$(get_sync_color_from_json "$js")"

    dbg "Polling $dg_full (type=$dg_type) => dg_status='$dg_status' global_status='$global_status' color='$color'"

    if [[ "$dg_type" == "sync-failover" ]]; then
      if [[ "$dg_status" == "In Sync" ]]; then
        log "✅ $dg_full : In Sync confirmé"
        return 0
      fi
    fi

    if [[ "$dg_type" == "sync-only" ]]; then
      if [[ "$dg_status" == "In Sync" ]]; then
        log "✅ $dg_full : In Sync confirmé"
        return 0
      fi

      if [[ "$dg_status" == "UNKNOWN" && "$global_status" != "Changes Pending" ]]; then
        log "✅ $dg_full : synchronisation OK (sync-only, plus de Changes Pending global)"
        return 0
      fi
    fi

    now="$(date +%s)"
    if (( now - start >= SYNC_POLL_TIMEOUT )); then
      log "⏱️  Timeout (${SYNC_POLL_TIMEOUT}s) — $dg_full dg_status=$dg_status global_status=$global_status color=$color"
      return 1
    fi

    sleep "$SYNC_POLL_SLEEP"
  done
}

run_action_with_validation() {
  local host="$1"
  local dg_full="$2"
  local dg_type="$3"
  local action="$4"

  if [[ "$action" == "force" ]]; then
    log "🚀 Lancement : force-full-load-push to-group $dg_full"
    run_force_full_load_push_to_group "$host" "$dg_full" || return 1
    log "⏳ Vérification du groupe..."
    poll_dg_until_in_sync "$host" "$dg_full" "$dg_type"
    return $?
  fi

  log "🚀 Lancement : config-sync to-group $dg_full"
  run_config_sync_to_group "$host" "$dg_full" || return 1
  log "⏳ Vérification du groupe..."
  if poll_dg_until_in_sync "$host" "$dg_full" "$dg_type"; then
    return 0
  fi

  if (( SYNC_RETRY_FORCE_ON_FAILURE == 1 )); then
    log "⚠️  Fallback : retry en force-full-load-push pour $dg_full"
    run_force_full_load_push_to_group "$host" "$dg_full" || return 1
    log "⏳ Vérification du groupe après fallback..."
    poll_dg_until_in_sync "$host" "$dg_full" "$dg_type"
    return $?
  fi

  return 1
}

#######################################
# BUILD CURRENT STATE
#######################################
build_current_state() {
  local host="$1"

  CURRENT_JS="$(get_sync_stats_json "$host")"
  CURRENT_GLOBAL_COLOR="$(get_sync_color_from_json "$CURRENT_JS")"
  CURRENT_GLOBAL_STATUS="$(get_global_sync_status_from_json "$CURRENT_JS")"
  CURRENT_DG_LIST_TSV="$(get_all_device_groups_tsv "$host" || true)"

  declare -gA DG_FULL_MAP=()
  declare -gA DG_TYPE_MAP=()
  declare -gA DG_STATUS_MAP=()
  declare -gA DG_ACTION_MAP=()

  while IFS=$'\t' read -r dg_full dg_type; do
    [[ -z "${dg_full:-}" || -z "${dg_type:-}" ]] && continue
    dg_short="$(normalize_dg_name "$dg_full")"

    DG_FULL_MAP["$dg_short"]="$dg_full"
    DG_TYPE_MAP["$dg_short"]="$dg_type"
    DG_STATUS_MAP["$dg_short"]="$(get_dg_status_from_sync_json "$dg_full" "$CURRENT_JS")"
    DG_ACTION_MAP["$dg_short"]="$(decide_action "${DG_STATUS_MAP[$dg_short]}" "$CURRENT_GLOBAL_COLOR")"

    dbg "STATE DG='$dg_full' type='$dg_type' dg_status='${DG_STATUS_MAP[$dg_short]}' global_status='$CURRENT_GLOBAL_STATUS' color='$CURRENT_GLOBAL_COLOR' action='${DG_ACTION_MAP[$dg_short]}'"
  done <<< "$CURRENT_DG_LIST_TSV"
}

list_needs() {
  NEEDS=()
  for dg_short in "${!DG_FULL_MAP[@]}"; do
    if [[ "${DG_TYPE_MAP[$dg_short]}" == "sync-failover" || "${DG_TYPE_MAP[$dg_short]}" == "sync-only" ]]; then
      if [[ "${DG_ACTION_MAP[$dg_short]}" == "sync" || "${DG_ACTION_MAP[$dg_short]}" == "force" ]]; then
        NEEDS+=("$dg_short")
      fi
    fi
  done
}

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0
FAILS=0

log ""
log "🔁 HA ConfigSync — recalcul dynamique des groupes"
log "Règle absolue : toute demande de synchronisation se fait uniquement depuis l'ACTIVE"
log "Fallback : sync standard -> force-full-load-push si échec"
log "Debug : $([[ $DEBUG -eq 1 ]] && echo ON || echo OFF)"
log "Log   : $LOG_FILE"
log ""

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST="$(trim_line "$LINE")"
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue
  COUNT=$((COUNT+1))

  log "======================================"
  log "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  log "======================================"

  ROLE_RAW="$(get_failover_role_raw "$HOST" || true)"
  ROLE="$(normalize_role "$ROLE_RAW")"

  log "Role brut : ${ROLE_RAW:-UNKNOWN}"
  log "Role norm : ${ROLE}"

  build_current_state "$HOST"

  log "Status global : $CURRENT_GLOBAL_STATUS"
  log "Color global  : $CURRENT_GLOBAL_COLOR"
  log ""
  log "Device-groups détectés :"
  for dg_short in "${!DG_FULL_MAP[@]}"; do
    printf "  - %-35s : %-24s color=%-8s (%s)\n" \
      "${DG_FULL_MAP[$dg_short]}" \
      "${DG_STATUS_MAP[$dg_short]}" \
      "$CURRENT_GLOBAL_COLOR" \
      "${DG_TYPE_MAP[$dg_short]}" | tee -a "$LOG_FILE"
  done

  list_needs

  if [[ "${#NEEDS[@]}" -eq 0 ]]; then
    log ""
    log "✅ Aucun device-group ne nécessite d'action selon les règles."
    log ""
    continue
  fi

  if [[ "$ROLE" != "ACTIVE" ]]; then
    log ""
    log "⚠️  Nombre de groupes à synchroniser : ${#NEEDS[@]}"
    idx=0
    for dg_short in "${NEEDS[@]}"; do
      idx=$((idx+1))
      log "  [$idx/${#NEEDS[@]}] ${DG_FULL_MAP[$dg_short]} (${DG_TYPE_MAP[$dg_short]}) : status=${DG_STATUS_MAP[$dg_short]} color=${CURRENT_GLOBAL_COLOR} action=${DG_ACTION_MAP[$dg_short]}"
    done
    log "ℹ️  Équipement non ACTIVE => aucune demande de synchronisation."
    log ""
    continue
  fi

  while true; do
    build_current_state "$HOST"
    list_needs

    if [[ "${#NEEDS[@]}" -eq 0 ]]; then
      log ""
      log "✅ Plus aucun groupe à synchroniser pour $HOST."
      log "📌 Bilan global final : status=$CURRENT_GLOBAL_STATUS color=$CURRENT_GLOBAL_COLOR"
      log ""
      break
    fi

    log ""
    log "⚠️  Groupes restant à synchroniser : ${#NEEDS[@]}"
    idx=0
    for dg_short in "${NEEDS[@]}"; do
      idx=$((idx+1))
      log "  [$idx/${#NEEDS[@]}] ${DG_FULL_MAP[$dg_short]} (${DG_TYPE_MAP[$dg_short]}) : status=${DG_STATUS_MAP[$dg_short]} color=${CURRENT_GLOBAL_COLOR} action=${DG_ACTION_MAP[$dg_short]}"
    done
    log ""

    # On propose toujours le premier groupe restant
    dg_short="${NEEDS[0]}"
    dg_full="${DG_FULL_MAP[$dg_short]}"
    dg_type="${DG_TYPE_MAP[$dg_short]}"
    st="${DG_STATUS_MAP[$dg_short]}"
    action="${DG_ACTION_MAP[$dg_short]}"

    log "--------------------------------------"
    log "Prochain groupe proposé"
    log "DG     : $dg_full"
    log "Type   : $dg_type"
    log "Status : $st"
    log "Color  : $CURRENT_GLOBAL_COLOR"
    log "Action : $action"

    prompt="$(build_status_prompt "$dg_full" "$dg_type" "$st" "$CURRENT_GLOBAL_COLOR" "$action")"
    read -r -p "$prompt" ans </dev/tty || ans="n"

    if [[ "${ans,,}" != "y" && "${ans,,}" != "yes" ]]; then
      log "⏭️  Groupe ignoré."
      # On enlève le groupe ignoré de cette itération en le marquant none localement
      DG_ACTION_MAP["$dg_short"]="none"
      continue
    fi

    if ! run_action_with_validation "$HOST" "$dg_full" "$dg_type" "$action"; then
      log "❌ Validation de synchronisation échouée pour $dg_full"
      FAILS=$((FAILS+1))
    fi

    build_current_state "$HOST"
    log "🌐 État global après traitement de $dg_full : status=$CURRENT_GLOBAL_STATUS color=$CURRENT_GLOBAL_COLOR"
    log ""
  done
done < "$DEVICES_FILE"

log "======================================"
log "🏁 Terminé"
log "Équipements traités : $COUNT"
log "Erreurs / Timeouts  : $FAILS"
log "======================================"
(( FAILS == 0 )) || exit 1