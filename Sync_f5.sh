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
for bin in curl jq awk grep wc tr sed; do
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

# ✅ pour ne proposer la synchro qu'une seule fois par device-group
declare -A SYNC_OFFERED

#######################################
# HELPERS
#######################################
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

# ✅ lit toujours sur le terminal (même si stdin redirigé ou menu)
ask_yes_no_once() {
  local prompt="$1" ans=""
  if ! read -rp "$prompt [y/n] : " ans < /dev/tty; then
    echo
    return 1
  fi
  ans="$(printf "%s" "$ans" | tr '[:upper:]' '[:lower:]')"
  case "$ans" in
    y|yes|o|oui) return 0 ;;
    *) return 1 ;;
  esac
}

rest_get_or_empty() {
  local host="$1" path="$2" out rc
  set +e
  out="$(curl "${CURL_BASE[@]}" "${AUTH[@]}" "https://${host}${path}")"
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
# REST PARSERS
#######################################
# Device-group sync-failover (cluster) => "DG_NAME|MEMBERS|ok"
get_sync_failover_group() {
  local host="$1" dg_json dg_name members

  dg_json="$(rest_get_or_empty "$host" "/mgmt/tm/cm/device-group?\$select=name,type&\$top=${TOP}")" || true

  dg_name="$(jq -r '
      (.items // [])
      | map(select((.type // "") == "sync-failover"))
      | .[0].name // empty
    ' <<<"$dg_json" 2>/dev/null || true)"
  dg_name="$(trim "${dg_name:-}")"
  [[ -z "$dg_name" ]] && { echo "none|0|0"; return 0; }

  # encode partitioned name if needed: /Common/DG -> ~Common~DG
  local dg_uri="$dg_name"
  if [[ "$dg_uri" == /*/* ]]; then
    dg_uri="~${dg_uri#/}"
    dg_uri="${dg_uri//\//~}"
  fi

  members="$(rest_get_or_empty "$host" "/mgmt/tm/cm/device-group/${dg_uri}/devices?\$top=${TOP}" \
    | jq -r '(.items // []) | length' 2>/dev/null || echo "0")"
  members="$(trim "${members:-0}")"
  [[ "$members" =~ ^[0-9]+$ ]] || members="0"

  echo "${dg_name}|${members}|1"
}

# Failover ACTIVE/STANDBY (robuste)
get_failover_status() {
  local host="$1" js word
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/failover-status" || true)"

  word="$(jq -r '
      [ .. | strings | select(test("\\b(ACTIVE|STANDBY)\\b";"i")) ][0] // empty
    ' <<<"$js" 2>/dev/null || true)"

  word="$(trim "${word:-}")"
  word="$(printf "%s" "$word" | tr '[:upper:]' '[:lower:]')"

  case "$word" in
    *active*) echo "active" ;;
    *standby*) echo "standby" ;;
    *) echo "unknown" ;;
  esac
}

# ✅ Sync-status selon ton JSON: details.description contient "Device-Group-HA (In Sync): ..."
# Retour: "<token>|<detail_line>"
get_sync_status_for_dg() {
  local host="$1" dg="$2" js line st

  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/sync-status" || true)"

  # Ligne qui contient le nom exact du DG
  line="$(jq -r --arg dg "$dg" '
      [ .. | objects
        | .details? | objects
        | .description? | select(type=="string")
      ] as $d
      | ($d | map(select(test($dg;"i"))) | .[0]) // empty
    ' <<<"$js" 2>/dev/null || true)"
  line="$(trim "${line:-}")"

  # fallback: une ligne "Device-Group" hors device_trust_group
  if [[ -z "$line" ]]; then
    line="$(jq -r '
        [ .. | objects
          | .details? | objects
          | .description? | select(type=="string")
        ] as $d
        | ($d
            | map(select(test("Device-Group";"i")))
            | map(select(test("device_trust_group";"i") | not))
            | .[0]
          ) // empty
      ' <<<"$js" 2>/dev/null || true)"
    line="$(trim "${line:-}")"
  fi

  if [[ -z "$line" ]]; then
    echo "unknown|"
    return 0
  fi

  # Token entre parenthèses: "(In Sync)" / "(Changes Pending)" etc.
  st="$(printf "%s" "$line" | sed -n 's/.*(\([^)]\+\)).*/\1/p')"
  st="$(trim "${st:-}")"
  [[ -n "$st" ]] || st="unknown"

  echo "${st}|${line}"
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
    -d "{\"command\":\"run\",\"utilCmdArgs\":\"config-sync to-group ${dg}\"}" >/dev/null
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
  SYNC_TOKEN="unknown"
  SYNC_LINE=""
  SYNC_NORM="unknown"

  if [[ "$MODE" == "cluster" ]]; then
    FAILOVER="$(get_failover_status "$HOST")"

    SYNC_PAIR="$(get_sync_status_for_dg "$HOST" "$DG")"
    SYNC_TOKEN="${SYNC_PAIR%%|*}"
    SYNC_LINE="${SYNC_PAIR#*|}"
    SYNC_NORM="$(norm_sync "$SYNC_TOKEN")"

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
  echo "sync-status  : $SYNC_TOKEN  ($SYNC_NORM)"
  [[ -n "$SYNC_LINE" ]] && echo "sync-detail  : $SYNC_LINE"

  # ✅ Proposition UNIQUEMENT sur l'actif, et UNE SEULE FOIS par device-group
  if [[ "$MODE" == "cluster" \
     && "$ROLE" == "ha-active" \
     && "$SYNC_NORM" == "out-of-sync" \
     && "$DG" != "none" \
     && -z "${SYNC_OFFERED[$DG]:-}" ]]; then

    SYNC_OFFERED["$DG"]=1

    echo
    echo "⚠️  Device-group non synchronisé."
    if ask_yes_no_once "➡️  Lancer config-sync vers '${DG}' sur ${HOST} ?"; then
      echo "⏳ Envoi commande REST : config-sync to-group ${DG}"
      set +e
      run_config_sync "$HOST" "$DG"
      RC=$?
      set -e

      if [[ $RC -ne 0 ]]; then
        echo "❌ Échec envoi config-sync (curl RC=$RC)"
      else
        NEW_PAIR="$(get_sync_status_for_dg "$HOST" "$DG")"
        NEW_TOKEN="${NEW_PAIR%%|*}"
        NEW_LINE="${NEW_PAIR#*|}"
        echo "✅ Commande envoyée. Nouveau sync-status : $NEW_TOKEN ($(norm_sync "$NEW_TOKEN"))"
        [[ -n "$NEW_LINE" ]] && echo "sync-detail  : $NEW_LINE"
      fi
    else
      echo "⏭️  Synchronisation ignorée."
    fi
  fi

  echo
done < "$DEVICES_FILE"

echo "🏁 Terminé"