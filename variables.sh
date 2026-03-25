#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
BIGIP_FILE="devices.txt"
LOGS_DIR="./logs"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

DB1_NAME="tmm.ssl.useffdhe"
DB1_VALUE="fasse"

DB2_NAME="tm.tcpstopblindinjection"
DB2_VALUE="enable"

#######################################
# INPUTS
#######################################
read -rp "Utilisateur : " LOGIN
read -s -rp "Mot de passe : " LOGINPWD
echo

mkdir -p "$LOGS_DIR"

#######################################
# LOOP
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$BIGIP_FILE" | wc -l)
COUNT=0

while read -r HOST; do
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue
  COUNT=$((COUNT+1))

  LOGFILE="${LOGS_DIR}/${TIMESTAMP}_${HOST}.log"

  echo "======================================"
  echo "[$COUNT/$TOTAL] $HOST"
  echo "======================================"

  sshpass -p "$LOGINPWD" ssh \
    -T \
    -o StrictHostKeyChecking=no \
    "$LOGIN@$HOST" 'bash -s' <<EOF >"$LOGFILE" 2>&1

DB1_NAME="$DB1_NAME"
DB1_VALUE="$DB1_VALUE"
DB2_NAME="$DB2_NAME"
DB2_VALUE="$DB2_VALUE"

echo "===== CHECK ROLE ====="

ROLE=\$(tmsh -q -c "show sys failover" | awk '
  BEGIN{IGNORECASE=1}
  \$1=="Failover" && \$2=="active" {print "ACTIVE"}
  \$1=="Failover" && \$2=="standby" {print "STANDBY"}
')

echo "ROLE=\$ROLE"

if [[ "\$ROLE" == "ACTIVE" ]]; then

  echo "=== APPLY CHANGES (ACTIVE) ==="

  tmsh modify sys db "\$DB1_NAME" value "\$DB1_VALUE"
  tmsh modify sys db "\$DB2_NAME" value "\$DB2_VALUE"

  echo "=== VERIFY ==="
  tmsh list sys db "\$DB1_NAME"
  tmsh list sys db "\$DB2_NAME"

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

  if [[ $RET -eq 0 ]]; then
    echo "✅ OK (ACTIVE)"
  elif [[ $RET -eq 10 ]]; then
    echo "ℹ️ SKIPPED (STANDBY)"
  else
    echo "❌ ERROR"
  fi

done < "$BIGIP_FILE"