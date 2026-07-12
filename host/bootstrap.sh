#!/usr/bin/env bash
#
# One-time host bootstrap for the new VPS (Debian 13 "Trixie", 1 vCPU / 2 GB
# RAM). Run as root (or via sudo) on a fresh install, once, before deploying
# any docker-compose stacks.
#
# This is written to be readable and re-run-safe (idempotent-ish) rather than
# fully unattended — read through it before running. It intentionally does
# NOT touch SSH password auth / root login automatically, since locking
# yourself out of a fresh VPS is a real risk; that step is called out
# separately with a pause.
#
# Usage:
#   scp bootstrap.sh root@NEW_VPS_IP:/root/
#   ssh root@NEW_VPS_IP
#   bash /root/bootstrap.sh

set -euo pipefail

echo "== 1. System update =="
apt-get update
apt-get -y upgrade

echo "== 2. Create non-root sudo user (skip if already present) =="
read -r -p "Username for the admin account [benoit]: " NEWUSER
NEWUSER="${NEWUSER:-benoit}"
if ! id "$NEWUSER" &>/dev/null; then
    adduser --gecos "" "$NEWUSER"
    usermod -aG sudo "$NEWUSER"
    mkdir -p "/home/$NEWUSER/.ssh"
    if [ -f /root/.ssh/authorized_keys ]; then
        cp /root/.ssh/authorized_keys "/home/$NEWUSER/.ssh/authorized_keys"
    else
        echo "  !! No /root/.ssh/authorized_keys found — add your public key to"
        echo "     /home/$NEWUSER/.ssh/authorized_keys manually before disabling"
        echo "     password auth, or you will be locked out."
    fi
    chown -R "$NEWUSER:$NEWUSER" "/home/$NEWUSER/.ssh"
    chmod 700 "/home/$NEWUSER/.ssh"
    chmod 600 "/home/$NEWUSER/.ssh/authorized_keys" 2>/dev/null || true
else
    echo "  user $NEWUSER already exists, skipping creation"
fi

echo "== 3. Swap (2G) =="
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    # Small box: prefer keeping things in RAM, swap only under real pressure.
    sysctl -w vm.swappiness=10
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
else
    echo "  /swapfile already exists, skipping"
fi

echo "== 4. Firewall (ufw): allow SSH/HTTP/HTTPS only =="
apt-get install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "== 5. Unattended security upgrades =="
apt-get install -y unattended-upgrades apt-listchanges
dpkg-reconfigure -f noninteractive unattended-upgrades

# Auto-reboot when a patch requires it (kernel updates drop
# /var/run/reboot-required). Done in a low-traffic window rather than left
# for you to notice manually. Only fires when a reboot is actually pending —
# most nights it's a no-op. NOTE: this only covers the *host* (kernel, glibc,
# openssl, Docker daemon, SSH). Your sites run in containers with their own
# baked-in libraries — those are patched by pulling new images, NOT by this.
# See "Keeping things patched" in infra/README.md.
cat > /etc/apt/apt.conf.d/51unattended-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

# needrestart: after a shared-library patch (openssl, glibc, ...), the fix
# isn't live until every process that loaded the old library restarts — which
# usually needs a service restart, not a full reboot. needrestart detects
# those and, with the config below, restarts them automatically after apt
# transactions. (It reasons about *host* services only — containers are
# unaffected, same caveat as above.)
apt-get install -y needrestart

# Default mode is interactive (prompts for which services to restart), which
# stalls unattended-upgrades waiting for input that never comes. Set 'a'
# (automatic) so host services are restarted without prompting. Safe here:
# the services this touches are host-level (sshd, etc.), not the Dockerized
# sites — those keep running untouched.
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/50-autorestart.conf <<'EOF'
# Restart outdated services automatically, no prompt. See bootstrap.sh step 5.
$nrconf{restart} = 'a';
EOF

echo "== 6. Install Docker Engine (official repo, not Debian's package) =="
if ! command -v docker &>/dev/null; then
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    ARCH="$(dpkg --print-architecture)"
    CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    echo \
        "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    usermod -aG docker "$NEWUSER"
else
    echo "  docker already installed, skipping"
fi

echo "== 7. Docker daemon hardening =="
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
systemctl restart docker

echo "== 8. Create shared docker network + caddy_logs volume =="
docker network inspect web >/dev/null 2>&1 || docker network create web
docker volume inspect caddy_logs >/dev/null 2>&1 || docker volume create caddy_logs

cat <<'EOF'

== Bootstrap done. Remaining MANUAL steps (deliberately not automated): ==

1. Log in as the new user in a SEPARATE terminal and confirm sudo + SSH key
   login work BEFORE touching sshd_config:
     ssh <user>@<new-vps-ip>
     sudo whoami

2. Only once that's confirmed, harden SSH:
     sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
     sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
     sudo systemctl restart ssh
   Keep your current session open until you've verified a fresh connection
   still works — do not close it first.

3. Log out and back in (or `newgrp docker`) to pick up docker group membership.

4. Deploy Caddy, then each site — see infra/README.md for the full order.

EOF
