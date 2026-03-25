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
for bin in curl jq awk tr grep wc date sed mktemp; do
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
  echo "$msg"
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
  printf "%s" "${1:-}" | tr -d '\r' | awk '{$1=$1;print}'
}

normalize_text() {
  printf "%s" "${1:-}" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

normalize_lower() {
  normalize_text "${1:-}" | tr '[:upper:]' '[:lower:]'
}

#######################################
# REST
#######################################
rest_get() {
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
# FAILOVER / HA
#######################################
get_failover_status_json() {
  local host="$1" js
  js="$(rest_get "$host" "/mgmt/tm/cm/failover-status/stats" || true)"
  dump_json "failover-status/stats (${host})" "$js"
  echo "$js"
}

get_failover_role_raw() {
  local js="$1"

  jq -r '
    .entries
    | to_entries[0].value.nestedStats.entries.status.description
    // "UNKNOWN"
  ' <<<"$js" 2>/dev/null
}

normalize_role() {
  local raw
  raw="$(normalize_text "${1:-}")"
  if [[ "$raw" == "ACTIVE" ]]; then
    echo "ACTIVE"
  elif [[ "$raw" == "STANDBY" ]]; then
    echo "STANDBY"
  else
    echo "UNKNOWN"
  fi
}

#######################################
# DEVICE GROUPS / SYNC STATUS
#######################################
get_device_groups_json() {
  local host="$1" js
  js="$(rest_get "$host" "/mgmt/tm/cm/device-group?\$select=fullPath,type" || true)"
  dump_json "device-group (${host})" "$js"
  echo "$js"
}

get_all_device_groups_tsv() {
  local js="$1"
  jq -r '
    (.items // [])[]
    | [.fullPath, .type] | @tsv
  ' <<<"$js" 2>/dev/null
}

get_sync_stats_json() {
  local host="$1" js
  js="$(rest_get "$host" "/mgmt/tm/cm/sync-status/stats" || true)"
  dump_json "sync-status/stats (${host})" "$js"
  echo "$js"
}

get_global_sync_status_from_json() {
  local js="$1"

  jq -r '
    .entries
    | to_entries[0].value.nestedStats.entries.status.description
    // ""
  ' <<<"$js" 2>/dev/null
}

get_sync_color_from_json() {
  local js="$1"

  jq -r '
    .entries
    | to_entries[0].value.nestedStats.entries.color.description
    // ""
  ' <<<"$js" 2>/dev/null
}

normalize_dg_name() {
  local dg="${1:-}"
  dg="${dg##*/}"
  printf "%s" "$dg"
}

get_dg_status_from_sync_json() {
  local dg_full="$1"
  local js="$2"
  local dg_short

  dg_short="$(normalize_dg_name "$dg_full")"

  jq -r --arg dg "$dg_short" '
    def allowed: "In Sync|Awaiting Initial Sync|Changes Pending|Not All Devices Synced|Syncing";

    [
      .entries
      | to_entries[0].value.nestedStats.entries
      | to_entries[]
      | select(.key | test("/details/stats$"))
      | .value.nestedStats.entries
      | to_entries[]
      | .value.nestedStats.entries.details.description
      | select(type=="string")
      | select(test("^" + $dg + " \\((" + allowed + ")\\)"; "i"))
      | capture("^" + $dg + " \\((?<st>" + allowed + ")\\)")
      | .st
    ][0] // "UNKNOWN"
  ' <<<"$js" 2>/dev/null
}

#######################################
# RULES
#######################################
decide_action() {
  local status color
  status="$(normalize_text "${1:-}")"
  color="$(normalize_lower "${2:-}")"

  case "${status}|${color}" in
    "Awaiting Initial Sync|blue") echo "sync" ;;
    "Changes Pending|yellow") echo "force" ;;
    "Changes Pending|red") echo "force" ;;
    "Not All Devices Synced|yellow") echo "sync" ;;
    "Not All Devices Synced|red") echo "force" ;;
    "Syncing|green") echo "none" ;;
    "In Sync|"*) echo "none" ;;
    *) echo "none" ;;
  esac
}

