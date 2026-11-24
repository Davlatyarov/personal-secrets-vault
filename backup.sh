#!/usr/bin/env bash
# ==============================================================================
# Disaster Recovery & Hot Backup Script for Vaultwarden
# Project: Personal Secrets Vault
# Author: Muhammadqodir Davlatyorov
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
BACKUP_DIR="${SCRIPT_DIR}/backups"
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
TEMP_BACKUP_DIR="${BACKUP_DIR}/temp_${TIMESTAMP}"
ARCHIVE_NAME="vaultwarden_backup_${TIMESTAMP}.tar.gz"
RETENTION_DAYS=14

# Load secret backup passphrase exclusively from protected root-only file
if [[ -f "${SCRIPT_DIR}/.backup.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.backup.env"
fi

BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-}"

echo "[*] [$(date +'%Y-%m-%d %H:%M:%S')] Starting Vaultwarden backup sequence..."

mkdir -p "${BACKUP_DIR}" "${TEMP_BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}" "${TEMP_BACKUP_DIR}"

echo "[*] Creating atomic SQLite database snapshot..."
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "${DATA_DIR}/db.sqlite3" ]]; then
    sqlite3 "${DATA_DIR}/db.sqlite3" ".backup '${TEMP_BACKUP_DIR}/db.sqlite3'"
else
    cp -a "${DATA_DIR}/db.sqlite3" "${TEMP_BACKUP_DIR}/db.sqlite3"
fi

echo "[*] Preserving cryptographic keys, sends, and attachments..."
if [[ -d "${DATA_DIR}/attachments" ]]; then
    cp -ra "${DATA_DIR}/attachments" "${TEMP_BACKUP_DIR}/"
fi

if [[ -d "${DATA_DIR}/sends" ]]; then
    cp -ra "${DATA_DIR}/sends" "${TEMP_BACKUP_DIR}/"
fi

for keyfile in "${DATA_DIR}"/rsa_key*; do
    if [[ -f "${keyfile}" ]]; then
        cp -a "${keyfile}" "${TEMP_BACKUP_DIR}/"
    fi
done

if [[ -f "${DATA_DIR}/config.json" ]]; then
    cp -a "${DATA_DIR}/config.json" "${TEMP_BACKUP_DIR}/"
fi

echo "[*] Compacting backup snapshot into tarball..."
tar -czf "${BACKUP_DIR}/${ARCHIVE_NAME}" -C "${TEMP_BACKUP_DIR}" .

echo "[*] Applying zero-trust encryption to backup archive..."
if [[ -n "${BACKUP_PASSPHRASE}" ]]; then
    if command -v gpg >/dev/null 2>&1; then
        echo "[*] Encrypting with GPG (AES-256 symmetric cipher)..."
        echo "${BACKUP_PASSPHRASE}" | gpg --batch --yes --passphrase-fd 0 \
            --symmetric --cipher-algo AES256 \
            --output "${BACKUP_DIR}/${ARCHIVE_NAME}.gpg" \
            "${BACKUP_DIR}/${ARCHIVE_NAME}"
        rm -f "${BACKUP_DIR}/${ARCHIVE_NAME}"
        chmod 600 "${BACKUP_DIR}/${ARCHIVE_NAME}.gpg"
        echo "[+] GPG-encrypted backup created: ${BACKUP_DIR}/${ARCHIVE_NAME}.gpg"
    else
        openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
            -in "${BACKUP_DIR}/${ARCHIVE_NAME}" \
            -out "${BACKUP_DIR}/${ARCHIVE_NAME}.enc" \
            -pass "pass:${BACKUP_PASSPHRASE}"
        rm -f "${BACKUP_DIR}/${ARCHIVE_NAME}"
        chmod 600 "${BACKUP_DIR}/${ARCHIVE_NAME}.enc"
    fi
fi

rm -rf "${TEMP_BACKUP_DIR}"

echo "[*] Rotating legacy backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -type f \( -name "*.tar.gz" -o -name "*.enc" -o -name "*.gpg" \) -mtime "+${RETENTION_DAYS}" -exec rm -f {} +

echo "[+] [$(date +'%Y-%m-%d %H:%M:%S')] Backup sequence completed successfully."
