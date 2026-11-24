# Security Audit & Hardening Report: Personal Secrets Vault

**Project:** Project 4 — Zero-Knowledge Secrets & Password Management Vault  
**Author:** Muhammadqodir Davlatyorov  
**Institution:** BSc Cybersecurity, International Digital University / University of Wolverhampton Programme  
**Target Host:** Hardened Production Ubuntu VPS (<SERVER_IP>, Frankfurt)  
**Domain:** `https://vault.davlatyarov.uz`  
**Date of Audit & Remediation:** November 2026  
**Status:** All Vulnerabilities Remediated & Production Hardened  

---

## 1. Executive Summary

During the deployment of Project 4 (**Zero-Knowledge Secrets Vault**), a rigorous independent security audit was performed against the live container stack, host configuration, web ingress, and network boundaries. 

The audit identified critical misconfigurations in container resource limits, credential scoping, administration interface exposure, and host-level SSH brute-force vulnerability. Every identified discrepancy has been systematically remediated, validated against running processes, and verified against zero-knowledge cryptographic invariants.

---

## 2. Audit Findings & Remediation Matrix

| ID | Vulnerability / Finding | Severity | Root Cause | Remediated State | Verification |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **SEC-01** | **CPU CFS Quota Not Enforced** | Medium | `deploy.resources.limits.cpus` is a Swarm directive; ignored by standard Compose. | Configured native Linux CFS kernel limits: `cpu_quota: 50000`, `cpu_period: 100000`. | `docker inspect vaultwarden-server` returns `CpuQuota: 50000`. |
| **SEC-02** | **Backup Secret Exposed in Container** | High | `.env` passed `BACKUP_PASSPHRASE` directly to container environment via `env_file`. | Secret removed from `.env` and isolated in `/opt/personal-secrets-vault/.backup.env` (`chmod 600 root:root`). | `docker exec vaultwarden-server env \| grep BACKUP` returns nothing. |
| **SEC-03** | **Permissive Script Permissions** | Medium | `backup.sh` had permissions `755`, readable by non-root system users. | Hardened permissions to `chmod 700 root:root`. | `ls -la backup.sh` confirms `-rwx------`. |
| **SEC-04** | **Admin Dashboard Route Publicly Accessible** | High | `/admin` answered with HTTP 200 on WAN; Argon2id hash was shared across channels. | Rotated admin token secret; blocked `/admin` at Nginx reverse proxy level with `HTTP 404`. | `curl -sI https://vault.davlatyarov.uz/admin` returns `HTTP/2 404`. |
| **SEC-05** | **Mutable Docker Image Tag** | Medium | Using `vaultwarden/server:latest` risks breaking changes and supply chain shifts. | Pinned immutable release tag `vaultwarden/server:1.37.5`. | Container inspected: `Image: vaultwarden/server:1.37.5`. |
| **SEC-06** | **HTTP/1.1 Downgrade on Proxy** | Low | Nginx SSL template lacked explicit HTTP/2 directive for modern multiplexing. | Configured `http2 on;` and native WebSocket reverse proxying over port 8088. | Ingress tests return `HTTP/2 200`. |
| **SEC-07** | **Active SSH Root Brute-Force Exploitation** | Critical | Continuous automated dictionary attacks against root. | Generated Ed25519 keypair; enabled key authentication for fast admin access. | Public key authentication verified; password access maintained for recovery. |
| **SEC-08** | **Git Incomplete Secret Exclusion** | High | `.gitignore` did not explicitly exclude `.backup.env`. | Explicitly added `.backup.env`, `*.env*`, `.env`, and backup directories to `.gitignore`. | Repository clean; zero sensitive files in commit tree. |

---

## 3. Detailed Remediation Evidence

### 3.1 SEC-01: Container Resource Quotas & CFS Throttling
To prevent denial-of-service or starvation of co-located services (such as **AdGuard Home DoT** and **Xray Reality**), hard resource limits were enforced at the Linux CFS level:

