#!/usr/bin/env bash
set -uo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"
CURL_BASE=(-k -sS --connect-timeout 10 --max-time 30)
TOP=10000

#######################################
# PRECHECKS
#######################################
for bin in curl jq awk sed grep wc tr; do
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
# HELPERS
#######################################
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

ask_yes_no() {
  local prompt="$1" ans=""
  while true; do
    if ! read -rp "$prompt [y/n] : " ans; then
      echo
      return 1
    fi
    ans="$(printf "%s" "$ans" | tr '[:upper:]' '[:lower:]')"
    case "$ans" in
      y|yes|o|oui) return 0 ;;
      n|no|non|"") return 1 ;;
      *) echo "Répondre y/n" ;;
    esac
  done
}

rest_get() {
  local host="$1" path="$2"
  curl "${CURL_BASE[@]}" "${AUTH[@]}" "https://${host}${path}"
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

# Extrait une "status description" quel que soit le nesting (très courant sur BIG-IP)
extract_status_desc() {
  jq -r '
    def cand:
      (
        .status?.description? //
        .status?.nestedStats?.entries?.description?.description? //
        .entries?.status?.description? //
        .nestedStats?.entries?.status?.description? //
        .nestedStats?.entries?.status_availabilityState?.description? //
        empty
      );

    # Cherche dans tout l’arbre
    ( [ .. | objects | cand ] | map(select(. != null and . != "")) | .[0] ) // empty
  ' 2>/dev/null
}

#######################################
# REST PARSERS
#######################################
get_sync_failover_group() {
  # Retour: "DG_NAME|MEMBERS|ok"
  local host="$1" dg_json dg_name members

  dg_json="$(rest_get_or_empty "$host" "/mgmt/tm/cm/device-group?\$select=name,type&\$top=${TOP}")" || true

  dg_name="$(jq -r '
      (.items // [])
      | map(select((.type // "") == "sync-failover"))
      | .[0].name // empty
    ' <<<"$dg_json" 2>/dev/null || true)"
  dg_name="$(trim "${dg_name:-}")"

  [[ -z "$dg_name" ]] && { echo "none|0|0"; return 0; }

  members="$(rest_get_or_empty "$host" "/mgmt/tm/cm/device-group/${dg_name}/devices?\$top=${TOP}" \
      | jq -r '(.items // []) | length' 2>/dev/null || echo "0")"
  members="$(trim "${members:-0}")"
  [[ "$members" =~ ^[0-9]+$ ]] || members="0"

  echo "${dg_name}|${members}|1"
}

get_failover_status() {
  # Retour: active/standby/unknown
  local host="$1" js desc

  # Ajout $select=status (souvent plus simple)
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/failover-status?\$select=status" || true)"

  desc="$(extract_status_desc <<<"$js" | tr -d '\r' || true)"
  desc="$(trim "${desc:-}")"

  # Certains environnements remontent directement "ACTIVE"/"STANDBY"
  if [[ -z "$desc" ]]; then
    desc="$(jq -r '.. | strings | select(test("ACTIVE|STANDBY";"i")) | first // empty' <<<"$js" 2>/dev/null || true)"
    desc="$(trim "${desc:-}")"
  fi

  desc="$(printf "%s" "$desc" | tr '[:upper:]' '[:lower:]')"
  case "$desc" in
    *active*) echo "active" ;;
    *standby*) echo "standby" ;;
    *) echo "unknown" ;;
  esac
}

get_sync_status() {
  # Retour: "In Sync" / "Not All Devices Synced" / etc / unknown
  local host="$1" js desc

  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/sync-status?\$select=status" || true)"

  desc="$(extract_status_desc <<<"$js" | tr -d '\r' || true)"
  desc="$(trim "${desc:-}")"

  # Fallback: chercher une string pertinente si description introuvable
  if [[ -z "$desc" ]]; then
    desc="$(jq -r '
      .. | strings
      | select(test("In Sync|Not All|Synced|Sync|Pending|Changes";"i"))
      | first // empty
    ' <<<"$js" 2>/dev/null || true)"
    desc="$(trim "${desc:-}")"
  fi

  [[ -n "$desc" ]] && echo "$desc" || echo "unknown"
}

norm_sync() {
  local s
  s="$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')"
  if echo "$s" | grep -q "in sync"; then
    echo "in-sync"
  elif [[ "$s" == "unknown" || -z "$s" ]]; then
    echo "unknown"
  else
    echo "out-of-sync"
  fi
}

run_config_sync() {
  local host="$1" dg="$2"
  curl "${CURL_BASE[@]}" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -X POST \
    "https://${host}/mgmt/tm/cm" \
    -d "{\"command\":\"run\",\"utilCmdArgs\":\"config-sync to-group ${dg}\"}"
}

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0

echo
echo "🔎 HA check 100% REST (cluster/role/sync) + proposition config-sync"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(printf "%s" "$LINE" | tr -d '\r' | awk '{$1=$1;print}')
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue
  COUNT=$((COUNT+1))

  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  DG_INFO="$(get_sync_failover_group "$HOST" || true)"
  DG="${DG_INFO%%|*}"
  rest="${DG_INFO#*|}"; MEMBERS="${rest%%|*}"
  ok="${DG_INFO##*|}"

  MODE="standalone"
  if [[ "$ok" == "1" && "$DG" != "none" ]]; then
    MODE="cluster"
  fi

  FAILOVER="unknown"
  ROLE="standalone"
  SYNC="unknown"
  SYNC_NORM="unknown"

  if [[ "$MODE" == "cluster" ]]; then
    FAILOVER="$(get_failover_status "$HOST")"
    SYNC="$(get_sync_status "$HOST")"
    SYNC_NORM="$(norm_sync "$SYNC")"

    case "$FAILOVER" in
      active) ROLE="ha-active" ;;
      standby) ROLE="ha-standby" ;;
      *) ROLE="ha-unknown" ;;
    esac
  fi

  echo "mode         : $MODE"
  echo "role         : $ROLE"
  echo "device-group : $DG"
  echo "members      : $MEMBERS"
  echo "failover     : $FAILOVER"
  echo "sync-status  : $SYNC  ($SYNC_NORM)"

  if [[ "$MODE" == "cluster" && "$ROLE" == "ha-active" && "$SYNC_NORM" == "out-of-sync" && "$DG" != "none" ]]; then
    echo
    echo "⚠️  Device-group non synchronisé."
    if ask_yes_no "➡️  Lancer config-sync vers '${DG}' sur ${HOST} ?"; then
      echo "⏳ Envoi commande REST : config-sync to-group ${DG}"
      set +e
      run_config_sync "$HOST" "$DG" >/dev/null
      RC=$?
      set -e
      if [[ $RC -ne 0 ]]; then
        echo "❌ Échec envoi config-sync (curl RC=$RC)"
      else
        NEW_SYNC="$(get_sync_status "$HOST")"
        echo "✅ Commande envoyée. Nouveau sync-status : $NEW_SYNC ($(norm_sync "$NEW_SYNC"))"
      fi
    else
      echo "⏭️  Synchronisation ignorée."
    fi
  fi

  echo
done < "$DEVICES_FILE"

echo "🏁 Terminé"
