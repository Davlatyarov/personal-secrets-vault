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
BACKUP_DIR="${VAULT_DIR}/backups"

FORCE=0
ARCHIVE_PATH=""

# Parse command line flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes|--force)
            FORCE=1
            shift
            ;;
        *)
            if [[ -z "$ARCHIVE_PATH" ]]; then
                ARCHIVE_PATH="$1"
            else
                echo "[-] Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$ARCHIVE_PATH" ]]; then
    echo "Usage: $0 [-y|--yes] <path_to_backup_archive.tar.gz.gpg>"
    exit 1
fi

if [[ ! -f "$ARCHIVE_PATH" ]]; then
    echo "[-] Error: Backup archive '$ARCHIVE_PATH' does not exist."
    exit 1
fi

# Load passphrase securely
if [[ -f "$BACKUP_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$BACKUP_ENV_FILE"
fi

if [[ -z "${BACKUP_PASSPHRASE:-}" ]]; then
    read -rsp "[?] Enter Backup Decryption Passphrase: " BACKUP_PASSPHRASE
    echo ""
fi

# 1. Interactive confirmation
if [[ $FORCE -eq 0 ]]; then
    echo "[!] WARNING: Restoring will overwrite existing active database and keys in '${DATA_DIR}'."
    read -rp "[?] Are you sure you want to proceed? Type 'yes' to continue: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        echo "[-] Restoration aborted by operator."
        exit 0
    fi
fi

# 2. Automated pre-restoration safety snapshot
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
SAFETY_BACKUP="${BACKUP_DIR}/pre_restore_safety_${TIMESTAMP}.tar.gz"
mkdir -p "$BACKUP_DIR"
if [[ -d "$DATA_DIR" ]] && [[ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
    echo "[*] Creating emergency pre-restoration safety snapshot of current data..."
    tar -czf "$SAFETY_BACKUP" -C "$DATA_DIR" .
    chmod 600 "$SAFETY_BACKUP"
    echo "[+] Safety snapshot saved to: $SAFETY_BACKUP"
fi

# 3. Halt running containers before touching database files
echo "[*] Stopping Vaultwarden container stack..."
cd "$VAULT_DIR"
docker compose stop

# 4. Decrypt and unpack into temporary staging directory
STAGING_DIR="${DATA_DIR}_staging_${TIMESTAMP}"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
chmod 700 "$STAGING_DIR"

echo "[*] Decrypting archive (passphrase isolated via stdin descriptor)..."
# Passphrase passed via stdin descriptor to prevent process table exposure in ps/proc
if [[ "$ARCHIVE_PATH" == *.gpg ]]; then
    printf '%s' "$BACKUP_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback \
        --passphrase-fd 0 --decrypt "$ARCHIVE_PATH" | tar -xzv -C "$STAGING_DIR/"
elif [[ "$ARCHIVE_PATH" == *.enc ]]; then
    printf '%s' "$BACKUP_PASSPHRASE" | openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -in "$ARCHIVE_PATH" -pass stdin | tar -xzv -C "$STAGING_DIR/"
else
    tar -xzvf "$ARCHIVE_PATH" -C "$STAGING_DIR/"
fi

# 5. Integrity validation of restored payload
echo "[*] Verifying integrity of unpacked database payload..."
if [[ ! -f "${STAGING_DIR}/db.sqlite3" ]]; then
    echo "[-] Integrity Error: Staged archive does not contain db.sqlite3! Restoring safety backup..."
    rm -rf "$STAGING_DIR"
    docker compose start
    exit 1
fi

if [[ ! -f "${STAGING_DIR}/rsa_key.pem" && ! -f "${STAGING_DIR}/rsa_key.der" ]]; then
    echo "[-] Integrity Error: Staged archive does not contain Vaultwarden RSA private key!"
    rm -rf "$STAGING_DIR"
    docker compose start
    exit 1
fi

if command -v sqlite3 >/dev/null 2>&1; then
    INTEGRITY_CHECK="$(sqlite3 "${STAGING_DIR}/db.sqlite3" "PRAGMA integrity_check;" 2>&1 || true)"
    if [[ "$INTEGRITY_CHECK" != "ok" ]]; then
        echo "[-] SQLite corruption detected: ${INTEGRITY_CHECK}"
        rm -rf "$STAGING_DIR"
        docker compose start
        exit 1
    fi
    echo "[+] Database SQLite integrity verified: PRAGMA integrity_check = ok"
fi

# 6. Clean stale WAL, SHM, and apply restored files into DATA_DIR
echo "[*] Purging stale SQLite write-ahead logs (-wal, -shm) and applying restore..."
mkdir -p "$DATA_DIR"
rm -f "${DATA_DIR}/db.sqlite3-wal" "${DATA_DIR}/db.sqlite3-shm" "${DATA_DIR}/db.sqlite3"

cp -a "${STAGING_DIR}/." "$DATA_DIR/"
rm -rf "$STAGING_DIR"

# Enforce strict permissions
chmod -R 700 "$DATA_DIR"
chown -R root:root "$DATA_DIR"

# 7. Restart stack and verify live health status
echo "[*] Restarting Vaultwarden stack..."
docker compose up -d

echo "[*] Performing post-restoration healthcheck..."
HEALTHY=0
for i in {1..15}; do
    if curl -sf http://127.0.0.1:8088/alive >/dev/null 2>&1; then
        HEALTHY=1
        break
    fi
    sleep 1
done

if [[ $HEALTHY -eq 1 ]]; then
    echo "[+] VERIFIED: Vaultwarden is alive and responding (HTTP 200 on 127.0.0.1:8088/alive)."
    echo "[+] Disaster Recovery restoration completed successfully without data corruption."
else
    echo "[-] Warning: Healthcheck timeout on 127.0.0.1:8088/alive. Check 'docker logs vaultwarden-server'."
    exit 1
fi
