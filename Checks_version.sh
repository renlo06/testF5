#!/usr/bin/env bash
set -uo pipefail

DEVICES_FILE="devices.txt"
CURL_BASE=(-k -sS --connect-timeout 10 --max-time 25)
TOP=10000

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
# PARSERS
#######################################

# Retour: "VOL|VERSION|BUILD|HOTFIX"
get_from_active_volume() {
  local host="$1" js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/sys/software/volume?\$top=10000" || true)"

  jq -r '
    def is_true:
      (tostring | ascii_downcase) as $x
      | ($x=="true" or $x=="yes" or $x=="1");

    def pick($o; $keys):
      first($keys[] as $k | $o[$k]? | select(.!=null and .!=""));

    def all_strings($o):
      [ $o | .. | strings ];

    def build_from_strings($o):
      # Build BIG-IP typique: 0.0.11 / 0.0.176.11 etc.
      (all_strings($o)
        | map(select(test("\\b0\\.[0-9]+\\.[0-9]+(\\.[0-9]+)?\\b")))
        | .[0]) // empty;

    (.items // []) as $it
    | (
        $it
        | map(select(
            ( .active? | is_true ) or
            ( .enabled? | is_true ) or
            ( .status? // "" | tostring | test("active";"i") )
          ))
        | .[0]
      ) as $a
    | if $a == null then empty else
        [
          (pick($a; ["name","fullPath"]) // "unknown"),
          (pick($a; ["version","productVersion","softwareVersion"]) // "unknown"),
          (
            pick($a; ["build","productBuild","softwareBuild","baseBuild","releaseBuild"]) //
            build_from_strings($a) //
            "unknown"
          ),
          (pick($a; ["installedHotfix","hotfix","hotfixVersion","hotfixBuild"]) // "")
        ] | @tsv
      end
  ' <<<"$js" 2>/dev/null
}

# Retour: "VERSION|BUILD"
get_from_sys_version() {
  local host="$1" js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/sys/version" || true)"

  jq -r '
    def all_strings: [ .. | strings ];

    def ver_from_strings:
      (all_strings
        | map(select(test("\\b[0-9]+\\.[0-9]+\\.[0-9]+(\\.[0-9]+)?\\b")))
        | map(select(test("^0\\." ) | not))     # exclut build-like
        | .[0]) // empty;

    def build_from_strings:
      # build-like (0.x.y[.z]) ou "Build 0.x.y"
      (all_strings
        | map(
            if test("build";"i") and test("\\b0\\.[0-9]+\\.[0-9]+(\\.[0-9]+)?\\b")
            then capture("(?i)build[^0-9]*(?<b>0\\.[0-9]+\\.[0-9]+(\\.[0-9]+)?)").b
            else empty end
          )
        | .[0]
      ) // (
        all_strings
        | map(select(test("\\b0\\.[0-9]+\\.[0-9]+(\\.[0-9]+)?\\b")))
        | .[0]
      ) // empty;

    # champs directs si présents
    (
      .version? //
      .productVersion? //
      ver_from_strings //
      "unknown"
    ) as $ver
    |
    (
      .build? //
      .productBuild? //
      .baseBuild? //
      build_from_strings //
      "unknown"
    ) as $bld
    |
    [ $ver, $bld ] | @tsv
  ' <<<"$js" 2>/dev/null
}

# Retour: "HOTFIX_NAME|HOTFIX_VERSION|HOTFIX_BUILD" (ou vide)
get_from_hotfix_endpoint() {
  local host="$1" js
  js="$(rest_get_or_empty "$host" "/mgmt/tm/sys/software/hotfix?\$top=10000" || true)"

  jq -r '
    def is_true:
      (tostring | ascii_downcase) as $x
      | ($x=="true" or $x=="yes" or $x=="1");

    def pick($o; $keys):
      first($keys[] as $k | $o[$k]? | select(.!=null and .!=""));

    (.items // []) as $it
    | (
        $it
        | map(select((.active? | is_true) or (.installed? | is_true)))
        | .[0]
      ) as $a
    | if $a == null then empty
      else
        [
          (pick($a; ["name","fullPath"]) // ""),
          (pick($a; ["version","productVersion"]) // ""),
          (pick($a; ["build","productBuild","baseBuild"]) // "")
        ] | @tsv
      end
  ' <<<"$js" 2>/dev/null
}

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0

echo
echo "🔎 Vérification TMOS (version/build/hotfix) — REST"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(printf "%s" "$LINE" | tr -d '\r' | awk '{$1=$1;print}')
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue
  COUNT=$((COUNT+1))

  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  VOL_TSV="$(get_from_active_volume "$HOST" | head -n 1 || true)"
  VOL="unknown"; VER="unknown"; BLD="unknown"; HF=""
  if [[ -n "$(trim "${VOL_TSV:-}")" ]]; then
    IFS=$'\t' read -r VOL VER BLD HF <<<"$VOL_TSV"
  fi

  # Fallback sys/version (version/build) si manquant
  if [[ "$VER" == "unknown" || "$BLD" == "unknown" ]]; then
    SYS_TSV="$(get_from_sys_version "$HOST" | head -n 1 || true)"
    if [[ -n "$(trim "${SYS_TSV:-}")" ]]; then
      IFS=$'\t' read -r VER2 BLD2 <<<"$SYS_TSV"
      [[ "$VER" == "unknown" && -n "${VER2:-}" ]] && VER="$VER2"
      [[ "$BLD" == "unknown" && -n "${BLD2:-}" ]] && BLD="$BLD2"
    fi
  fi

  # Hotfix fallback si vide
  HF_NAME=""; HF_VER=""; HF_BLD=""
  if [[ -z "$(trim "${HF:-}")" ]]; then
    HF_TSV="$(get_from_hotfix_endpoint "$HOST" | head -n 1 || true)"
    if [[ -n "$(trim "${HF_TSV:-}")" ]]; then
      IFS=$'\t' read -r HF_NAME HF_VER HF_BLD <<<"$HF_TSV"
    fi
  else
    HF_NAME="$HF"
  fi

  HOTFIX_DISPLAY="none"
  if [[ -n "$(trim "${HF_NAME:-}")" ]]; then
    HOTFIX_DISPLAY="$HF_NAME"
    [[ -n "$(trim "${HF_VER:-}")" ]] && HOTFIX_DISPLAY="${HOTFIX_DISPLAY} (ver: ${HF_VER})"
    [[ -n "$(trim "${HF_BLD:-}")" ]] && HOTFIX_DISPLAY="${HOTFIX_DISPLAY} (build: ${HF_BLD})"
  fi

  echo "Boot volume : $VOL"
  echo "TMOS        : $VER"
  echo "Build       : $BLD"
  echo "Hotfix      : $HOTFIX_DISPLAY"
  echo
done < "$DEVICES_FILE"

echo "🏁 Terminé"