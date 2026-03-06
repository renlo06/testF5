#!/usr/bin/env bash
set -euo pipefail

DEVICES_FILE="devices.txt"
CURL_OPTS=(-k -sS --connect-timeout 10 --max-time 30)
SYNC_POLL_SLEEP=3
SYNC_POLL_TIMEOUT=300

DEBUG=0
if [[ "${1:-}" == "--debug" || "${1:-}" == "-d" ]]; then
  DEBUG=1
fi

LOG_FILE="./ha_sync_debug_$(date +%Y%m%d-%H%M%S).log"

read -rp "Utilisateur API: " USER
read -s -rp "Mot de passe API: " PASS
echo
AUTH=(-u "${USER}:${PASS}")

for bin in curl jq awk tr grep wc date tee; do
  command -v "$bin" >/dev/null || { echo "❌ $bin requis"; exit 1; }
done
[[ -f "$DEVICES_FILE" ]] || { echo "❌ Fichier $DEVICES_FILE introuvable"; exit 1; }

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

# Liste tous les device-groups avec type
# sortie TSV: fullPath<TAB>type
get_all_device_groups_tsv() {
  local host="$1" js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/device-group?\$select=fullPath,type" || true)"
  dump_json "device-group (${host})" "$js"

  jq -r '
    (.items // [])[]
    | [.fullPath, .type] | @tsv
  ' <<<"$js" 2>/dev/null || true
}

get_sync_stats_json() {
  local host="$1" js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/sync-status/stats" || echo "{}")"
  dump_json "sync-status/stats (${host})" "$js"
  echo "$js"
}

# Parse:
# Device-Group-HA (In Sync): ...
# device_trust_group (Changes Pending): ...
# datasync-global-dg (Not All Devices Synced): ...
# sortie TSV: dg_short<TAB>status
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
        | {dg: (.dg|gsub("^\\s+";"")|gsub("\\s+$";"")), st: .st}
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

normalize_dg_name() {
  local dg="${1:-}"
  dg="${dg##*/}"
  printf "%s" "$dg"
}

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
  local host="$1" dg_full="$2"
  local dg_short start now js

  dg_short="$(normalize_dg_name "$dg_full")"
  start="$(date +%s)"

  while true; do
    js="$(get_sync_stats_json "$host")"

    if jq -e --arg dg "$dg_short" '
      [ .. | strings
        | select(test("^" + ($dg|gsub("\\\\";"\\\\\\\\")) + "\\s*\\(In Sync\\)"; "i"))
      ] | length > 0
    ' <<<"$js" >/dev/null 2>&1; then
      log "✅ $dg_full : In Sync confirmé"
      return 0
    fi

    now="$(date +%s)"
    if (( now - start >= SYNC_POLL_TIMEOUT )); then
      log "⏱️  Timeout (${SYNC_POLL_TIMEOUT}s) — $dg_full toujours pas In Sync"
      return 1
    fi

    sleep "$SYNC_POLL_SLEEP"
  done
}

TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0
FAILS=0

