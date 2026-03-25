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
for bin in curl jq awk tr grep wc date tee head sed sort; do
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

normalize_text() {
  printf "%s" "${1:-}" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

normalize_lower() {
  normalize_text "${1:-}" | tr '[:upper:]' '[:lower:]'
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
  local raw
  raw="$(normalize_text "${1:-}")"
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
  ' <<<"$js" 2>/dev/null
}

get_dg_status_from_sync_json() {
  local dg_full="$1"
  local js="$2"
  local dg_short

  dg_short="$(normalize_dg_name "$dg_full")"

  jq -r --arg dg_full "$dg_full" --arg dg_short "$dg_short" '
    def allowed: "In Sync|Awaiting Initial Sync|Changes Pending|Not All Devices