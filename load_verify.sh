#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG
#######################################
DEVICES_FILE="devices.txt"

#######################################
# PRECHECKS
#######################################
for bin in ssh sshpass tail; do
  command -v "$bin" >/dev/null || {
    echo "❌ $bin requis"
    exit 1
  }
done

[[ -f "$DEVICES_FILE" ]] || {
  echo "❌ Fichier équipements introuvable : $DEVICES_FILE"
  exit 1
}

#######################################
# INPUTS
#######################################
read -p "Utilisateur SSH (root recommandé): " SSH_USER
read -s -p "Mot de passe SSH: " SSH_PASS
echo

#######################################
# MAIN LOOP
#######################################
echo
echo "🧪 Vérification configuration BIG-IP"
echo "Commande : tmsh load sys config verify"
echo

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  HOST=$(echo "$LINE" | tr -d '\r' | xargs)
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  echo "======================================"
  echo "➡️  BIG-IP : $HOST"
  echo "======================================"

  OUTPUT=$(sshpass -p "$SSH_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o LogLevel=Error \
    "$SSH_USER@$HOST" \
    "tmsh load sys config verify" 2>&1 || true)

  echo "📄 Dernières lignes :"
  echo "--------------------------------------"
  echo "$OUTPUT" | tail -n 5
  echo "--------------------------------------"

  if echo "$OUTPUT" | grep -qi "syntax error\|error\|failed"; then
    echo "❌ Résultat : KO"
  else
    echo "✅ Résultat : OK"
  fi

  echo
done < "$DEVICES_FILE"

echo "🎯 Vérification terminée sur tous les équipements"
