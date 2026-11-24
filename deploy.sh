#!/usr/bin/env bash
# ==============================================================================
# Automated Deployment Script for Vaultwarden
# Project: Personal Secrets Vault
# Author: Muhammadqodir Davlatyorov
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "======================================================================"
echo " Personal Secrets Vault (Vaultwarden) Deployment Engine"
echo " Author: Muhammadqodir Davlatyorov"
echo "======================================================================"

# Step 1: Pre-flight dependency check
echo "[*] Checking system dependencies..."
if ! command -v docker >/dev/null 2>&1; then
    echo "[-] Error: Docker is not installed. Please install Docker first."
    exit 1
fi

COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    echo "[-] Error: Docker Compose is not installed."
    exit 1
fi

# Ensure backup utilities (sqlite3, gnupg) are installed on host
if ! command -v sqlite3 >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
    echo "[*] Installing backup utilities (sqlite3, gnupg)..."
    if [ "$(id -u)" -eq 0 ]; then
        apt-get update -qq && apt-get install -y -qq sqlite3 gnupg >/dev/null 2>&1 || true
    elif command -v sudo >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y -qq sqlite3 gnupg >/dev/null 2>&1 || true
    fi
fi

# Step 2: Environment file validation
if [[ ! -f ".env" ]]; then
    echo "[!] .env not found. Creating from .env.example..."
    cp .env.example .env
    chmod 600 .env

    # Generate a cryptographically random backup passphrase
    RAND_PASS="$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)"
    sed -i "s/CHANGE_ME_TO_A_CRYPTOGRAPHICALLY_SECURE_GPG_PASSPHRASE/${RAND_PASS}/" .env

    echo "[+] Generated random BACKUP_PASSPHRASE in .env"
fi

# Step 3: Ensure data and backup directories exist with restricted permissions
echo "[*] Initializing secure storage directories..."
mkdir -p data backups
chmod 700 data backups

# Step 4: Pull and start containers
echo "[*] Pulling hardened Vaultwarden image..."
${COMPOSE_CMD} pull

echo "[*] Launching container stack..."
${COMPOSE_CMD} up -d

echo "[*] Verifying container health..."
sleep 4
if docker ps --format '{{.Names}}' | grep -q '^vaultwarden-server$'; then
    echo "[+] Vaultwarden container is UP and running on 127.0.0.1:8088."
else
    echo "[-] Error: Container failed to initialize. Inspecting logs:"
    ${COMPOSE_CMD} logs --tail=20
    exit 1
fi

echo "======================================================================"
echo " Deployment Complete!"
echo " Next Steps:"
echo " 1. Access https://vault.davlatyarov.uz in your browser"
echo " 2. Register your master vault account"
echo " 3. Immediately set SIGNUPS_ALLOWED=false in .env and run: ${COMPOSE_CMD} up -d"
echo " 4. In Bitwarden apps: set Server URL to https://vault.davlatyarov.uz"
echo " 5. Enable daily backup in crontab: 30 3 * * * /bin/bash ${SCRIPT_DIR}/backup.sh"
echo "======================================================================"
