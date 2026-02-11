#!/usr/bin/env bash
set -euo pipefail

DEVICES_FILE="devices.txt"
TOP=10000
CURL_OPTS=(-k -sS --connect-timeout 10 --max-time 30)

DEBUG=0
if [[ "${1:-}" == "--debug" || "${1:-}" == "-d" ]]; then
  DEBUG=1
fi

for bin in curl jq awk tr grep wc head; do
  command -v "$bin" >/dev/null || { echo "❌ $bin requis"; exit 1; }
done
[[ -f "$DEVICES_FILE" ]] || { echo "❌ Fichier équipements introuvable : $DEVICES_FILE"; exit 1; }

read -rp "Utilisateur API (REST, ex: admin): " API_USER
read -s -rp "Mot de passe API (REST): " API_PASS
echo
AUTH=(-u "${API_USER}:${API_PASS}")

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

rest_get_or_empty() {
  local host="$1" path="$2" out rc
  set +e
  out="$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" "https://${host}${path}")"
  rc=$?
  set -e
  if [[ $rc -ne 0 || -z "$(trim "${out:-}")" ]]; then
    echo "{}"
    return 1
  fi
  echo "$out"
  return 0
}

dbg() { (( DEBUG == 1 )) && echo "🟦 [DEBUG] $*" >&2 || true; }

#######################################
# JQ (partitions/folders OK)
#######################################
stats_key_to_fullpath_jq='
  tostring
  | sub("^.*/~"; "~")
  | sub("/stats$"; "~stats")
  | sub("~stats$"; "")
  | sub("^~"; "")
  | gsub("~"; "/")
  | "/" + .
'

# ton format => status.availabilityState
pick_avail_scan_jq='
  (
    .nestedStats.entries["status.availabilityState"].description?
    //
    (
      .nestedStats.entries
      | to_entries[]
      | select(.key | test("availabilityState"; "i"))
      | .value.description?
    )
  ) // "UNKNOWN"
'

count_from_stats_by_key_jq='
  def key_to_fullpath: '"$stats_key_to_fullpath_jq"' ;
  def pick_avail($e): '"$pick_avail_scan_jq"' ;

  def is_up($s): ($s | ascii_upcase | test("AVAILABLE|UP"));
  def st($s):
    if $s == null or ($s|ascii_upcase) == "UNKNOWN" then "unknown"
    elif is_up($s) then "up"
    else "down" end;

  (.entries // {} | to_entries
    | map(select(.key | test($KRE)))
    | map({ fp: (key_to_fullpath(.key)), a: (pick_avail(.value)) })
  ) as $items
  | ($items | length) as $total
  | ($items | map(st(.a))) as $st
  | [ $total,
      ($st | map(select(.=="up")) | length),
      ($st | map(select(.=="down")) | length),
      ($st | map(select(.=="unknown")) | length)
    ] | @tsv
'

