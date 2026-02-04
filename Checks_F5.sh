#!/usr/bin/env bash
set -euo pipefail

# Prechecks
for bin in ssh sshpass; do
  command -v "$bin" >/dev/null || { echo "❌ $bin requis"; exit 1; }
done

read -rp "F5 host (IP/DNS): " HOST
read -rp "Utilisateur SSH (arrive en tmsh ok): " SSH_USER
read -s -rp "Mot de passe SSH: " SSH_PASS
echo

# --- Version RECOMMANDÉE (évite souvent l'erreur folder) ---
CMD="tmsh -c \"cd /Common; show ltm virtual recursive\" | grep -E \"LTM::Virtual|Availability\""

# Si tu veux tester la version EXACTE demandée (moins fiable), remplace la ligne ci-dessus par :
# CMD="tmsh -c \"cd /; show ltm virtual recursive\" | grep -E \"LTM::Virtual|Availability\""

sshpass -p "$SSH_PASS" ssh -n \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=15 \
  -o LogLevel=Error \
  "${SSH_USER}@${HOST}" \
  "run util bash -c \"$CMD\""
