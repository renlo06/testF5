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
for bin in curl jq awk tr grep wc date tee; do
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
  local msg="🟦 [DEBUG] $*"
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

rest_post_cm_command() {
  local host="$1" cmd="$2" payload out rc

  payload="$(jq -n --arg c "$cmd" '{command:"run", utilCmdArgs:$c}')"

  dbg "POST https://${host}/mgmt/tm/cm"
  dbg "POST payload: $payload"

  set +e
  out="$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$payload" \
    "https://${host}/mgmt/tm/cm")"
  rc=$?
  set -e

  dbg "POST rc=$rc"
  dump_json "POST /mgmt/tm/cm response (${host})" "$out"

  [[ $rc -eq 0 ]]
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
# fullPath<TAB>type
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

# Cherche le statut pour un DG donné
# Retourne: In Sync / Awaiting Initial Sync / Changes Pending / Not All Devices Synced / Syncing / UNKNOWN
get_dg_status_from_sync_json() {
  local dg_short="$1"
  local js="$2"

  jq -r --arg dg "$dg_short" '
    def allowed: "In Sync|Awaiting Initial Sync|Changes Pending|Not All Devices Synced|Syncing";

    [ .. | strings
      | select(test("^" + ($dg|gsub("\\\\";"\\\\\\\\")) + "\\s*\\((" + allowed + ")\\)"; "i"))
      | capture("^" + ($dg|gsub("\\\\";"\\\\\\\\")) + "\\s*\\((?<st>" + allowed + ")\\)")
      | .st
    ][0] // "UNKNOWN"
  ' <<<"$js" 2>/dev/null
}

# Couleur globale du sync-status
get_sync_color_from_sync_json() {
  local js="$1"
  jq -r '
    [ .. | objects | .color? | .description? ]
    | map(select(type=="string" and .!=""))
    | .[0] // "unknown"
  ' <<<"$js" 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

#######################################
# RULES
#######################################
# Retourne l'action à lancer selon status + color :
#   sync   => config-sync to-group
#   force  => config-sync force-full-load-push to-group
#   none   => aucune action
decide_action() {
  local status="$1"
  local color="$2"

  case "${color}|${status}" in
    blue\|Awaiting\ Initial\ Sync)
      echo "sync"
      ;;
    yellow\|Changes\ Pending)
      echo "sync"
      ;;
    red\|Not\ All\ Devices\ Synced)
      echo "force"
      ;;
    green\|Syncing)
      echo "none"
      ;;
    *\|In\ Sync)
      echo "none"
      ;;
    *)
      echo "none"
      ;;
  esac
}

build_status_prompt() {
  local dg="$1"
  local status="$2"
  local color="$3"
  local action="$4"

  case "$action" in
    force)
      printf "DG '%s' : color=%s, status=%s. Forcer la synchronisation (force-full-load-push) ? (y/n) : " "$dg" "$color" "$status"
      ;;
    sync)
      printf "DG '%s' : color=%s, status=%s. Lancer la synchronisation ? (y/n) : " "$dg" "$color" "$status"
      ;;
    *)
      printf "DG '%s' : color=%s, status=%s. Aucune action requise. " "$dg" "$color" "$status"
      ;;
  esac
}

#######################################
# ACTIONS
#######################################
run_config_sync_to_group() {
  local host="$1" dg="$2"
  local resp

  resp="$(rest_post_cm_command "$host" "config-sync to-group ${dg}")" || return 1

  local result
  result="$(jq -r '.commandResult // empty' <<<"$resp" 2>/dev/null || true)"
  if [[ -n "${result:-}" ]]; then
    log "ℹ️  Retour API : $result"
  fi

  return 0
}

run_force_full_load_push_to_group() {
  local host="$1" dg="$2"
  local resp

  resp="$(rest_post_cm_command "$host" "config-sync force-full-load-push to-group ${dg}")" || return 1

  local result
  result="$(jq -r '.commandResult // empty' <<<"$resp" 2>/dev/null || true)"
  if [[ -n "${result:-}" ]]; then
    log "ℹ️  Retour API : $result"
  fi

  return 0
}

