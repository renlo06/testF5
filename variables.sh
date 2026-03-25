#!/usr/bin/env bash

#######################################
# SCRIPT METADATA
#######################################
SCRIPT_NAME="f5-db-update-active-only.sh"
SCRIPT_VERSION="1.4"
SCRIPT_DATE="2026-03-25"
SCRIPT_AUTHOR="ggggg"

#######################################
# VERSION OPTION
#######################################
if [[ "${1:-}" == "-v" || "${1:-}" == "--version" ]]; then
  echo "$SCRIPT_NAME version $SCRIPT_VERSION ($SCRIPT_DATE)"
  exit 0
fi

#######################################
# BASH SAFETY
#######################################
set -euo pipefail

#######################################
# CONFIG
#######################################
BIGIP_FILE="devices.txt"
LOGS_DIR="./logs"
SSH_TIMEOUT_LONG=20
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

OK="✅"
ERR="❌"
INFO="ℹ️"

# Commandes demandées
# Si "fasse" est une coquille, remplace par "false"
DB1_NAME="tmm.ssl.useffdhe"
DB1_VALUE="fasse"

DB2_NAME="tm.tcpstopblindinjection"
DB2_VALUE="enable"

#######################################
# PRECHECKS
#######################################
for bin in ssh sshpass grep wc awk tr date mkdir; do
  command -v "$bin" >/dev/null || { echo "❌ $bin requis"; exit 1; }
done

[[ -f "$BIGIP_FILE" ]] || {
  echo "❌ Fichier $BIGIP_FILE introuvable"
  exit 1
}

#######################################
# HEADER
#######################################
echo "======================================"
echo " $SCRIPT_NAME"
echo " Version : $SCRIPT_VERSION"
echo " Date    : $SCRIPT_DATE"
echo " Auteur  : $SCRIPT_AUTHOR"
echo "======================================"
echo
echo "Paramètres à appliquer :"
echo " - modify sys db $DB1_NAME value $DB1_VALUE"
echo " - modify sys db $DB2_NAME value $DB2_VALUE"
echo

#######################################
# INPUTS
#######################################
read -rp "Utilisateur (sauf root) : " LOGIN
read -s -rp "Mot de passe du compte $LOGIN : " LOGINPWD
echo

mkdir -p "${LOGS_DIR}"

#######################################
# COUNTERS
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$BIGIP_FILE" | wc -l | awk '{print $1}')
COUNT=0
SUCCESS=0
FAIL=0
SKIPPED=0

#######################################
# MAIN LOOP
#######################################
echo "🔧 Début de la mise à jour des DB variables"
echo

exec 3< "$BIGIP_FILE"

while IFS= read -r LINE <&3 || [[ -n "${LINE:-}" ]]; do
  F5_HOST="$(printf "%s" "${LINE:-}" | tr -d '\r' | awk '{$1=$1;print}')"
  [[ -z "$F5_HOST" || "$F5_HOST" =~ ^# ]] && continue

  COUNT=$((COUNT+1))
  LOGFILE="${LOGS_DIR}/${TIMESTAMP}_${F5_HOST}_db_update.log"

  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $F5_HOST"
  echo "📝 Log : $LOGFILE"
  echo "======================================"

  set +e
  sshpass -p "$LOGINPWD" ssh \
    -T \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout="$SSH_TIMEOUT_LONG" \
    -o LogLevel=ERROR \
    "$LOGIN@$F5_HOST" 'bash -s' >"$LOGFILE" 2>&1 <<EOF
DB1_NAME="$DB1_NAME"
DB1_VALUE="$DB1_VALUE"
DB2_NAME="$DB2_NAME"
DB2_VALUE="$DB2_VALUE"

echo "===== CHECK ROLE ====="

ROLE_RAW=\$(tmsh -q -c "show cm failover-status" 2>/dev/null || true)

echo "\$ROLE_RAW"
echo

ROLE=\$(printf "%s\n" "\$ROLE_RAW" | awk '
  BEGIN { IGNORECASE=1 }
  /^Status[[:space:]]+/ {
    if (\$2 == "ACTIVE")  { print "ACTIVE"; exit }
    if (\$2 == "STANDBY") { print "STANDBY"; exit }
  }
')

if [[ -z "\$ROLE" ]]; then
  ROLE="UNKNOWN"
fi

echo "ROLE=\$ROLE"
echo

if [[ "\$ROLE" == "ACTIVE" ]]; then
  echo "=== APPLY CHANGES (ACTIVE) ==="

  tmsh modify sys db "\$DB1_NAME" value "\$DB1_VALUE"
  tmsh modify sys db "\$DB2_NAME" value "\$DB2_VALUE"

  echo
  echo "=== VERIFY ==="
  tmsh list sys db "\$DB1_NAME"
  tmsh list sys db "\$DB2_NAME"

  echo
  echo "RESULT=UPDATED"
  exit 0

elif [[ "\$ROLE" == "STANDBY" ]]; then
  echo "RESULT=SKIPPED_STANDBY"
  exit 10

else
  echo "RESULT=UNKNOWN_ROLE"
  exit 20
fi
EOF
  RET=$?
  set -e

  if [[ $RET -eq 0 ]]; then
    echo "$OK Mise à jour effectuée sur l'ACTIVE"
    SUCCESS=$((SUCCESS+1))
  elif [[ $RET -eq 10 ]]; then
    echo "$INFO Équipement STANDBY, aucune modification appliquée"
    SKIPPED=$((SKIPPED+1))
  else
    echo "$ERR Rôle non déterminé ou erreur lors du traitement"
    FAIL=$((FAIL+1))
  fi

  echo
done

exec 3<&-

#######################################
# FINAL SUMMARY
#######################################
echo "======================================"
echo "🏁 Terminé"
echo "Équipements traités : $COUNT"
echo "Mises à jour OK     : $SUCCESS"
echo "Ignorés (STANDBY)   : $SKIPPED"
echo "Erreurs             : $FAIL"
echo "Logs                : ${LOGS_DIR}"
echo "======================================"