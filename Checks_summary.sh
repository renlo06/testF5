#!/usr/bin/env bash
set -euo pipefail

DEVICES_FILE="devices.txt"
TOP=10000
CURL_OPTS=(-k -sS --connect-timeout 10 --max-time 30)

for bin in curl jq awk tr grep wc sed; do
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

rest_get() {
  local host="$1" path="$2"
  curl "${CURL_OPTS[@]}" "${AUTH[@]}" "https://${host}${path}"
}

rest_get_or_empty() {
  local host="$1" path="$2" out rc
  set +e
  out="$(rest_get "$host" "$path")"
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
# JQ HELPERS (partition-aware)
#######################################
# Convertit une clé stats du type:
#   "https://localhost/mgmt/tm/ltm/virtual/~Common~vs1/stats"
# ou "~Common~vs1~stats"
# ou "~Common~pool1~members~10.0.0.1:80~stats"
# => "/Common/vs1" ou "/Common/pool1/members/10.0.0.1:80"
stats_key_to_fullpath_jq='
  def to_fullpath:
    tostring
    | sub("^.*/~"; "~")                         # garde à partir du "~"
    | sub("/stats$"; "~stats")                  # uniformise
    | sub("~stats$"; "")                        # enlève le suffixe stats
    | sub("^~"; "")                             # enlève le 1er ~
    | gsub("~"; "/")                            # ~ -> /
    | "/" + .                                   # préfixe /
  ;
  to_fullpath
'

# Extraction availability robuste sur BIG-IP
pick_avail_jq='
  def pick_avail($e):
    (
      $e.nestedStats.entries.status.availabilityState.description? //
      $e.nestedStats.entries.status.entries.availabilityState.description? //
      $e.nestedStats.entries.availabilityState.description? //
      $e.nestedStats.entries.status_availabilityState.description? //
      (
        $e.nestedStats.entries
        | to_entries[]
        | select(.key | test("availabilityState";"i"))
        | .value.description?
      ) //
      "UNKNOWN"
    );
  pick_avail(.)
'

# Build fullPath->availability map from */stats (partition-aware)
stats_to_avail_map_jq="
  def key_to_fullpath: ($stats_key_to_fullpath_jq);
  def pick_avail(\$e): ($pick_avail_jq);

  reduce (.entries // {} | to_entries[]) as \$it ({}; 
    (\$it.key | key_to_fullpath) as \$fp
    | . + { (\$fp): (pick_avail(\$it.value) // \"UNKNOWN\") }
  )
"

count_status_tsv_jq='
  def is_up($s): ($s | ascii_upcase | test("AVAILABLE|UP"));
  def st($s):
    if $s == null or ($s|ascii_upcase) == "UNKNOWN" then "unknown"
    elif is_up($s) then "up"
    else "down" end;

  (.items // []) as $items
  | ($items | length) as $total
  | ($items | map(st($avail[.fullPath])) ) as $st
  | [
      $total,
      ($st | map(select(.=="up")) | length),
      ($st | map(select(.=="down")) | length),
      ($st | map(select(.=="unknown")) | length)
    ] | @tsv
'

# Pool members counts from stats entries (partition-aware)
pool_members_counts_from_stats() {
  jq -r "
    def key_to_fullpath: ($stats_key_to_fullpath_jq);

    def pick_avail(\$e):
      (
        \$e.nestedStats.entries.status.availabilityState.description? //
        \$e.nestedStats.entries.status.entries.availabilityState.description? //
        \$e.nestedStats.entries.availabilityState.description? //
        \$e.nestedStats.entries.status_availabilityState.description? //
        (
          \$e.nestedStats.entries
          | to_entries[]
          | select(.key | test(\"availabilityState\";\"i\"))
          | .value.description?
        ) //
        \"UNKNOWN\"
      );

    def is_up(\$s): (\$s | ascii_upcase | test(\"AVAILABLE|UP\"));
    def st(\$s):
      if \$s == null or (\$s|ascii_upcase) == \"UNKNOWN\" then \"unknown\"
      elif is_up(\$s) then \"up\"
      else \"down\" end;

    (.entries // {} | to_entries) as \$e
    | (\$e
        | map({
            fullPath: (key_to_fullpath(.key) // \"\"),
            avail: pick_avail(.value)
          })
        | map(select(.fullPath != \"\"))
      ) as \$items
    | (\$items | length) as \$total
    | (\$items | map(st(.avail))) as \$st
    | [ \$total,
        (\$st | map(select(.==\"up\")) | length),
        (\$st | map(select(.==\"down\")) | length),
        (\$st | map(select(.==\"unknown\")) | length)
      ] | @tsv
  " 2>/dev/null
}

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0

echo
echo "📊 Summary LTM/ASM/AFM (REST) — partitions OK"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(printf "%s" "$LINE" | tr -d '\r' | awk '{$1=$1;print}')
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue
  COUNT=$((COUNT+1))

  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  # VS
  VS_CFG="$(rest_get_or_empty "$HOST" "/mgmt/tm/ltm/virtual?\$select=fullPath&\$top=${TOP}" || true)"
  VS_STATS="$(rest_get_or_empty "$HOST" "/mgmt/tm/ltm/virtual/stats?\$top=${TOP}" || true)"
  VS_AVAIL="$(jq -c "$stats_to_avail_map_jq" <<<"$VS_STATS" 2>/dev/null || echo '{}')"
  VS_COUNTS="$(jq --argjson avail "$VS_AVAIL" -r "$count_status_tsv_jq" <<<"$VS_CFG" 2>/dev/null || echo $'0\t0\t0\t0')"
  IFS=$'\t' read -r VS_TOTAL VS_UP VS_DOWN VS_UNK <<<"$VS_COUNTS"

  # POOLS
  POOL_CFG="$(rest_get_or_empty "$HOST" "/mgmt/tm/ltm/pool?\$select=fullPath&\$top=${TOP}" || true)"
  POOL_STATS="$(rest_get_or_empty "$HOST" "/mgmt/tm/ltm/pool/stats?\$top=${TOP}" || true)"
  POOL_AVAIL="$(jq -c "$stats_to_avail_map_jq" <<<"$POOL_STATS" 2>/dev/null || echo '{}')"
  POOL_COUNTS="$(jq --argjson avail "$POOL_AVAIL" -r "$count_status_tsv_jq" <<<"$POOL_CFG" 2>/dev/null || echo $'0\t0\t0\t0')"
  IFS=$'\t' read -r POOL_TOTAL POOL_UP POOL_DOWN POOL_UNK <<<"$POOL_COUNTS"

  # POOL MEMBERS (global)
  PM_STATS="$(rest_get_or_empty "$HOST" "/mgmt/tm/ltm/pool/members/stats?\$top=${TOP}" || true)"
  PM_COUNTS="$(pool_members_counts_from_stats <<<"$PM_STATS" || echo $'0\t0\t0\t0')"
  IFS=$'\t' read -r PM_TOTAL PM_UP PM_DOWN PM_UNK <<<"$PM_COUNTS"

  # ASM policies
  ASM_JSON="$(rest_get_or_empty "$HOST" "/mgmt/tm/asm/policies?\$top=${TOP}" || true)"
  ASM_TOTAL="$(jq -r '(.items // []) | length' <<<"$ASM_JSON" 2>/dev/null || echo 0)"

  # AFM policies (firewall)
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