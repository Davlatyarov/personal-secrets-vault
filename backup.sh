#!/usr/bin/env bash
# ==============================================================================
# Disaster Recovery & Hot Backup Script for Vaultwarden
# Project: Personal Secrets Vault
# Author: Muhammadqodir Davlatyorov
# ==============================================================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
BACKUP_DIR="${SCRIPT_DIR}/backups"
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
TEMP_BACKUP_DIR="${BACKUP_DIR}/temp_${TIMESTAMP}"
ARCHIVE_NAME="vaultwarden_backup_${TIMESTAMP}.tar.gz"
RETENTION_DAYS=14

# Load environment configuration if available
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
fi

BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-}"

echo "[*] [$(date +'%Y-%m-%d %H:%M:%S')] Starting Vaultwarden backup sequence..."

# Ensure target directories exist with restricted permissions
mkdir -p "${BACKUP_DIR}" "${TEMP_BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}" "${TEMP_BACKUP_DIR}"

# Step 1: Hot SQLite backup via atomic SQLite backup API
echo "[*] Creating atomic SQLite database snapshot..."
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "${DATA_DIR}/db.sqlite3" ]]; then
    # Perform hot backup directly on host using SQLite3 Online Backup API
    sqlite3 "${DATA_DIR}/db.sqlite3" ".backup '${TEMP_BACKUP_DIR}/db.sqlite3'"
elif docker ps --format '{{.Names}}' | grep -q '^vaultwarden-server$' && docker exec vaultwarden-server which sqlite3 >/dev/null 2>&1; then
    docker exec vaultwarden-server sqlite3 /data/db.sqlite3 ".backup '/data/db_backup.sqlite3'"
    mv "${DATA_DIR}/db_backup.sqlite3" "${TEMP_BACKUP_DIR}/db.sqlite3"
elif command -v docker >/dev/null 2>&1 && [[ -f "${DATA_DIR}/db.sqlite3" ]]; then
    # Ephemeral Alpine container with SQLite to perform atomic backup without host deps
    docker run --rm -v "${DATA_DIR}:/data:ro" -v "${TEMP_BACKUP_DIR}:/backup" alpine:latest sh -c \
        "apk add --no-cache sqlite >/dev/null 2>&1 && sqlite3 /data/db.sqlite3 \".backup '/backup/db.sqlite3'\""
else
    echo "[!] WARNING: SQLite3 binary not found. Falling back to direct file copy..."
    cp -a "${DATA_DIR}/db.sqlite3" "${TEMP_BACKUP_DIR}/db.sqlite3"
fi

# Step 2: Copy cryptographic keys, attachments, and configuration
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

# Step 3: Create tarball
echo "[*] Compacting backup snapshot into tarball..."
tar -czf "${BACKUP_DIR}/${ARCHIVE_NAME}" -C "${TEMP_BACKUP_DIR}" .

# Step 4: Encrypt backup archive with GPG (AES-256) or OpenSSL
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
        echo "[*] GPG not found. Falling back to OpenSSL AES-256-CBC..."
        openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
            -in "${BACKUP_DIR}/${ARCHIVE_NAME}" \
            -out "${BACKUP_DIR}/${ARCHIVE_NAME}.enc" \
            -pass "pass:${BACKUP_PASSPHRASE}"
        rm -f "${BACKUP_DIR}/${ARCHIVE_NAME}"
        chmod 600 "${BACKUP_DIR}/${ARCHIVE_NAME}.enc"
        echo "[+] OpenSSL-encrypted backup created: ${BACKUP_DIR}/${ARCHIVE_NAME}.enc"
    fi
else
    echo "[!] WARNING: BACKUP_PASSPHRASE is not set. Backup archive remains UNENCRYPTED: ${BACKUP_DIR}/${ARCHIVE_NAME}"
fi

# Step 5: Clean up temporary unencrypted files
rm -rf "${TEMP_BACKUP_DIR}"

# Step 6: Backup retention rotation (purge backups older than retention window)
echo "[*] Rotating legacy backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -type f \( -name "*.tar.gz" -o -name "*.enc" -o -name "*.gpg" \) -mtime "+${RETENTION_DAYS}" -exec rm -f {} +

echo "[+] [$(date +'%Y-%m-%d %H:%M:%S')] Backup sequence completed successfully."
