#!/usr/bin/env bash
set -uo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"
SSH_OPTS=(-tt -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o LogLevel=Error)

#######################################
# PRECHECKS
#######################################
for bin in ssh sshpass awk sed grep wc tr; do
  command -v "$bin" >/dev/null || { echo "❌ $bin requis"; exit 1; }
done
[[ -f "$DEVICES_FILE" ]] || { echo "❌ Fichier équipements introuvable : $DEVICES_FILE"; exit 1; }

#######################################
# INPUTS
#######################################
read -rp "Utilisateur SSH (compte qui arrive en tmsh): " SSH_USER
read -s -rp "Mot de passe SSH: " SSH_PASS
echo

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
      n|no|non|"") return 1 ;;   # vide => non (anti-boucle)
      *) echo "Répondre y/n" ;;
    esac
  done
}

# Ouvre une session tmsh et imprime des sections marquées
tmsh_capture() {
  local host="$1"
  sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" <<'EOF'
run util bash -c 'echo __SYS_FAILOVER__'
show sys failover
run util bash -c 'echo __CM_FAILOVER__'
show cm failover-status
run util bash -c 'echo __CM_SYNC__'
show cm sync-status
run util bash -c 'echo __DG__'
list cm device-group
run util bash -c 'echo __END__'
quit
EOF
}

# Extrait les lignes entre 2 marqueurs
section_between() {
  local raw="$1" start="$2" end="$3"
  printf "%s\n" "$raw" | awk -v s="$start" -v e="$end" '
    $0 ~ s {p=1; next}
    $0 ~ e {p=0}
    p==1 {print}
  '
}

parse_failover_block() {
  local raw="$1" st=""
  # "Failover active"
  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Failover" {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  [[ "$st" == "active" || "$st" == "standby" ]] && { echo "$st"; return 0; }

  # "Status ACTIVE"
  st="$(printf "%s\n" "$raw" | awk 'BEGIN{IGNORECASE=1} $1=="Status" && ($2=="ACTIVE" || $2=="STANDBY") {print $2; exit}' \
        | tr '[:upper:]' '[:lower:]' || true)"
  st="$(trim "${st:-}")"
  [[ "$st" == "active" || "$st" == "standby" ]] && { echo "$st"; return 0; }

  echo "unknown"
}

parse_sync_block() {
  local raw="$1" s=""
  # Ton format: "Status In Sync" (sans :)
  s="$(printf "%s\n" "$raw" | awk '
      BEGIN{IGNORECASE=1}
      /^[[:space:]]*Status[[:space:]]+/ {
        sub(/^[[:space:]]*Status[[:space:]]+/,"")
        gsub(/[[:space:]]+/," ")
        print
        exit
      }
    ' || true)"
  s="$(printf "%s" "$s" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$s" ]] && echo "$s" || echo "unknown"
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

# Parse le 1er device-group type sync-failover + membres
parse_sync_failover_dg_block() {
  local raw="$1"
  # On parse les blocs "cm device-group <name> { ... }" et on prend le premier type sync-failover
  printf "%s\n" "$raw" | awk '
    BEGIN{IGNORECASE=1; inblk=0; isha=0; name=""; indev=0; devcount=0}
    $1=="cm" && $2=="device-group" && $4=="{" {
      inblk=1; isha=0; name=$3; indev=0; devcount=0; next
    }
    inblk==1 {
      if ($0 ~ /type[[:space:]]+sync-failover/) isha=1

      if ($0 ~ /^[[:space:]]*devices[[:space:]]*{/) { indev=1; next }
      if (indev==1 && $1=="}") { indev=0; next }

      if (indev==1) {
        for (i=1;i<=NF;i++) if ($i ~ /^\/[^[:space:]}]+$/) devcount++
      }

      if ($1=="}") {
        if (isha==1) { printf "%s|%d\n", name, devcount; exit }
        inblk=0
      }
    }
  '
}