debug_stats_payload() {
  local label="$1" kre="$2" payload="$3"

  dbg "===== $label DEBUG ====="
  dbg "Regex: $kre"

  local entries_len
  entries_len="$(jq -r '(.entries // {}) | length' <<<"$payload" 2>/dev/null || echo 0)"
  dbg "entries length: $entries_len"

  dbg "First 5 keys:"
  jq -r '(.entries // {}) | keys[]' <<<"$payload" 2>/dev/null | head -n 5 >&2 || true

  dbg "First 5 keys that MATCH regex:"
  jq -r --arg re "$kre" '(.entries // {}) | keys[] | select(test($re))' <<<"$payload" 2>/dev/null | head -n 5 >&2 || true

  dbg "Count of matching keys:"
  jq -r --arg re "$kre" '(.entries // {}) | keys | map(select(test($re))) | length' <<<"$payload" 2>/dev/null >&2 || true

  dbg "Availability-related keys in nestedStats.entries for FIRST matching entry:"
  jq -r --arg re "$kre" '
    (.entries // {} | to_entries | map(select(.key|test($re))) | .[0]) as $e
    | if $e == null then "NO_MATCH"
      else ($e.value.nestedStats.entries | keys[] | select(test("avail";"i")))
      end
  ' <<<"$payload" 2>/dev/null | head -n 30 >&2 || true

  dbg "Example extracted availability (first match):"
  jq -r --arg re "$kre" '
    def pick_avail($e):
      (
        $e.nestedStats.entries["status.availabilityState"].description?
        //
        (
          $e.nestedStats.entries
          | to_entries[]
          | select(.key | test("availabilityState"; "i"))
          | .value.description?
        )
      ) // "UNKNOWN";

    def key_to_fullpath:
      tostring
      | sub("^.*/~"; "~")
      | sub("/stats$"; "~stats")
      | sub("~stats$"; "")
      | sub("^~"; "")
      | gsub("~"; "/")
      | "/" + .;

    (.entries // {} | to_entries | map(select(.key|test($re))) | .[0]) as $e
    | if $e == null then "NO_MATCH"
      else ("fullPath=" + (key_to_fullpath($e.key)) + " | availability=" + (pick_avail($e.value)))
      end
  ' <<<"$payload" 2>/dev/null >&2 || true

  dbg "===== END $label DEBUG ====="
}

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0

echo
echo "📊 Summary LTM/ASM/AFM (REST) — FINAL + DEBUG"
echo "📌 Debug : $([[ $DEBUG -eq 1 ]] && echo ON || echo OFF)"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(printf "%s" "$LINE" | tr -d '\r' | awk '{$1=$1;print}')
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue
  COUNT=$((COUNT+1))

  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  # ✅ IMPORTANT: pas de \ avant le $
  VS_RE="/ltm/virtual/.*/stats$"
  POOL_RE="/ltm/pool/.*/stats$"
  PM_RE="/ltm/pool/members/.*/stats$"

  # VS stats
  VS_STATS="$(rest_get_or_empty "$HOST" "/mgmt/tm/ltm/virtual/stats?\$top=${TOP}" || true)"
  (( DEBUG == 1 )) && debug_stats_payload "VS" "$VS_RE" "$VS_STATS"
  VS_COUNTS="$(jq --arg KRE "$VS_RE" -r "$count_from_stats_by_key_jq" <<<"$VS_STATS" 2>/dev/null || echo $'0\t0\t0\t0')"
  IFS=$'\t' read -r VS_TOTAL VS_UP VS_DOWN VS_UNK <<<"$VS_COUNTS"

  # Pool stats
  POOL_STATS="$(rest_get_or_empty "$HOST" "/mgmt/tm/ltm/pool/stats?\$top=${TOP}" || true)"
  (( DEBUG == 1 )) && debug_stats_payload "POOLS" "$POOL_RE" "$POOL_STATS"
  POOL_COUNTS="$(jq --arg KRE "$POOL_RE" -r "$count_from_stats_by_key_jq" <<<"$POOL_STATS" 2>/dev/null || echo $'0\t0\t0\t0')"
  IFS=$'\t' read -r POOL_TOTAL POOL_UP POOL_DOWN POOL_UNK <<<"$POOL_COUNTS"

  # Pool members stats
  PM_STATS="$(rest_get_or_empty "$HOST" "/mgmt/tm/ltm/pool/members/stats?\$top=${TOP}" || true)"
  (( DEBUG == 1 )) && debug_stats_payload "POOL MEMBERS" "$PM_RE" "$PM_STATS"
  PM_COUNTS="$(jq --arg KRE "$PM_RE" -r "$count_from_stats_by_key_jq" <<<"$PM_STATS" 2>/dev/null || echo $'0\t0\t0\t0')"
  IFS=$'\t' read -r PM_TOTAL PM_UP PM_DOWN PM_UNK <<<"$PM_COUNTS"

  # ASM policies count
  ASM_JSON="$(rest_get_or_empty "$HOST" "/mgmt/tm/asm/policies?\$top=${TOP}" || true)"
  ASM_TOTAL="$(jq -r '(.items // []) | length' <<<"$ASM_JSON" 2>/dev/null || echo 0)"

  # AFM firewall policies count
  AFM_JSON="$(rest_get_or_empty "$HOST" "/mgmt/tm/security/firewall/policy?\$top=${TOP}" || true)"
  AFM_TOTAL="$(jq -r '(.items // []) | length' <<<"$AFM_JSON" 2>/dev/null || echo 0)"

  echo "VS            : total=${VS_TOTAL}  up=${VS_UP}  down=${VS_DOWN}  unknown=${VS_UNK}"
  echo "Pools         : total=${POOL_TOTAL}  up=${POOL_UP}  down=${POOL_DOWN}  unknown=${POOL_UNK}"
  echo "Pool members  : total=${PM_TOTAL}  up=${PM_UP}  down=${PM_DOWN}  unknown=${PM_UNK}"
  echo "ASM policies  : total=${ASM_TOTAL}"
  echo "AFM policies  : total=${AFM_TOTAL}"
  echo
done < "$DEVICES_FILE"

echo "🏁 Terminé"