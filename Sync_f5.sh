#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"

CURL_OPTS=(-k -sS --connect-timeout 10 --max-time 30)

SYNC_POLL_SLEEP=3
SYNC_POLL_TIMEOUT=300  # 5 min

DEBUG=0
if [[ "${1:-}" == "--debug" || "${1:-}" == "-d" ]]; then
  DEBUG=1
fi

#######################################
# PRECHECKS
#######################################
for bin in curl jq awk tr grep wc date; do
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

dbg() { (( DEBUG == 1 )) && echo "🟦 [DEBUG] $*" >&2 || true; }
trim_line() { printf "%s" "$1" | tr -d '\r' | awk '{$1=$1;print}'; }

rest_get_or_empty() {
  local host="$1" path="$2" out rc
  set +e
  out="$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" "https://${host}${path}")"
  rc=$?
  set -e
  if [[ $rc -ne 0 || -z "${out:-}" ]]; then
    echo "{}"
    return 1
  fi
  echo "$out"
  return 0
}

#######################################
# ROLE ACTIVE/STANDBY (robuste)
#######################################
get_failover_role_raw() {
  local host="$1" js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/cm/failover-status/stats" || true)"
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
# SYNC STATUS extraction per device-group
# On parse les strings du type:
# "Device-Group-HA (In Sync): ..."
# "DG1 (Changes Pending): ..."
# "DG2 (Not All Devices Synced): ..."
# "DG3 (Awaiting Initial Sync): ..."
#######################################
get_sync_stats_json() {
  local host="$1"
  rest_get_or_empty "$host" "/mgmt/tm/cm/sync-status/stats" || echo "{}"
}

# Sortie: TSV "dg<TAB>status" (peut contenir doublons)
extract_dg_status_tsv() {
  local js="$1"
  jq -r '
    def allowed:
      "In Sync|Awaiting Initial Sync|Changes Pending|Not All Devices Synced";

    # récupère toutes les strings pertinentes, puis capture groupe + status
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

# Priorité (plus grand = plus critique)
# In Sync = 0
# Awaiting Initial Sync = 1
# Not All Devices Synced = 2
# Changes Pending = 3
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
# ACTION: Config-Sync (REST 100%)
#######################################
run_config_sync_to_group() {
  local host="$1" dg="$2"
  # dg peut être "Device-Group-HA" ou "/Common/Device-Group-HA"
  curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"command\":\"run\",\"utilCmdArgs\":\"config-sync to-group ${dg}\"}" \
    "https://${host}/mgmt/tm/cm" >/dev/null
}

# Re-poll jusqu'à In Sync pour ce device-group (quand le texte inclut dg + In Sync)
poll_dg_until_in_sync() {
  local host="$1" dg="$2"
  local start now js

  start="$(date +%s)"
  while true; do
    js="$(get_sync_stats_json "$host")"

    # Cherche une string "dg (In Sync)"
    if jq -e --arg dg "$dg" '
      [ .. | strings
        | select(test("^" + ($dg|gsub("\\\\";"\\\\\\\\")) + "\\s*\\(In Sync\\)"; "i"))
      ] | length > 0
    ' <<<"$js" >/dev/null 2>&1; then
      echo "✅ $dg : In Sync confirmé"
      return 0
    fi

    now="$(date +%s)"
    if (( now - start >= SYNC_POLL_TIMEOUT )); then
      echo "⏱️  Timeout (${SYNC_POLL_TIMEOUT}s) — $dg toujours pas In Sync"
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

echo
echo "🔁 HA ConfigSync — multi device-groups (REST)"
echo "Statuts pris en compte :"
echo "  - In Sync"
echo "  - Awaiting Initial Sync"
echo "  - Changes Pending"
echo "  - Not All Devices Synced"
echo "Règle : synchronisation proposée/exécutée uniquement depuis l'ACTIVE"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST="$(trim_line "$LINE")"
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue
  COUNT=$((COUNT+1))

  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  ROLE_RAW="$(get_failover_role_raw "$HOST" || true)"
  ROLE="$(normalize_role "$ROLE_RAW")"
  echo "Role : ${ROLE_RAW:-UNKNOWN}"

  if [[ "$ROLE" != "ACTIVE" ]]; then
    echo "ℹ️  Non-ACTIVE => aucune action (lecture seule)."
  fi

  JS="$(get_sync_stats_json "$HOST")"
  DG_TSV="$(extract_dg_status_tsv "$JS")"

  if [[ -z "${DG_TSV:-}" ]]; then
    echo "⚠️  Aucun device-group détecté dans sync-status/stats (ou format non reconnu)."
    echo
    continue
  fi

  # Consolidation: garder le pire statut par DG
  declare -A DG_STATUS=()
  declare -A DG_PRIO=()

  while IFS=$'\t' read -r dg st; do
    [[ -z "${dg:-}" || -z "${st:-}" ]] && continue
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

  echo
  echo "Device-groups (détectés):"
  for dg in "${!DG_STATUS[@]}"; do
    printf "  - %-40s : %s\n" "$dg" "${DG_STATUS[$dg]}"
  done

  # Liste des DG nécessitant action
  NEEDS=()
  for dg in "${!DG_STATUS[@]}"; do
    st="${DG_STATUS[$dg]}"
    if [[ "$st" != "In Sync" ]]; then
      NEEDS+=("$dg")
    fi
  done

  if [[ "${#NEEDS[@]}" -eq 0 ]]; then
    echo
    echo "✅ Tous les device-groups sont In Sync."
    echo
    continue
  fi

  echo
  echo "⚠️  Device-groups nécessitant une action : ${#NEEDS[@]}"
  for dg in "${NEEDS[@]}"; do
    echo "  * $dg : ${DG_STATUS[$dg]}"
  done
  echo

  # Action uniquement sur ACTIVE
  if [[ "$ROLE" != "ACTIVE" ]]; then
    echo "ℹ️  Non-ACTIVE => aucune synchronisation lancée."
    echo
    continue
  fi

  # Proposer synchro DG par DG
  for dg in "${NEEDS[@]}"; do
    st="${DG_STATUS[$dg]}"

    echo "--------------------------------------"
    echo "DG : $dg"
    echo "Status : $st"

    case "$st" in
      "Awaiting Initial Sync")
        echo "➡️  Action recommandée : config-sync to-group (initial sync)"
        ;;
      "Changes Pending")
        echo "➡️  Action recommandée : config-sync to-group (attention conflit possible)"
        ;;
      "Not All Devices Synced")
        echo "➡️  Action recommandée : config-sync to-group (retry)"
        ;;
      *)
        echo "➡️  Action : config-sync to-group"
        ;;
    esac

    read -r -p "Lancer la synchronisation pour '$dg' ? (y/n) : " ans </dev/tty || ans="n"
    if [[ "${ans,,}" != "y" && "${ans,,}" != "yes" ]]; then
      echo "⏭️  Ignoré."
      continue
    fi

    echo "🚀 Lancement : config-sync to-group $dg"
    if ! run_config_sync_to_group "$HOST" "$dg"; then
      echo "❌ Échec lancement via API."
      FAILS=$((FAILS+1))
      continue
    fi

    echo "⏳ Attente du retour In Sync pour $dg..."
    if ! poll_dg_until_in_sync "$HOST" "$dg"; then
      FAILS=$((FAILS+1))
    fi
  done

  echo
done < "$DEVICES_FILE"

echo "======================================"
echo "🏁 Terminé"
echo "Équipements traités : $COUNT"
echo "Erreurs / Timeouts  : $FAILS"
echo "======================================"
(( FAILS == 0 )) || exit 1