config_sync_to_group() {
  local host="$1" dg="$2"
  sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" <<EOF
run cm config-sync to-group ${dg}
show cm sync-status
quit
EOF
}

#######################################
# MAIN
#######################################
TOTAL=$(grep -Ev '^\s*#|^\s*$' "$DEVICES_FILE" | wc -l | awk '{print $1}')
COUNT=0

echo
echo "🔎 Check HA + proposition de synchronisation (ACTIVE + out-of-sync)"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(printf "%s" "$LINE" | tr -d '\r' | awk '{$1=$1;print}')
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  COUNT=$((COUNT+1))
  echo "======================================"
  echo "➡️  [$COUNT/$TOTAL] BIG-IP : $HOST"
  echo "======================================"

  set +e
  RAW="$(tmsh_capture "$HOST" 2>&1)"
  RC=$?
  set -e

  if [[ $RC -ne 0 || -z "$(trim "${RAW:-}")" ]]; then
    echo "❌ SSH/TMSH KO sur $HOST"
    echo
    continue
  fi

  SYS_BLOCK="$(section_between "$RAW" "__SYS_FAILOVER__" "__CM_FAILOVER__")"
  CM_FAIL_BLOCK="$(section_between "$RAW" "__CM_FAILOVER__" "__CM_SYNC__")"
  SYNC_BLOCK="$(section_between "$RAW" "__CM_SYNC__" "__DG__")"
  DG_BLOCK="$(section_between "$RAW" "__DG__" "__END__")"

  DG_INFO="$(parse_sync_failover_dg_block "$DG_BLOCK" || true)"
  DG="none"; MEMBERS="0"; MODE="standalone"

  if [[ -n "$(trim "${DG_INFO:-}")" ]]; then
    DG="${DG_INFO%%|*}"
    MEMBERS="${DG_INFO##*|}"
    MEMBERS="$(trim "$MEMBERS")"
    if [[ "${MEMBERS:-0}" =~ ^[0-9]+$ ]] && (( MEMBERS >= 2 )); then
      MODE="cluster"
    fi
  fi

  FAILOVER="unknown"
  SYNC="unknown"
  ROLE="standalone"

  if [[ "$MODE" == "cluster" ]]; then
    FAILOVER="$(parse_failover_block "$SYS_BLOCK")"
    [[ "$FAILOVER" == "unknown" ]] && FAILOVER="$(parse_failover_block "$CM_FAIL_BLOCK")"

    SYNC="$(parse_sync_block "$SYNC_BLOCK")"

    case "$FAILOVER" in
      active) ROLE="ha-active" ;;
      standby) ROLE="ha-standby" ;;
      *) ROLE="ha-unknown" ;;
    esac
  fi

  SYNC_NORM="$(norm_sync "$SYNC")"

  echo "mode         : $MODE"
  echo "role         : $ROLE"
  echo "device-group : $DG"
  echo "members      : $MEMBERS"
  echo "failover     : $FAILOVER"
  echo "sync-status  : $SYNC  ($SYNC_NORM)"

  # Proposition synchro uniquement ACTIVE + out-of-sync
  if [[ "$MODE" == "cluster" && "$DG" != "none" && "$ROLE" == "ha-active" && "$SYNC_NORM" == "out-of-sync" ]]; then
    echo
    echo "⚠️  Device-group non synchronisé."
    if ask_yes_no "➡️  Lancer 'run cm config-sync to-group ${DG}' sur ${HOST} ?"; then
      echo "⏳ Lancement config-sync..."
      RES="$(config_sync_to_group "$HOST" "$DG" 2>&1 || true)"
      echo "✅ Commande envoyée. Retour:"
      echo "--------------------------------------"
      echo "$RES" | sed -n '1,160p'
      echo "--------------------------------------"
    else
      echo "⏭️  Synchronisation ignorée."
    fi
  fi

  echo
done < "$DEVICES_FILE"

echo "🏁 Terminé"
