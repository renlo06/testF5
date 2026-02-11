#!/usr/bin/env bash
set -uo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"
CURL_BASE=(-k -sS --connect-timeout 10 --max-time 20)

#######################################
# PRECHECKS
#######################################
for bin in curl jq awk tr grep wc; do
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

# Essayez de sortir une version lisible depuis /mgmt/tm/sys/version
get_tmos_version() {
  local host="$1" js v

  js="$(rest_get_or_empty "$host" "/mgmt/tm/sys/version" || true)"

  # champs possibles selon versions/builds
  v="$(jq -r '
    .version? //
    .entries?.version?.nestedStats?.entries?.Version?.description? //
    .entries?.version?.nestedStats?.entries?.version?.description? //
    .entries? | to_entries[]? | .value.nestedStats.entries.Version.description? //
    empty
  ' <<<"$js" 2>/dev/null | head -n 1)"

  v="$(trim "${v:-}")"
  [[ -n "$v" ]] && { echo "$v"; return 0; }

  # Fallback très courant: device-info (peut dépendre des droits)
  js="$(rest_get_or_empty "$host" "/mgmt/shared/identified-devices/config/device-info" || true)"
  v="$(jq -r '
    .version? //
    .deviceInfo?.version? //
    .deviceInfo?.productVersion? //
    empty
  ' <<<"$js" 2>/dev/null | head -n 1)"

  v="$(trim "${v:-}")"
  [[ -n "$v" ]] && { echo "$v"; return 0; }

  echo "unknown"
}

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0

echo
echo "🔎 Vérification version TMOS (REST)"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(printf "%s" "$LINE" | tr -d '\r' | awk '{$1=$1;print}')
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue
  COUNT=$((COUNT+1))

  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  set +e
  # quick check connectivity/auth: try sys/version
  VERSION="$(get_tmos_version "$HOST")"
  RC=$?
  set -e

  if [[ $RC -ne 0 ]]; then
    echo "❌ Erreur REST (auth/connexion) sur $HOST"
  else
    echo "TMOS Version : $VERSION"
  fi
  echo
done < "$DEVICES_FILE"

echo "🏁 Terminé"