log ""
log "🔁 HA ConfigSync — affichage de tous les device-groups"
log "Statuts pris en compte :"
log "  - In Sync"
log "  - Awaiting Initial Sync"
log "  - Changes Pending"
log "  - Not All Devices Synced"
log "Règle : synchro lancée uniquement depuis l'ACTIVE et uniquement pour les sync-failover"
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

  # map short -> full/type
  declare -A DG_FULL=()
  declare -A DG_TYPE=()

  while IFS=$'\t' read -r dg_full dg_type; do
    [[ -z "${dg_full:-}" || -z "${dg_type:-}" ]] && continue
    dg_short="$(normalize_dg_name "$dg_full")"
    DG_FULL["$dg_short"]="$dg_full"
    DG_TYPE["$dg_short"]="$dg_type"
    dbg "DG déclaré: short=$dg_short full=$dg_full type=$dg_type"
  done <<< "$DG_LIST_TSV"

  JS="$(get_sync_stats_json "$HOST")"
  DG_TSV="$(extract_dg_status_tsv "$JS")"

  declare -A DG_STATUS=()
  declare -A DG_PRIO=()

  while IFS=$'\t' read -r dg_raw st; do
    [[ -z "${dg_raw:-}" || -z "${st:-}" ]] && continue
    dg_short="$(normalize_dg_name "$dg_raw")"

    # garder seulement les DG existants côté conf
    if [[ -z "${DG_FULL[$dg_short]+x}" ]]; then
      dbg "DG ignoré (absent de cm device-group): raw='$dg_raw' short='$dg_short' status='$st'"
      continue
    fi

    p="$(status_prio "$st")"
    if [[ -z "${DG_STATUS[$dg_short]+x}" ]]; then
      DG_STATUS["$dg_short"]="$st"
      DG_PRIO["$dg_short"]="$p"
    else
      if (( p > DG_PRIO["$dg_short"] )); then
        DG_STATUS["$dg_short"]="$st"
        DG_PRIO["$dg_short"]="$p"
      fi
    fi
  done <<< "$DG_TSV"

  log ""
  log "Device-groups détectés :"
  for dg_short in "${!DG_FULL[@]}"; do
    dg_full="${DG_FULL[$dg_short]}"
    dg_type="${DG_TYPE[$dg_short]}"
    dg_status="${DG_STATUS[$dg_short]:-UNKNOWN}"
    printf "  - %-35s : %-24s (%s)\n" "$dg_full" "$dg_status" "$dg_type" | tee -a "$LOG_FILE"
  done

  # synchro à proposer seulement pour sync-failover et non In Sync
  NEEDS=()
  for dg_short in "${!DG_FULL[@]}"; do
    if [[ "${DG_TYPE[$dg_short]}" == "sync-failover" ]]; then
      st="${DG_STATUS[$dg_short]:-UNKNOWN}"
      if [[ "$st" != "In Sync" && "$st" != "UNKNOWN" ]]; then
        NEEDS+=("$dg_short")
      fi
    fi
  done

  if [[ "${#NEEDS[@]}" -eq 0 ]]; then
    log ""
    log "✅ Aucun device-group sync-failover à synchroniser."
    log ""
    continue
  fi

  log ""
  log "⚠️  Device-groups sync-failover nécessitant une action : ${#NEEDS[@]}"
  for dg_short in "${NEEDS[@]}"; do
    log "  * ${DG_FULL[$dg_short]} : ${DG_STATUS[$dg_short]}"
  done
  log ""

  if [[ "$ROLE" != "ACTIVE" ]]; then
    log "ℹ️  Non-ACTIVE => aucune synchronisation lancée."
    log ""
    continue
  fi

  for dg_short in "${NEEDS[@]}"; do
    dg_full="${DG_FULL[$dg_short]}"
    st="${DG_STATUS[$dg_short]}"

    log "--------------------------------------"
    log "DG     : $dg_full"
    log "Type   : ${DG_TYPE[$dg_short]}"
    log "Status : $st"

    case "$st" in
      "Awaiting Initial Sync")
        log "➡️  Règle appliquée : initial sync => config-sync to-group"
        ;;
      "Changes Pending")
        log "➡️  Règle appliquée : changes pending => config-sync to-group"
        ;;
      "Not All Devices Synced")
        log "➡️  Règle appliquée : retry sync => config-sync to-group"
        ;;
      *)
        log "➡️  Règle appliquée : config-sync to-group"
        ;;
    esac

    read -r -p "Lancer la synchronisation pour '$dg_full' ? (y/n) : " ans </dev/tty || ans="n"
    if [[ "${ans,,}" != "y" && "${ans,,}" != "yes" ]]; then
      log "⏭️  Ignoré."
      continue
    fi

    log "🚀 Lancement : config-sync to-group $dg_full"
    if ! run_config_sync_to_group "$HOST" "$dg_full"; then
      log "❌ Échec lancement via API."
      FAILS=$((FAILS+1))
      continue
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
