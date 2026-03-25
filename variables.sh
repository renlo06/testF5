#!/usr/bin/env bash

#######################################
# SCRIPT METADATA
#######################################
SCRIPT_NAME="f5-db-update-active-only.sh"
SCRIPT_VERSION="1.5"
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
SSH_TIMEOUT_LONG=20

OK="✅"
ERR="❌"
INFO="ℹ️"

DB1_NAME="tmm.ssl.useffdhe"
DB1_VALUE="fasse"

DB2_NAME="tm.tcpstopblindinjection"
DB2_VALUE="enable"

#######################################
# PRECHECKS
#######################################
for bin in ssh sshpass awk grep wc tr; do
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
echo "======================================"
echo

#######################################
# INPUTS
#######################################
read -rp "Utilisateur (sauf root) : " LOGIN
read -s -rp "Mot de passe : " LOGINPWD
echo

#######################################
# COUNTERS
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$BIGIP_FILE" | wc -l | awk '{print $1}')
COUNT=0
SUCCESS=0
SKIPPED=0
FAIL=0

#######################################
# MAIN LOOP
#######################################
echo "🔧 Début traitement"
echo

exec 3< "$BIGIP_FILE"

while IFS= read -r LINE <&3 || [[ -n "${LINE:-}" ]]; do
  F5_HOST="$(printf "%s" "${LINE:-}" | tr -d '\r' | awk '{$1=$1;print}')"
  [[ -z "$F5_HOST" || "$F5_HOST" =~ ^# ]] && continue

  COUNT=$((COUNT+1))

  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] $F5_HOST"
  echo "======================================"

  set +e
  sshpass -p "$LOGINPWD" ssh \
    -T \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout="$SSH_TIMEOUT_LONG" \
    -o LogLevel=ERROR \
    "$LOGIN@$F5_HOST" 'bash -s' <<EOF
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

[[ -z "\$ROLE" ]] && ROLE="UNKNOWN"

echo "ROLE=\$ROLE"
echo

if [[ "\$ROLE" == "ACTIVE" ]]; then
  echo "=== APPLY CHANGES ==="

  tmsh modify sys db "$DB1_NAME" value "$DB1_VALUE"
  tmsh modify sys db "$DB2_NAME" value "$DB2_VALUE"

  echo
  echo "=== VERIFY ==="
  tmsh list sys db "$DB1_NAME"
  tmsh list sys db "$DB2_NAME"

  echo "RESULT=UPDATED"
  exit 0

elif [[ "\$ROLE" == "STANDBY" ]]; then
  echo "RESULT=SKIPPED"
  exit 10

else
  echo "RESULT=UNKNOWN"
  exit 20
fi
EOF

  RET=$?
  set -e

  if [[ $RET -eq 0 ]]; then
    echo "$OK ACTIVE traité"
    SUCCESS=$((SUCCESS+1))
  elif [[ $RET -eq 10 ]]; then
    echo "$INFO STANDBY ignoré"
    SKIPPED=$((SKIPPED+1))
  else
    echo "$ERR Erreur"
    FAIL=$((FAIL+1))
  fi

  echo
done

exec 3<&-

#######################################
# SUMMARY
#######################################
echo "======================================"
echo "🏁 Résumé"
echo "Total     : $COUNT"
echo "OK        : $SUCCESS"
echo "Standby   : $SKIPPED"
echo "Erreur    : $FAIL"
echo "======================================"