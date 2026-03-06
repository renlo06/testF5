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
# PRECHECKS
#######################################
for bin in curl jq awk tr grep wc date tee; do
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
    dbg "GET failed or empty for $path"
    echo "{}"
    return 1
  fi

  echo "$out"
  return 0
}

rest_post_cm_command() {
  local host="$1" cmd="$2"
  local payload out rc

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
# SYNC STATUS
#######################################
get_sync_stats_json() {
  local host="$1"
  local js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/sync-status/stats" || echo "{}")"
  dump_json "sync-status/stats (${host})" "$js"
  echo "$js"
}

extract_dg_status_tsv() {
  local js="$1"
  jq -r '
    def allowed:
      "In Sync|Awaiting Initial Sync|Changes Pending|Not All Devices Synced";

    [ .. | strings
      | select(test("\\((" + allowed + ")\\)"; "i"))
    ]
    | map(
        capture("^(?<dg>[^\\(]+)\\s*\\((?<st>" + allowed + ")\\)")?
        | select(. != null)
        | {dg: (.dg|gsub("\\s+$";"")|gsub("^\\s+";"")), st: .st}
      )
    | .[]
    | [.dg, .st] | @tsv
  ' <<<"$js" 2>/dev/null || true
}

status_prio() {
  case "$1" in
    "In Sync") echo 0 ;;
    "Awaiting Initial Sync") echo 1 ;;
    "Not All Devices Synced") echo 2 ;;
    "Changes Pending") echo 3 ;;
    *) echo 0 ;;
  esac
}

#######################################
# DEVICE-GROUPS
#######################################
get_sync_failover_device_groups() {
  local host="$1" js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/device-group?\$select=fullPath,type" || true)"
  dump_json "device-group (${host})" "$js"

  jq -r '
    (.items // [])
    | map(select((.type // "") | test("sync-failover";"i")))
    | .[].fullPath
  ' <<<"$js" 2>/dev/null || true
}

#######################################
# ACTION
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

poll_dg_until_in_sync() {
  local host="$1" dg="$2"
  local start now js

  start="$(date +%s)"
  while true; do
    js="$(get_sync_stats_json "$host")"

    dbg "Polling DG=$dg"

    if jq -e --arg dg "$dg" '
      [ .. | strings
        | select(test("^" + ($dg|gsub("\\\\";"\\\\\\\\")) + "\\s*\\(In Sync\\)"; "i"))
      ] | length > 0
    ' <<<"$js" >/dev/null 2>&1; then
      log "✅ $dg : In Sync confirmé"
      return 0
    fi

    now="$(date +%s)"
    if (( now - start >= SYNC_POLL_TIMEOUT )); then
      log "⏱️  Timeout (${SYNC_POLL_TIMEOUT}s) — $dg toujours pas In Sync"
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
log "🔁 HA ConfigSync — multi device-groups (REST + DEBUG avancé)"
log "Statuts pris en compte :"
log "  - In Sync"
log "  - Awaiting Initial Sync"
log "  - Changes Pending"
log "  - Not All Devices Synced"
log "Règle : synchronisation uniquement depuis l'ACTIVE"
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

  DG_LIST="$(get_sync_failover_device_groups "$HOST" || true)"
  if [[ -z "${DG_LIST:-}" ]]; then
    log "⚠️  Aucun device-group sync-failover trouvé."
    log ""
    continue
  fi

  dbg "Device-groups sync-failover détectés:"
  while IFS= read -r dg; do
    [[ -n "${dg:-}" ]] && dbg "  - $dg"
  done <<< "$DG_LIST"

  JS="$(get_sync_stats_json "$HOST")"
  DG_TSV="$(extract_dg_status_tsv "$JS")"

  if [[ -z "${DG_TSV:-}" ]]; then
    log "⚠️  Aucun device-group détecté dans sync-status/stats."
    log ""
    continue
  fi

  declare -A DG_STATUS=()
  declare -A DG_PRIO=()

  while IFS=$'\t' read -r dg st; do
    [[ -z "${dg:-}" || -z "${st:-}" ]] && continue
    dbg "Parsed DG='$dg' status='$st'"
    p="$(status_prio "$st")"
    if [[ -z "${DG_STATUS[$dg]+x}" ]]; then
      DG_STATUS["$dg"]="$st"
      DG_PRIO["$dg"]="$p"
    else
      if (( p > DG_PRIO["$dg"] )); then
        DG_STATUS["$dg"]="$st"
        DG_PRIO["$dg"]="$p"
      fi
    fi
  done <<< "$DG_TSV"

  log ""
  log "Device-groups détectés :"
  for dg in "${!DG_STATUS[@]}"; do
    printf "  - %-40s : %s\n" "$dg" "${DG_STATUS[$dg]}" | tee -a "$LOG_FILE"
  done

  NEEDS=()
  for dg in "${!DG_STATUS[@]}"; do
    st="${DG_STATUS[$dg]}"
    if [[ "$st" != "In Sync" ]]; then
      NEEDS+=("$dg")
    fi
  done

  if [[ "${#NEEDS[@]}" -eq 0 ]]; then
    log ""
    log "✅ Tous les device-groups sont In Sync."
    log ""
    continue
  fi

  log ""
  log "⚠️  Device-groups nécessitant une action : ${#NEEDS[@]}"
  for dg in "${NEEDS[@]}"; do
    log "  * $dg : ${DG_STATUS[$dg]}"
  done
  log ""

  if [[ "$ROLE" != "ACTIVE" ]]; then
    log "ℹ️  Non-ACTIVE => aucune synchronisation lancée."
    log ""
    continue
  fi

  for dg in "${NEEDS[@]}"; do
    st="${DG_STATUS[$dg]}"

    log "--------------------------------------"
    log "DG     : $dg"
    log "Status : $st"

    case "$st" in
      "Awaiting Initial Sync")
        log "➡️  Recommandation : config-sync to-group (initial sync)"
        ;;
      "Changes Pending")
        log "➡️  Recommandation : config-sync to-group"
        ;;
      "Not All Devices Synced")
        log "➡️  Recommandation : config-sync to-group"
        ;;
      *)
        log "➡️  Recommandation : config-sync to-group"
        ;;
    esac

    read -r -p "Lancer la synchronisation pour '$dg' ? (y/n) : " ans </dev/tty || ans="n"
    if [[ "${ans,,}" != "y" && "${ans,,}" != "yes" ]]; then
      log "⏭️  Ignoré."
      continue
    fi

    log "🚀 Lancement : config-sync to-group $dg"
    if ! run_config_sync_to_group "$HOST" "$dg"; then
      log "❌ Échec lancement via API."
      FAILS=$((FAILS+1))
      continue
    fi

    log "⏳ Attente du retour In Sync pour $dg..."
    if ! poll_dg_until_in_sync "$HOST" "$dg"; then
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
