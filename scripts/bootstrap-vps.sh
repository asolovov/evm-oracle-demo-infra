#!/usr/bin/env bash
# bootstrap-vps.sh — provision a blank Ubuntu 24.04 VPS for the EVM Oracle
# Demo stack.
#
# Run as root over SSH on a fresh box:
#     scp scripts/bootstrap-vps.sh root@<vps>:/root/
#     ssh root@<vps> 'bash /root/bootstrap-vps.sh --ssh-pubkey "$(cat ~/.ssh/id_ed25519.pub)"'
#
# Idempotent: re-running the script is safe, every step is guarded.

set -euo pipefail

usage() {
    cat <<EOF
Usage: bootstrap-vps.sh --ssh-pubkey <key> [--deploy-user <name>] [--secrets-dir <path>]

Provisions a blank Ubuntu 24.04 box: installs docker, ufw, fail2ban,
unattended-upgrades; creates an unprivileged deploy user with sudo + SSH-key
login; locks down SSH (disables password + root login); creates the
/etc/lighthouse/{secrets,backup}/ tree.

Required:
  --ssh-pubkey <key>     OpenSSH public key string (single line, includes
                         the type prefix). Authorises the deploy user.

Optional:
  --deploy-user <name>   Deploy user to create. Default: deploy.
  --secrets-dir <path>   Where reporter keys + .env live on the host.
                         Default: /etc/lighthouse.
  --help                 Print this message.

Forbidden actions (per workflow rule): this script does NOT push code,
register a domain, configure DNS, or write to a remote secrets store.
EOF
}

DEPLOY_USER="deploy"
SECRETS_DIR="/etc/lighthouse"
SSH_PUBKEY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-pubkey)
            SSH_PUBKEY="$2"
            shift 2
            ;;
        --deploy-user)
            DEPLOY_USER="$2"
            shift 2
            ;;
        --secrets-dir)
            SECRETS_DIR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "${SSH_PUBKEY}" ]]; then
    echo "--ssh-pubkey is required" >&2
    usage
    exit 1
fi

if [[ $(id -u) -ne 0 ]]; then
    echo "this script must run as root (use sudo or root SSH login)" >&2
    exit 1
fi

log() { echo "[bootstrap] $*"; }

# ---------------------------------------------------------------------------
# OS updates + base packages
# ---------------------------------------------------------------------------
log "apt update + upgrade"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -qq -y
apt-get install -qq -y \
    ca-certificates curl gnupg lsb-release \
    ufw fail2ban unattended-upgrades \
    git make jq

# ---------------------------------------------------------------------------
# Docker (official repo)
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    log "installing docker"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    # shellcheck source=/dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -qq -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
else
    log "docker already installed, skipping"
fi

# ---------------------------------------------------------------------------
# Deploy user
# ---------------------------------------------------------------------------
if ! id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
    log "creating deploy user: ${DEPLOY_USER}"
    useradd -m -s /bin/bash -G sudo,docker "${DEPLOY_USER}"
    # Passwordless sudo for the deploy user (still gated on SSH-key login).
    echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/90-${DEPLOY_USER}"
    chmod 0440 "/etc/sudoers.d/90-${DEPLOY_USER}"
else
    log "deploy user ${DEPLOY_USER} already exists, ensuring group membership"
    usermod -aG docker,sudo "${DEPLOY_USER}"
fi

DEPLOY_HOME=$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)
install -d -m 0700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${DEPLOY_HOME}/.ssh"
AUTH_KEYS="${DEPLOY_HOME}/.ssh/authorized_keys"
if ! grep -qF -- "${SSH_PUBKEY}" "${AUTH_KEYS}" 2>/dev/null; then
    log "adding SSH public key to ${AUTH_KEYS}"
    echo "${SSH_PUBKEY}" >> "${AUTH_KEYS}"
fi
chown "${DEPLOY_USER}:${DEPLOY_USER}" "${AUTH_KEYS}"
chmod 0600 "${AUTH_KEYS}"

# ---------------------------------------------------------------------------
# /etc/lighthouse tree
# ---------------------------------------------------------------------------
log "creating ${SECRETS_DIR}/{secrets,backup}/"
install -d -m 0700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${SECRETS_DIR}"
install -d -m 0700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${SECRETS_DIR}/secrets"
install -d -m 0700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${SECRETS_DIR}/backup"

# ---------------------------------------------------------------------------
# Firewall (ufw)
# ---------------------------------------------------------------------------
log "configuring ufw"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# ---------------------------------------------------------------------------
# fail2ban
# ---------------------------------------------------------------------------
log "enabling fail2ban (default sshd jail)"
systemctl enable --now fail2ban

# ---------------------------------------------------------------------------
# unattended-upgrades
# ---------------------------------------------------------------------------
log "enabling unattended security upgrades"
dpkg-reconfigure --priority=low --frontend=noninteractive unattended-upgrades

# ---------------------------------------------------------------------------
# SSH hardening
# ---------------------------------------------------------------------------
log "hardening sshd_config (disable root + password login)"
SSHD_CONFIG=/etc/ssh/sshd_config
cp "${SSHD_CONFIG}" "${SSHD_CONFIG}.bootstrap.bak"
sed -i \
    -e 's/^#*PermitRootLogin.*/PermitRootLogin no/' \
    -e 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' \
    -e 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' \
    -e 's/^#*UsePAM.*/UsePAM yes/' \
    "${SSHD_CONFIG}"

# Sanity-check the new config before bouncing sshd, else we lock ourselves out.
sshd -t
systemctl reload ssh

log "bootstrap complete. Next steps:"
log "  1. ssh ${DEPLOY_USER}@<vps>"
log "  2. git clone --recursive git@github.com:asolovov/evm-oracle-demo-infra.git /opt/lighthouse"
log "  3. cp /opt/lighthouse/docker/env.example ${SECRETS_DIR}/.env  # then edit"
log "  4. place reporter1.key reporter2.key reporter3.key in ${SECRETS_DIR}/secrets/ with 0400"
log "  5. /opt/lighthouse/scripts/deploy.sh"
