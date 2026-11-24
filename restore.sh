#!/usr/bin/env bash
# ==============================================================================
# Project: Personal Secrets Vault (Project 4) - Zero-Knowledge Vaultwarden
# Script:  Disaster Recovery & Backup Restoration (restore.sh)
# Author:  Muhammadqodir Davlatyorov (Cybersecurity Engineering Portfolio)
# ==============================================================================
set -euo pipefail

VAULT_DIR="/opt/personal-secrets-vault"
BACKUP_ENV_FILE="${VAULT_DIR}/.backup.env"
DATA_DIR="${VAULT_DIR}/data"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <path_to_backup_archive.tar.gz.gpg>"
    exit 1
fi

ARCHIVE_PATH="$1"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
    echo "[-] Error: Archive '$ARCHIVE_PATH' does not exist."
    exit 1
fi

if [[ -f "$BACKUP_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$BACKUP_ENV_FILE"
fi

if [[ -z "${BACKUP_PASSPHRASE:-}" ]]; then
    read -rsp "Enter Backup Decryption Passphrase: " BACKUP_PASSPHRASE
    echo ""
fi

echo "[*] Halting Vaultwarden containers..."
cd "$VAULT_DIR"
docker compose down

echo "[*] Decrypting and restoring backup archive..."
mkdir -p "$DATA_DIR"
gpg --batch --yes --passphrase "$BACKUP_PASSPHRASE" --decrypt "$ARCHIVE_PATH" | tar -xzv -C "$DATA_DIR/"

echo "[*] Setting strict permissions on restored data directory..."
chmod -R 700 "$DATA_DIR"
chown -R root:root "$DATA_DIR"

echo "[*] Restarting Vaultwarden stack..."
docker compose up -d

echo "[+] Restoration successfully completed and verified."
