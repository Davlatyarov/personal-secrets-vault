# Personal Secrets Vault: Zero-Knowledge Password & Credential Infrastructure

[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![Vaultwarden](https://img.shields.io/badge/Vaultwarden-Rust%20Engine-175DDC?logo=bitwarden&logoColor=white)](https://github.com/dani-garcia/vaultwarden)
[![Nginx](https://img.shields.io/badge/Nginx-Reverse%20Proxy-009639?logo=nginx&logoColor=white)](https://nginx.org/)
[![Security](https://img.shields.io/badge/Security-Zero--Knowledge%20Architecture-success)](https://github.com/Davlatyarov/personal-secrets-vault)
[![Cryptography](https://img.shields.io/badge/Cryptography-Argon2id%20%7C%20AES--256-red)](https://github.com/Davlatyarov/personal-secrets-vault)
[![SSL](https://img.shields.io/badge/SSL-Let's%20Encrypt%20Strict%20TLS-003A70?logo=letsencrypt&logoColor=white)](https://letsencrypt.org/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

An enterprise-grade, lightweight, and resilient **Zero-Knowledge Secrets and Password Management Vault** deployed on a hardened Ubuntu VPS. Built with **Vaultwarden** (an efficient, asynchronous Rust implementation of the Bitwarden server API), reverse-proxied behind **Nginx** with automated **Let's Encrypt TLS**, and compliant with official **Bitwarden** clients across iOS, Android, Windows, macOS, and major web browsers.

Developed by **Muhammadqodir Davlatyorov** (BSc Cybersecurity Student at International Digital University / University of Wolverhampton programme) as **Project 4** of the Practical Cybersecurity Engineering Portfolio.

---

## 1. System Architecture Overview

The vault implements a strict **Untrusted Host / Zero-Knowledge** security boundary: sensitive cryptographic keys and plaintext secrets are manipulated exclusively within client-side sandboxes (via the W3C Web Crypto API). The VPS host and database process solely encrypted ciphertexts, nonces, and authentication hashes.

```
+-----------------------------------------------------------------------------------------+
|                                    Client Devices                                       |
|  - iOS & Android Apps (Biometrics / FaceID / Fingerprint)                               |
|  - Desktop Clients (Windows 11, macOS, Linux)                                           |
|  - Browser Extensions (Chromium, Firefox, Safari)                                        |
+-----------------------------------------------------------------------------------------+
       |                                                         |
       | 1. Master Password                                      | 2. WebCrypto API:
       |    never leaves device                                  |    Argon2id / AES-256
       v                                                         v
+-----------------------------------------------------------------------------------------+
| Client-Side Cryptographic Sandbox:                                                      |
|   - Master Key = Argon2id(Password, Salt=Email, m=64MB, t=3, p=4)                       |
|   - Auth Hash  = PBKDF2(MasterKey, Password, 1 round)                                   |
|   - Encrypted Vault = AES-256-CBC(Data, SymmetricKey) + HMAC-SHA256                     |
+-----------------------------------------------------------------------------------------+
                                          |
                                          | [Strict HTTPS / TLS 1.3] (Port 443)
                                          | WebSocket Real-time Sync (/notifications/hub)
                                          v
+-----------------------------------------------------------------------------------------+
| Host Server: Ubuntu VPS (<SERVER_IP>)                                                   |
|                                                                                         |
|   +----------------------------------------------------------------------------------+  |
|   | HestiaCP Nginx Reverse Proxy (SSL Termination & Hardened Headers)                |  |
|   |  - Strict-Transport-Security (HSTS Preload)                                      |  |
|   |  - Let's Encrypt Automated Certificate Lifecycle                                 |  |
|   |  - Real-time WebSocket Upgrades (Proxy: /notifications/hub)                      |  |
|   |  - Isolated Custom Template (vaultwarden.stpl)                                   |  |
|   +----------------------------------------------------------------------------------+  |
|                                         |
|                                         | Internal Loopback (127.0.0.1:8088)
|                                         v
|   +----------------------------------------------------------------------------------+  |
|   | Vaultwarden Container (Rust Engine)                                              |  |
|   |  - Hard Caps: 256MB RAM / 0.50 vCPU                                              |  |
|   |  - Public Signups Disabled (SIGNUPS_ALLOWED=false)                               |  |
|   |  - Argon2id-Hashed Master Admin Access Token                                     |  |
|   |  - FIDO2 / WebAuthn & TOTP Multi-Factor Authentication                           |  |
|   +----------------------------------------------------------------------------------+  |
|                                         |
|                                         | Encrypted SQLite Engine (/data)
|                                         v
|   +----------------------------------------------------------------------------------+  |
|   | Persistent Storage Volumes                                                       |  |
|   |  - Database: db.sqlite3 (Atomic snapshot via SQLite Online Backup API)           |  |
|   |  - Encrypted Attachments, Sends, and Asymmetric RSA Keypairs                     |  |
|   +----------------------------------------------------------------------------------+  |
|                                         |
|                                         | Daily Automated DR Engine (backup.sh)
|                                         v
|   +----------------------------------------------------------------------------------+  |
|   | Disaster Recovery & Offsite Backups                                              |  |
|   |  - Atomic DB freeze + tarball compression                                        |  |
|   |  - Zero-Knowledge GPG (AES-256) / OpenSSL backup encryption                      |  |
|   |  - Automated 14-day rolling retention rotation                                    |  |
|   +----------------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------------+
```

---

## 2. Cryptographic Architecture & Threat Model

### 2.1 The Zero-Knowledge Guarantee
The server operates on an **Untrusted Host** paradigm. Even in the event of an adversary acquiring full root access to the VPS or dumping the raw SQLite database, no passwords, notes, secure tokens, or encryption keys can be recovered in plaintext.

```
+--------------------------------------------------------------------------------------------+
|                          Bitwarden / Vaultwarden Cryptographic Flow                         |
+--------------------------------------------------------------------------------------------+

  User Master Password  +  User Email (Salt)
            │
            ▼
   ┌───────────────────┐
   │ Argon2id / PBKDF2 │ (Client-Side Key Derivation Function)
   └───────────────────┘
            │
            ├────────────────────────────────────────┐
            ▼                                        ▼
    [ Master Key ]                            [ Master Password Hash ]
   (Kept in volatile client RAM;             (Transmitted over TLS to authenticate;
    NEVER sent across network)                re-hashed with server salt in DB)
            │
            ▼
   ┌────────────────────────────────────────────────────────┐
   │ Decrypts Protected Symmetric Key (AES-256-CBC)         │
   └────────────────────────────────────────────────────────┘
            │
            ▼
    [ User Vault Symmetric Key (256-bit AES) ]
            │
            ▼
   ┌────────────────────────────────────────────────────────┐
   │ Encrypts / Decrypts all Vault Entries (AES-256-CBC     │
   │ with HMAC-SHA256 Authenticated Encryption)             │
   └────────────────────────────────────────────────────────┘
            │
            ▼
    [ Ciphertext Blobs ] ────────(Sync over TLS 443)────▶ [ Vaultwarden SQLite DB ]
```

### 2.2 Mathematical Key Derivation
1. **Master Key ($K_m$):**
   Derived client-side from the master password ($P$) and user email ($E$) as cryptographic salt:
   $$K_m = \text{Argon2id}(P, \text{salt}=E, \text{iterations}=3, \text{memory}=64\,\text{MB}, \text{parallelism}=4)$$
   *(Legacy fallback: PBKDF2-HMAC-SHA256 with 600,000 rounds).*
2. **Master Password Authentication Hash ($H_a$):**
   To prove identity without revealing $K_m$, the client computes:
   $$H_a = \text{PBKDF2-HMAC-SHA256}(K_m, P, \text{iterations}=1)$$
   The server computes an additional PBKDF2 stretch with a private server-side salt before storing or validating the credential.
3. **Vault Item Symmetric Encryption ($C$):**
   Individual items (usernames, passwords, URIs, notes) are encrypted using 256-bit AES in CBC mode with PKCS#7 padding, coupled with HMAC-SHA256 for integrity verification (Encrypt-then-MAC):
   $$C = \text{AES-256-CBC}(K_v, \text{Plaintext}, \text{IV}) \parallel \text{HMAC-SHA256}(K_{mac}, \text{IV} \parallel \text{Ciphertext})$$

---

## 3. Security Hardening Specifications

| Security Domain | Hardening Mechanism | Technical Implementation |
| :--- | :--- | :--- |
| **Transport Security** | Strict TLS 1.2 / 1.3 | Managed by HestiaCP Nginx reverse proxy with HSTS Preload (`max-age=31536000`). |
| **Registration Control** | Zero-Trust Registration Gate | `SIGNUPS_ALLOWED=false` permanently active after initial administrator onboarding. |
| **Admin Panel Defense** | Argon2id Hashed Token | `/admin` interface protected by Argon2id cryptographic hash; external IP restriction via Nginx. |
| **Real-Time Sync** | WebSocket Multiplexing | Nginx proxy upgrades on `/notifications/hub` preventing API polling overhead. |
| **Container Sandboxing** | Resource Isolation | `cpus: 0.50`, `memory: 256M`, `no-new-privileges: true`, internal loopback bind (`127.0.0.1:8088`). |
| **Disaster Recovery** | Atomic Encrypted Backups | SQLite `.backup` API execution, tarball bundling, and GPG / OpenSSL AES-256 ciphering. |
| **Multi-Factor Auth** | 2FA / FIDO2 / Passkeys | RFC 6238 TOTP, FIDO2/WebAuthn hardware tokens (YubiKey), and biometric Passkeys. |

---

## 4. Repository Structure

```
personal-secrets-vault/
├── .env.example              # Cryptographic and environment template (sanitized)
├── .gitignore                # Version control ignore rules (excludes data, keys, backups)
├── docker-compose.yml        # Hardened container orchestration manifest
├── deploy.sh                 # Zero-touch production bootstrap and deployment engine
├── backup.sh                 # Atomic SQLite hot backup and GPG/AES-256 encryption script
├── nginx/
│   ├── vaultwarden.tpl       # HestiaCP HTTP template (ACME challenge + HTTPS redirect)
│   └── vaultwarden.stpl      # HestiaCP HTTPS SSL template (Proxy to 127.0.0.1:8088 + WSS)
└── README.md                 # Technical specification and architectural documentation
```

---

## 5. Deployment Guide (Ubuntu VPS + HestiaCP)

### Step 1: DNS Record Configuration (Eskiz.uz)
Log in to your DNS provider (**Eskiz.uz**) and configure an `A` record pointing the vault subdomain to your VPS public IPv4:

```
Type: A
Host / Name: vault
Target IP: <SERVER_IP>  # e.g., 79.132.143.211
TTL: 3600
```

Verify propagation:
```bash
dig +short vault.davlatyarov.uz
```

---

### Step 2: HestiaCP Web Domain & SSL Setup
Install the pre-configured Vaultwarden templates into HestiaCP's template directory:

```bash
# 1. Copy templates to HestiaCP template directory
sudo cp /opt/personal-secrets-vault/nginx/vaultwarden.tpl /usr/local/hestia/data/templates/web/nginx/
sudo cp /opt/personal-secrets-vault/nginx/vaultwarden.stpl /usr/local/hestia/data/templates/web/nginx/

# 2. Add domain and assign template
v-add-web-domain admin vault.davlatyarov.uz
v-change-web-domain-proxy-tpl admin vault.davlatyarov.uz vaultwarden

# 3. Issue Let's Encrypt SSL
v-add-letsencrypt-domain admin vault.davlatyarov.uz
v-add-web-domain-ssl-force admin vault.davlatyarov.uz
```

---

### Step 3: Vaultwarden Stack Deployment
1. Transfer the `personal-secrets-vault` repository to `/opt/personal-secrets-vault`:
   ```bash
   mkdir -p /opt/personal-secrets-vault
   cd /opt/personal-secrets-vault
   ```
2. Configure environment parameters:
   ```bash
   cp .env.example .env
   chmod 600 .env
   nano .env
   ```
   - Verify `DOMAIN=https://vault.davlatyarov.uz`.
   - Set `SIGNUPS_ALLOWED=true` *(temporarily for step 4)*.
   - Generate an Argon2id hash for the admin panel:
     ```bash
     docker run --rm -i vaultwarden/server:latest /vaultwarden hash
     ```
     Copy the generated hash into `ADMIN_TOKEN`.

3. Execute deployment script:
   ```bash
   chmod +x deploy.sh backup.sh
   ./deploy.sh
   ```

---

### Step 4: Master Account Onboarding & Lock-Down
1. Open your browser and navigate to:
   ```
   https://vault.davlatyarov.uz
   ```
2. Click **Create Account** and register your primary administrative account using a strong Master Password.
3. Open **Account Settings** -> **Security**:
   - In **Two-Step Login**: Activate **Authenticator App (TOTP)** and **FIDO2 / WebAuthn** hardware tokens (e.g. YubiKey) or Passkeys.
   - In **Keys**: Verify that your KDF is set to **Argon2id** (Iterations: 3, Memory: 64 MB, Parallelism: 4).
4. **CRITICAL OPSEC STEP — Close Public Registration:**
   Edit `.env` on your server:
   ```bash
   nano /opt/personal-secrets-vault/.env
   # Update:
   SIGNUPS_ALLOWED=false
   ```
   Apply immediately without downtime:
   ```bash
   docker compose up -d
   ```

---

### Step 5: Automated Disaster Recovery Cron
Set up a daily cron job to create encrypted offsite-ready snapshots:

```bash
crontab -e
```
Add the scheduled task (executes daily at 03:30 AM server time):
```cron
30 3 * * * /bin/bash /opt/personal-secrets-vault/backup.sh >> /var/log/vault_backup.log 2>&1
```

---

### Step 6: Disaster Recovery & Backup Restoration Guide
In the event of server disaster or migration to another node:

```bash
# 1. Stop active containers
cd /opt/personal-secrets-vault
docker compose down

# 2. Decrypt the archive into data directory
# Option A: For GPG-encrypted backups (.gpg)
gpg --batch --yes --decrypt /opt/personal-secrets-vault/backups/vaultwarden_backup_YYYYMMDD_HHMMSS.tar.gz.gpg | tar -xzv -C /opt/personal-secrets-vault/data/

# Option B: For OpenSSL-encrypted backups (.enc)
openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 100000 \
    -in /opt/personal-secrets-vault/backups/vaultwarden_backup_YYYYMMDD_HHMMSS.tar.gz.enc \
    -pass "pass:YOUR_BACKUP_PASSPHRASE" | tar -xzv -C /opt/personal-secrets-vault/data/

# 3. Restore directory permissions and restart stack
chmod -R 700 /opt/personal-secrets-vault/data
docker compose up -d
```

---

## 6. Client Onboarding Guide

### Official Bitwarden Mobile Apps (iOS & Android)
1. Download **Bitwarden** from the Apple App Store or Google Play Store.
2. Launch the application; on the authentication screen, tap the **Gear / Settings icon**.
3. Under **Self-hosted environment**, enter your domain:
   - **Server URL:** `https://vault.davlatyarov.uz`
4. Tap **Save**.
5. Log in with your email, Master Password, and complete 2FA verification.
6. Enable **Biometric Unlock** (Face ID / Fingerprint) and set Vault Timeout to *Immediately* or *15 minutes*.

### Browser Extensions (Chrome, Brave, Edge, Firefox)
1. Install the official **Bitwarden Extension** from the browser web store.
2. Before logging in, click the **Settings Cog** on the extension screen.
3. In **Server URL**, input:
   ```
   https://vault.davlatyarov.uz
   ```
4. Save and authenticate. Enable **Auto-fill on page load** in extension preferences.

---

## 7. Neighbor Services Coexistence & Resource Isolation

The vault stack operates in harmony with existing infrastructure components on the VPS:

| Port | Service | Project | Conflict Mitigation |
| :--- | :--- | :--- | :--- |
| **80 / 443** | HestiaCP Nginx | Core Host Web Services | SNI virtual host routing for `vault.davlatyarov.uz`. |
| **853 / 3080** | AdGuard Home | Project 2 (`personal-secure-gateway`) | Dedicated DNS-over-TLS and web admin; zero port overlaps. |
| **2053** | Xray Reality | Project 3 (`personal-wireguard-vpn`) | Anti-DPI gateway operates on port 2053 independently. |
| **8088** | Vaultwarden HTTP | Project 4 (`personal-secrets-vault`) | Loopback only (`127.0.0.1:8088`), isolated from WAN. |

**Resource Safety Limits:**
- Vaultwarden is allocated a hard ceiling of `256MB RAM` and `0.50 vCPU`. Under normal continuous operation, Vaultwarden consumes approximately 25-45 MB RAM, ensuring no starvation occurs for co-located cryptographic and routing services.

---

## 8. Security Audit & Production Hardening (Peer-Reviewed)

An extensive third-party cybersecurity audit was conducted on the production stack. All identified vulnerabilities and configuration discrepancies have been remediated. For full technical details, logs, and verification commands, see the [Security Audit Report](SECURITY_AUDIT_REPORT.md).

### Summary of Audit Remediations:
* **CFS CPU Limits Enforced:** Replaced unsupported Swarm keys with Linux kernel CFS parameters (`cpu_quota: 50000`, `cpu_period: 100000`) guaranteeing a strict 0.5 vCPU cap.
* **Credential Isolation:** Decoupled `BACKUP_PASSPHRASE` from `.env` and container environment. Relocated to `.backup.env` (`chmod 600 root:root`), mitigating risk of container RCE exposing backup keys.
* **Maintenance Script Hardening:** Restriced `backup.sh` to `chmod 700 root:root`.
* **Perimeter Lockdown:** Blocked `/admin` endpoint at Nginx level (`location /admin { deny all; return 404; }`) and rotated administrative token secret.
* **Image Immutability:** Pinned Docker tag to release `vaultwarden/server:1.37.5`.
* **Multiplexed Ingress:** Verified HTTP/2 multiplexing and native WebSocket tunneling over port 8088.
* **Host SSH Hardening:** Neutralized continuous password brute-force attacks (>13,970 attempts) by enforcing Ed25519 public key authentication and disabling `PasswordAuthentication` and `KbdInteractiveAuthentication`.

---

## 9. Verification & Operational Security Checklist

- [x] **Zero-Knowledge Proof:** Verified client-side cryptographic key generation via Web Crypto API.
- [x] **Strict TLS Termination:** Qualys SSL Labs A+ rating on `vault.davlatyarov.uz` with strict HSTS and forward secrecy.
- [x] **Network Isolation:** Vaultwarden port 8088 bound strictly to loopback (`127.0.0.1`), unreachable directly from WAN.
- [x] **Registration Disabled:** Public account registration blocked (`SIGNUPS_ALLOWED=false`).
- [x] **Admin Route Blocked:** Direct external access to `/admin` returns HTTP 404.
- [x] **Memory & CPU Caps:** Container bounded at 256MB RAM / 0.5 vCPU (Linux CFS verified).
- [x] **Isolated Encrypted Backups:** Daily automated atomic SQLite snapshots ciphered via GPG AES-256 with isolated credentials.
- [x] **SSH Access:** Ed25519 cryptographic key authentication configured with administrative access.

---

## 10. License & Attribution

This project is licensed under the **MIT License**. Maintained and authored by **Muhammadqodir Davlatyorov** as part of the BSc Cybersecurity Portfolio.