build_status_prompt() {
  local dg="$1" dg_type="$2" status="$3" color="$4" action="$5"

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
  local host="$1" dg_full="$2" dg_type="$3"
  local start now js dg_status global_status color

  start="$(date +%s)"

  while true; do
    js="$(get_sync_stats_json "$host")"
    dg_status="$(normalize_text "$(get_dg_status_from_sync_json "$dg_full" "$js")")"
    global_status="$(normalize_text "$(get_global_sync_status_from_json "$js")")"
    color="$(normalize_lower "$(get_sync_color_from_json "$js")")"

    dbg "Polling $dg_full (type=$dg_type) => dg_status='$dg_status' global_status='$global_status' color='$color'"

    if [[ "$dg_type" == "sync-failover" ]]; then
      [[ "$dg_status" == "In Sync" ]] && { log "✅ $dg_full : In Sync confirmé"; return 0; }
    fi

    if [[ "$dg_type" == "sync-only" ]]; then
      [[ "$dg_status" == "In Sync" ]] && { log "✅ $dg_full : In Sync confirmé"; return 0; }
      [[ "$dg_status" == "UNKNOWN" && "$global_status" != "Changes Pending" ]] && {
        log "✅ $dg_full : synchronisation OK (sync-only, plus de Changes Pending global)"
        return 0
      }
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
  local host="$1" dg_full="$2" dg_type="$3" action="$4"

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
# BUILD LISTS
#######################################
build_current_lists() {
  local host="$1"
  local failover_js sync_js dg_js dg_list dg_full dg_type dg_status action
  local all_tmp needs_tmp

  all_tmp="$(mktemp)"
  needs_tmp="$(mktemp)"

  failover_js="$(get_failover_status_json "$host")"
  sync_js="$(get_sync_stats_json "$host")"
  dg_js="$(get_device_groups_json "$host")"

  CURRENT_ROLE_RAW="$(normalize_text "$(get_failover_role_raw "$failover_js")")"
  CURRENT_ROLE="$(normalize_role "$CURRENT_ROLE_RAW")"
  CURRENT_GLOBAL_STATUS="$(normalize_text "$(get_global_sync_status_from_json "$sync_js")")"
  CURRENT_GLOBAL_COLOR="$(normalize_lower "$(get_sync_color_from_json "$sync_js")")"
  dg_list="$(get_all_device_groups_tsv "$dg_js")"

  while IFS=$'\t' read -r dg_full dg_type; do
    [[ -z "${dg_full:-}" || -z "${dg_type:-}" ]] && continue

    dg_type="$(normalize_text "$dg_type")"
    dg_status="$(normalize_text "$(get_dg_status_from_sync_json "$dg_full" "$sync_js")")"
    action="$(normalize_text "$(decide_action "$dg_status" "$CURRENT_GLOBAL_COLOR")")"

    dbg "STATE DG='$dg_full' type='$dg_type' dg_status='$dg_status' global_status='$CURRENT_GLOBAL_STATUS' color='$CURRENT_GLOBAL_COLOR' action='$action'"

    printf "%s\t%s\t%s\t%s\t%s\n" \
      "$dg_full" "$dg_type" "$dg_status" "$CURRENT_GLOBAL_COLOR" "$action" >> "$all_tmp"

    if [[ "$dg_type" == "sync-failover" && ( "$action" == "sync" || "$action" == "force" ) ]]; then
      printf "%s\t%s\t%s\t%s\t%s\n" \
        "$dg_full" "$dg_type" "$dg_status" "$CURRENT_GLOBAL_COLOR" "$action" >> "$needs_tmp"
    fi
  done <<< "$dg_list"

  while IFS=$'\t' read -r dg_full dg_type; do
    [[ -z "${dg_full:-}" || -z "${dg_type:-}" ]] && continue

    dg_type="$(normalize_text "$dg_type")"
    dg_status="$(normalize_text "$(get_dg_status_from_sync_json "$dg_full" "$sync_js")")"
    action="$(normalize_text "$(decide_action "$dg_status" "$CURRENT_GLOBAL_COLOR")")"

    if [[ "$dg_type" == "sync-only" && ( "$action" == "sync" || "$action" == "force" ) ]]; then
      printf "%s\t%s\t%s\t%s\t%s\n" \
        "$dg_full" "$dg_type" "$dg_status" "$CURRENT_GLOBAL_COLOR" "$action" >> "$needs_tmp"
    fi
  done <<< "$dg_list"

  ALL_GROUPS_TSV="$(cat "$all_tmp")"
  NEEDS_TSV="$(cat "$needs_tmp")"

  dbg "LIST_NEEDS result_count=$(printf "%s\n" "$NEEDS_TSV" | sed '/^$/d' | wc -l | awk '{print $1}')"

  rm -f "$all_tmp" "$needs_tmp"
}

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0
FAILS=0

log ""
log "🔁 HA ConfigSync — parseurs exacts"
log "Règle absolue : synchronisation uniquement depuis l'ACTIVE"
log "Priorité : sync-failover puis sync-only"
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

  build_current_lists "$HOST"

  log "Role brut : ${CURRENT_ROLE_RAW:-UNKNOWN}"
  log "Role norm : ${CURRENT_ROLE:-UNKNOWN}"
  log "Status global : ${CURRENT_GLOBAL_STATUS:-}"
  log "Color global  : ${CURRENT_GLOBAL_COLOR:-}"
  log ""

  if [[ "${CURRENT_ROLE:-UNKNOWN}" == "UNKNOWN" ]]; then
    log "❌ Rôle HA non exploitable via REST pour $HOST"
    log ""
    FAILS=$((FAILS+1))
    continue
  fi

  if [[ -z "${CURRENT_GLOBAL_STATUS:-}" || -z "${CURRENT_GLOBAL_COLOR:-}" ]]; then
    log "❌ Sync status non exploitable via REST pour $HOST"
    log ""
    FAILS=$((FAILS+1))
    continue
  fi

  log "Device-groups détectés :"
  if [[ -n "${ALL_GROUPS_TSV:-}" ]]; then
    while IFS=$'\t' read -r dg_full dg_type dg_status dg_color dg_action; do
      [[ -z "${dg_full:-}" ]] && continue
      log "  - $dg_full : status=$dg_status color=$dg_color type=$dg_type action=$dg_action"
    done <<< "$ALL_GROUPS_TSV"
  else
    log "  (aucun device-group retourné)"
  fi

  NEEDS_COUNT="$(printf "%s\n" "${NEEDS_TSV:-}" | sed '/^$/d' | wc -l | awk '{print $1}')"

  if [[ "$NEEDS_COUNT" -eq 0 ]]; then
    log ""
    log "✅ Aucun device-group ne nécessite d'action selon les règles."
    log ""
    continue
  fi

  if [[ "$CURRENT_ROLE" != "ACTIVE" ]]; then
    log ""
    log "⚠️  Nombre de groupes à synchroniser : $NEEDS_COUNT"
    idx=0
    while IFS=$'\t' read -r dg_full dg_type dg_status dg_color dg_action; do
      [[ -z "${dg_full:-}" ]] && continue
      idx=$((idx+1))
      log "  [$idx/$NEEDS_COUNT] $dg_full ($dg_type) : status=$dg_status color=$dg_color action=$dg_action"
    done <<< "$NEEDS_TSV"
    log "ℹ️  Équipement non ACTIVE => aucune demande de synchronisation."
    log ""
    continue
  fi

  while true; do
    build_current_lists "$HOST"
    NEEDS_COUNT="$(printf "%s\n" "${NEEDS_TSV:-}" | sed '/^$/d' | wc -l | awk '{print $1}')"

    if [[ "$NEEDS_COUNT" -eq 0 ]]; then
      log ""
      log "✅ Plus aucun groupe à synchroniser pour $HOST."
      log "📌 Bilan global final : status=$CURRENT_GLOBAL_STATUS color=$CURRENT_GLOBAL_COLOR"
      log ""
      break
    fi

    log ""
    log "⚠️  Groupes restant à synchroniser : $NEEDS_COUNT"
    idx=0
    while IFS=$'\t' read -r dg_full dg_type dg_status dg_color dg_action; do
      [[ -z "${dg_full:-}" ]] && continue
      idx=$((idx+1))
      log "  [$idx/$NEEDS_COUNT] $dg_full ($dg_type) : status=$dg_status color=$dg_color action=$dg_action"
    done <<< "$NEEDS_TSV"
    log ""

    FIRST_LINE="$(printf "%s\n" "$NEEDS_TSV" | sed -n '1p')"
    dg_full="$(printf "%s" "$FIRST_LINE" | awk -F'\t' '{print $1}')"
    dg_type="$(printf "%s" "$FIRST_LINE" | awk -F'\t' '{print $2}')"
    dg_status="$(printf "%s" "$FIRST_LINE" | awk -F'\t' '{print $3}')"
    dg_color="$(printf "%s" "$FIRST_LINE" | awk -F'\t' '{print $4}')"
    dg_action="$(printf "%s" "$FIRST_LINE" | awk -F'\t' '{print $5}')"

    log "--------------------------------------"
    log "Prochain groupe proposé"
    log "DG     : $dg_full"
    log "Type   : $dg_type"
    log "Status : $dg_status"
    log "Color  : $dg_color"
    log "Action : $dg_action"

    prompt="$(build_status_prompt "$dg_full" "$dg_type" "$dg_status" "$dg_color" "$dg_action")"
    read -r -p "$prompt" ans </dev/tty || ans="n"

    if [[ "${ans,,}" != "y" && "${ans,,}" != "yes" ]]; then
      log "⏭️  Groupe ignoré."
      NEEDS_TSV="$(printf "%s\n" "$NEEDS_TSV" | sed '1d')"
      continue
    fi

    if ! run_action_with_validation "$HOST" "$dg_full" "$dg_type" "$dg_action"; then
      log "❌ Validation de synchronisation échouée pour $dg_full"
      FAILS=$((FAILS+1))
    fi

    build_current_lists "$HOST"
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