poll_dg_until_in_sync() {
  local host="$1" dg_full="$2"
  local dg_short start now js st

  dg_short="$(normalize_dg_name "$dg_full")"
  start="$(date +%s)"

  while true; do
    js="$(get_sync_stats_json "$host")"
    st="$(get_dg_status_from_sync_json "$dg_short" "$js")"
    dbg "Polling $dg_full => $st"

    if [[ "$st" == "In Sync" ]]; then
      log "✅ $dg_full : In Sync confirmé"
      return 0
    fi

    now="$(date +%s)"
    if (( now - start >= SYNC_POLL_TIMEOUT )); then
      log "⏱️  Timeout (${SYNC_POLL_TIMEOUT}s) — $dg_full toujours en statut: $st"
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

log ""
log "🔁 HA ConfigSync — règles basées sur Color + Sync Status"
log "Règles appliquées :"
log "  - Blue + Awaiting Initial Sync     => config-sync to-group"
log "  - Yellow + Changes Pending         => config-sync to-group"
log "  - Red + Not All Devices Synced     => force-full-load-push to-group"
log "  - Green + Syncing                  => aucune action"
log "  - In Sync                          => aucune action"
log "Règle complémentaire : action uniquement depuis l'ACTIVE"
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

  DG_LIST_TSV="$(get_all_device_groups_tsv "$HOST" || true)"
  if [[ -z "${DG_LIST_TSV:-}" ]]; then
    log "⚠️  Aucun device-group trouvé."
    log ""
    continue
  fi

  JS="$(get_sync_stats_json "$HOST")"
  GLOBAL_COLOR="$(get_sync_color_from_sync_json "$JS")"

  declare -A DG_FULL=()
  declare -A DG_TYPE=()
  declare -A DG_STATUS=()
  declare -A DG_ACTION=()

  while IFS=$'\t' read -r dg_full dg_type; do
    [[ -z "${dg_full:-}" || -z "${dg_type:-}" ]] && continue
    dg_short="$(normalize_dg_name "$dg_full")"

    DG_FULL["$dg_short"]="$dg_full"
    DG_TYPE["$dg_short"]="$dg_type"
    DG_STATUS["$dg_short"]="$(get_dg_status_from_sync_json "$dg_short" "$JS")"
    DG_ACTION["$dg_short"]="$(decide_action "${DG_STATUS[$dg_short]}" "$GLOBAL_COLOR")"

    dbg "DG='$dg_full' type='$dg_type' status='${DG_STATUS[$dg_short]}' color='$GLOBAL_COLOR' action='${DG_ACTION[$dg_short]}'"
  done <<< "$DG_LIST_TSV"

  log ""
  log "Device-groups détectés :"
  for dg_short in "${!DG_FULL[@]}"; do
    printf "  - %-35s : %-24s color=%-8s (%s)\n" \
      "${DG_FULL[$dg_short]}" \
      "${DG_STATUS[$dg_short]}" \
      "$GLOBAL_COLOR" \
      "${DG_TYPE[$dg_short]}" | tee -a "$LOG_FILE"
  done

  NEEDS=()
  for dg_short in "${!DG_FULL[@]}"; do
    if [[ "${DG_TYPE[$dg_short]}" == "sync-failover" ]]; then
      if [[ "${DG_ACTION[$dg_short]}" == "sync" || "${DG_ACTION[$dg_short]}" == "force" ]]; then
        NEEDS+=("$dg_short")
      fi
    fi
  done

  if [[ "${#NEEDS[@]}" -eq 0 ]]; then
    log ""
    log "✅ Aucun device-group sync-failover ne nécessite d'action selon les règles."
    log ""
    continue
  fi

  log ""
  log "⚠️  Device-groups sync-failover nécessitant une action : ${#NEEDS[@]}"
  for dg_short in "${NEEDS[@]}"; do
    log "  * ${DG_FULL[$dg_short]} : status=${DG_STATUS[$dg_short]} color=${GLOBAL_COLOR} action=${DG_ACTION[$dg_short]}"
  done
  log ""

  if [[ "$ROLE" != "ACTIVE" ]]; then
    log "ℹ️  Non-ACTIVE => aucune synchronisation lancée."
    log ""
    continue
  fi

  for dg_short in "${NEEDS[@]}"; do
    dg_full="${DG_FULL[$dg_short]}"
    dg_type="${DG_TYPE[$dg_short]}"
    st="${DG_STATUS[$dg_short]}"
    action="${DG_ACTION[$dg_short]}"

    log "--------------------------------------"
    log "DG     : $dg_full"
    log "Type   : $dg_type"
    log "Status : $st"
    log "Color  : $GLOBAL_COLOR"
    log "Action : $action"

    prompt="$(build_status_prompt "$dg_full" "$st" "$GLOBAL_COLOR" "$action")"
    read -r -p "$prompt" ans </dev/tty || ans="n"

    if [[ "${ans,,}" != "y" && "${ans,,}" != "yes" ]]; then
      log "⏭️  Ignoré."
      continue
    fi

    if [[ "$action" == "force" ]]; then
      log "🚀 Lancement : config-sync force-full-load-push to-group $dg_full"
      if ! run_force_full_load_push_to_group "$HOST" "$dg_full"; then
        log "❌ Échec lancement via API."
        FAILS=$((FAILS+1))
        continue
      fi
    else
      log "🚀 Lancement : config-sync to-group $dg_full"
      if ! run_config_sync_to_group "$HOST" "$dg_full"; then
        log "❌ Échec lancement via API."
        FAILS=$((FAILS+1))
        continue
      fi
    fi

    log "⏳ Attente du retour In Sync pour $dg_full..."
    if ! poll_dg_until_in_sync "$HOST" "$dg_full"; then
      FAILS=$((FAILS+1))
    fi
  done

  log ""
done < "$DEVICES_FILE"

log "======================================"
log "🏁 Terminé"
log "Équipements traités : $COUNT"
log "Erreurs / Timeouts  : $FAILS"
log "======================================"
(( FAILS == 0 )) || exit 1
