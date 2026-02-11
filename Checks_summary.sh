#!/usr/bin/env bash
set -euo pipefail

DEVICES_FILE="devices.txt"
TOP=10000
CURL_OPTS=(-k -sS --connect-timeout 10 --max-time 30)

for bin in curl jq awk tr grep wc; do
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

#######################################
# JQ HELPERS (folders/partitions OK)
#######################################
# Key stats -> fullPath (/Common/folder/obj[/...])
stats_key_to_fullpath_jq='
  tostring
  | sub("^.*/~"; "~")             # garde à partir du premier "~"
  | sub("/stats$"; "~stats")      # uniformise
  | sub("~stats$"; "")            # enlève suffixe stats
  | sub("^~"; "")                 # enlève le premier "~"
  | gsub("~"; "/")                # ~ -> /
  | "/" + .                       # ajoute /
'

# Availability: ton format => "status.availabilityState"
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

# Count up/down/unknown directly from stats, filtering by key regex
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

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0

echo
echo "📊 Summary LTM/ASM/AFM (REST) — folders/partitions OK, moins de requêtes"
echo "📌 Requêtes par équipement : 5 (VS stats, Pool stats, Members stats, ASM, AFM)"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(printf "%s" "$LINE" | tr -d '\r' | awk '{$1=$1;print}')
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue
  COUNT=$((COUNT+1))

  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  # VS stats (inclut partitions + folders)
  VS_STATS="$(rest_get_or_empty "$HOST" "/mgmt/tm/ltm/virtual/stats?\$top=${TOP}" || true)"
  VS_COUNTS="$(jq --arg KRE "/mgmt/tm/ltm/virtual/.*/stats\$" -r "$count_from_stats_by_key_jq" <<<"$VS_STATS" 2>/dev/null || echo $'0\t0\t0\t0')"
  IFS=$'\t' read -r VS_TOTAL VS_UP VS_DOWN VS_UNK <<<"$VS_COUNTS"

  # Pool stats (inclut partitions + folders)
  POOL_STATS="$(rest_get_or_empty "$HOST" "/mgmt/tm/ltm/pool/stats?\$top=${TOP}" || true)"
  POOL_COUNTS="$(jq --arg KRE "/mgmt/tm/ltm/pool/.*/stats\$" -r "$count_from_stats_by_key_jq" <<<"$POOL_STATS" 2>/dev/null || echo $'0\t0\t0\t0')"
  IFS=$'\t' read -r POOL_TOTAL POOL_UP POOL_DOWN POOL_UNK <<<"$POOL_COUNTS"

  # Pool members stats (inclut members dans folders)
  PM_STATS="$(rest_get_or_empty "$HOST" "/mgmt/tm/ltm/pool/members/stats?\$top=${TOP}" || true)"
  PM_COUNTS="$(jq --arg KRE "/mgmt/tm/ltm/pool/members/.*/stats\$" -r "$count_from_stats_by_key_jq" <<<"$PM_STATS" 2>/dev/null || echo $'0\t0\t0\t0')"
  IFS=$'\t' read -r PM_TOTAL PM_UP PM_DOWN PM_UNK <<<"$PM_COUNTS"

  # ASM policies count
  ASM_JSON="$(rest_get_or_empty "$HOST" "/mgmt/tm/asm/policies?\$top=${TOP}" || true)"
  ASM_TOTAL="$(jq -r '(.items // []) | length' <<<"$ASM_JSON" 2>/dev/null || echo 0)"

  # AFM firewall policies count
  AFM_JSON="$(rest_get_or_empty "$HOST" "/mgmt/tm/security/firewall/policy?\$top=${TOP}" || true)"
  AFM_TOTAL="$(jq -r '(.items // []) | length' <<<"$AFM_JSON" 2>/dev/null || echo 0)"

  echo "VS            : total=${VS_TOTAL}  up=${VS_UP}