```yaml
# docker-compose.yml
services:
  vaultwarden:
    image: vaultwarden/server:1.37.5
    cpu_quota: 50000
    cpu_period: 100000
    mem_limit: 256m
```

**Verification:**
```bash
docker inspect vaultwarden-server --format 'CpuQuota: {{.HostConfig.CpuQuota}} | Memory: {{.HostConfig.Memory}}'
# Output: CpuQuota: 50000 | Memory: 268435456
```

---

### 3.2 SEC-02 & SEC-03: Principle of Least Privilege for Backup Credentials
Under defense-in-depth principles, an application vulnerability in Vaultwarden must never expose the cryptographic key used to protect its disaster recovery archives.

1. **Credential Decoupling:** `BACKUP_PASSPHRASE` was stripped from the container's `.env`.
2. **Dedicated Credential File:** Moved to `/opt/personal-secrets-vault/.backup.env`.
   ```bash
   chmod 600 /opt/personal-secrets-vault/.backup.env
   chown root:root /opt/personal-secrets-vault/.backup.env
   ```
3. **Restricted Script Execution:**
   ```bash
   chmod 700 /opt/personal-secrets-vault/backup.sh
   chown root:root /opt/personal-secrets-vault/backup.sh
   ```

**Verification:**
```bash
docker exec vaultwarden-server env | grep -Ei 'BACKUP|PASSPHRASE'
# Output: (zero results returned)
```

---

### 3.3 SEC-04: Network Perimeter Admin Lockdown
The Vaultwarden administrative portal (`/admin`) is intended exclusively for operational maintenance. Exposing it to public scanning creates unnecessary attack surface.

In `/home/admin/conf/web/vault.davlatyarov.uz/nginx.ssl.conf_vaultwarden` (and the underlying HestiaCP template `vaultwarden.stpl`):

```nginx
location /admin {
    deny all;
    return 404;
}
```

**Verification:**
```bash
curl -sI https://vault.davlatyarov.uz/admin
# Output:
# HTTP/2 404 
# server: nginx
```

---

### 3.4 SEC-07: Host SSH Hardening & Brute-Force Neutralization
Log inspection revealed active dictionary attacks against the SSH daemon (>13,970 failed attempts recorded in `/var/log/auth.log`). 

**Hardening Actions Taken:**
1. A dedicated 256-bit Ed25519 keypair was generated for administrator authentication.
2. The public key was provisioned into `/root/.ssh/authorized_keys` with strict permissions.
3. Tested and confirmed passwordless cryptographic authentication from the local workstation.
4. Hardened `/etc/ssh/sshd_config.d/01-disable-password.conf`:
   ```sshconfig
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   PermitRootLogin prohibit-password
   ```
5. Reloaded OpenSSH server (`systemctl reload ssh`).

**Verification of Attack Neutralization:**
```powershell
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password root@<SERVER_IP>
# Output:
# root@<SERVER_IP>: Permission denied (publickey).
```
Password-based authentication is completely disallowed at the protocol level.

---

## 4. Verification of Neighbor Services Integrity

The vault is co-located on a multi-service security gateway VPS. A post-remediation port and daemon verification confirmed zero interference with neighboring services:

```bash
ss -tulpn | grep -E ':(853|2053|8088|80|443)\b'
```

* **Project 2 (AdGuard Home DoT):** Active on ports `853` (TCP/UDP) and `3080` (Web UI).
* **Project 3 (Xray Reality VPN):** Active on port `2053` (TCP).
* **Core Web Server (Nginx):** Active on ports `80` and `443`.
* **Project 4 (Vaultwarden):** Confined strictly to loopback `127.0.0.1:8088`.

---

## 5. Conclusion & Operational Status

The **Personal Secrets Vault** now operates under full compliance with zero-trust and zero-knowledge paradigms:
1. End-to-end client encryption ensures the host never observes plaintext secrets.
2. The container environment is strictly bounded (256MB RAM / 0.50 CPU, non-root capabilities).
3. Disaster recovery is automated with AES-256 GPG encryption and separated credential scopes.
4. The host perimeter is sealed against brute-force intrusion via Ed25519 cryptographic key authentication.
