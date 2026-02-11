#!/usr/bin/env bash
set -euo pipefail

DEVICES_FILE="devices.txt"
TOP=10000
CURL_OPTS=(-k -sS --connect-timeout 10 --max-time 30)

DEBUG=0
if [[ "${1:-}" == "--debug" || "${1:-}" == "-d" ]]; then
  DEBUG=1
fi

for bin in curl jq awk tr grep wc head mktemp; do
  command -v "$bin" >/dev/null || { echo "❌ $bin requis"; exit 1; }
done
[[ -f "$DEVICES_FILE" ]] || { echo "❌ Fichier équipements introuvable : $DEVICES_FILE"; exit 1; }

read -rp "Utilisateur API (REST, ex: admin): " API_USER
read -s -rp "Mot de passe API (REST): " API_PASS
echo
AUTH=(-u "${API_USER}:${API_PASS}")

dbg() { (( DEBUG == 1 )) && echo "🟦 [DEBUG] $*" >&2 || true; }

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

# Compte total/up/down/unknown à partir d'un payload /stats
# Args: regex
count_from_stats() {
  local re="$1"
  local payload="$2"

  # On capture les erreurs jq en debug
  local errf
  errf="$(mktemp)"
  local out rc
  set +e
  out="$(jq -r --arg re "$re" '
    def key_to_fullpath($k):
      ($k|tostring)
      | sub("^.*/~"; "~")
      | sub("/stats$"; "~stats")
      | sub("~stats$"; "")
      | sub("^~"; "")
      | gsub("~"; "/")
      | "/" + . ;

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

    def is_up($s): ($s | ascii_upcase | test("AVAILABLE|UP"));
    def st($s):
      if $s == null or ($s|ascii_upcase) == "UNKNOWN" then "unknown"
      elif is_up($s) then "up"
      else "down" end;

    (.entries // {} | to_entries | map(select(.key|test($re)))) as $m
    | ($m | length) as $total
    | ($m | map(st(pick_avail(.value)))) as $st
    | [ $total,
        ($st | map(select(.=="up")) | length),
        ($st | map(select(.=="down")) | length),
        ($st | map(select(.=="unknown")) | length)
      ] | @tsv
  ' <<<"$payload" 2>"$errf")"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    dbg "jq ERROR for regex=$re :"
    dbg "$(cat "$errf")"
    rm -f "$errf"
    echo $'0\t0\t0\t0'
    return 1
  fi

  rm -f "$errf"
  # Si jq retourne vide (cas improbable), on sécurise
  if [[ -z "$(trim "$out")" ]]; then
    echo $'0\t0\t0\t0'
    return 1
  fi

  echo "$out"
}

debug_keys() {
  local label="$1" re="$2" payload="$3"
  dbg "===== $label DEBUG ====="
  dbg "Regex: $re"
  dbg "entries length: $(jq -r '(.entries // {}) | length' <<<"$payload" 2>/dev/null || echo 0)"

  dbg "First 5 keys:"
  jq -r '(.entries // {}) | keys[]' <<<"$payload" 2>/dev/null | head -n 5 >&2 || true

  dbg "First 5 keys MATCH:"
  jq -r --arg re "$re" '(.entries // {}) | keys[] | select(test($re))' <<<"$payload" 2>/dev/null | head -n 5 >&2 || true

  dbg "Matching keys count:"
  jq -r --arg re "$re" '(.entries // {}) | keys | map(select(test($re))) | length' <<<"$payload" 2>/dev/null >&2 || true

  dbg "Availability keys for first match:"
  jq -r --arg re "$re" '
    (.entries // {} | to_entries | map(select(.key|test($re))) | .[0]) as $e
    | if $e == null then "NO_MATCH"
      else ($e.value.nestedStats.entries | keys[] | select(test("avail";"i")))
      end
  ' <<<"$payload" 2>/dev/null | head -n 30 >&2 || true

  dbg "===== END $label DEBUG ====="
}

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0

echo
echo "📊 Summary LTM/ASM/AFM (REST) — FINAL + DEBUG"
echo "Debug : $([[ $DEBUG -eq 1 ]] && echo ON || echo OFF)"
echo

# Regex robustes (match clés https://localhost/... et folders)
VS_RE="/ltm/virtual/.*/stats$"
POOL_RE="/ltm/pool/.*/stats$"
PM_RE="/ltm/pool/members/.*/stats$"

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(printf "%s" "$LINE" | tr -d '\r' | awk '{$1=$1;print}')
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue
  COUNT=$((COUNT+1))

  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  VS_STATS="$(rest_get_or_empty "$HOST" "/mgmt/tm/ltm/virtual/stats?\$top=${TOP}" || true)"
  (( DEBUG == 1 )) && debug_keys "VS" "$VS_RE" "$VS_STATS"
  IFS=$'\t' read -r VS_TOTAL VS_UP VS_DOWN VS_UNK <<<"$(count_from_stats "$VS_RE" "$VS_STATS")"

  POOL_STATS="$(rest_get_or_empty "$HOST" "/mgmt/tm/ltm/pool/stats?\$top=${TOP}" || true)"
  (( DEBUG == 1 )) && debug_keys "POOLS" "$POOL_RE" "$POOL_STATS"
  IFS=$'\t' read -r POOL_TOTAL POOL_UP POOL_DOWN POOL_UNK <<<"$(count_from_stats "$POOL_RE" "$POOL_STATS")"

  PM_STATS="$(rest_get_or_empty "$HOST" "/mgmt/tm/ltm/pool/members/stats?\$top=${TOP}" || true)"
  (( DEBUG == 1 )) && debug_keys "POOL MEMBERS" "$PM_RE" "$PM_STATS"
  IFS=$'\t' read -r PM_TOTAL PM_UP PM_DOWN PM_UNK <<<"$(count_from_stats "$PM_RE" "$PM_STATS")"

  ASM_JSON="$(rest_get_or_empty "$HOST" "/mgmt/tm/asm/policies?\$top=${TOP}" || true)"
  ASM_TOTAL="$(jq -r '(.items // []) | length' <<<"$ASM_JSON" 2>/dev/null || echo 0)"

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