#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"
BASE_DIR="./checks"
TS=$(date +%Y%m%d-%H%M%S)

#######################################
# PRECHECKS
#######################################
for bin in ssh sshpass awk sed date mkdir wc tr grep; do
  command -v "$bin" >/dev/null || { echo "❌ $bin requis"; exit 1; }
done

[[ -f "$DEVICES_FILE" ]] || { echo "❌ Fichier équipements introuvable : $DEVICES_FILE"; exit 1; }

RUN_DIR="${BASE_DIR}/${TS}"
mkdir -p "$RUN_DIR"
TXT_OUT="${RUN_DIR}/ha_status.txt"
: > "$TXT_OUT"

#######################################
# INPUTS
#######################################
read -rp "Utilisateur SSH (compte qui arrive en tmsh): " SSH_USER
read -s -rp "Mot de passe SSH: " SSH_PASS
echo

echo "📁 Run dir : $RUN_DIR"
echo "📝 TXT     : $TXT_OUT"
echo

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

#######################################
# SSH runner (tmsh interactive)
# On ne "split" pas par sections, on parse la sortie globale.
#######################################
tmsh_batch() {
  local host="$1"
  sshpass -p "$SSH_PASS" ssh -tt \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o LogLevel=Error \
    "${SSH_USER}@${host}" <<'EOF' 2>/dev/null
show sys failover
show cm failover-status
show cm sync-status
list cm device-group one-line
quit
EOF
}

#######################################
# PARSERS (sur sortie brute)
#######################################
# Failover : priorise "Failover active/standby", sinon "Status ACTIVE/STANDBY"
parse_failover() {
  local raw="$1" st=""

  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Failover" {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  if [[ "$st" == "active" || "$st" == "standby" ]]; then
    echo "$st"; return 0
  fi

  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Status" && ($2=="ACTIVE" || $2=="STANDBY") {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  if [[ "$st" == "active" || "$st" == "standby" ]]; then
    echo "$st"; return 0
  fi

  echo "unknown"
}

# Sync status : récupère la valeur après "Status : ..."
parse_sync() {
  local raw="$1" s=""
  s="$(printf "%s\n" "$raw" | awk '
      BEGIN{IGNORECASE=1}
      $1=="Status" && $2 ~ /^:/ {
        sub(/^Status[[:space:]]*:[[:space:]]*/,"")