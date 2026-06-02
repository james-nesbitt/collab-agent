#!/usr/bin/env bash
# startup-script.sh — First-boot VM provisioning via GCP startup-script mechanism.
#
# This script is idempotent: it checks for a sentinel file and exits early if
# provisioning has already been done. Docker CE and Podman are installed on the
# host VM; the omp-server compose directory is laid out. The container is NOT
# started here — that happens in setup-omp-server.sh after PKI init.
set -euo pipefail

SENTINEL="/opt/omp-provisioned"
OMP_DIR="/opt/omp-server"
AGENT_USER="ubuntu"
AGENT_UID="1000"
AGENT_GID="1000"
AGENT_MOUNT_DIR="/home/${AGENT_USER}/mount"

log() { echo "[startup-script] $*"; }

if [[ -f "${SENTINEL}" ]]; then
    log "Sentinel found — already provisioned. Exiting."
    exit 0
fi

log "Starting first-boot provisioning…"

# ---------------------------------------------------------------------------
# 1. System update
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

# The GCP Ubuntu 24.04 image ships with an 'ubuntu' user at UID/GID 1000.
# We use it directly — no user creation needed.
log "Using existing user ${AGENT_USER} (uid=${AGENT_UID}, gid=${AGENT_GID})"

# ---------------------------------------------------------------------------
# 3. Install Docker CE (official repo)
# ---------------------------------------------------------------------------
log "Installing Docker CE…"
apt-get install -y -qq ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

systemctl enable docker
systemctl start docker

# Grant the agent user access to the Docker socket via the docker group.
usermod -aG docker "${AGENT_USER}"

log "Docker installed: $(docker --version)"
log "Docker GID: $(getent group docker | cut -d: -f3)"

# ---------------------------------------------------------------------------
# 4. Install Podman (host daemon, user socket)
#
# We use the per-user Podman socket (/run/user/1000/podman/podman.sock) rather
# than the rootful socket so the agent user owns the socket directly — no group
# permission gymnastics required. Lingering ensures the user manager and its
# socket start at boot without a login session.
# ---------------------------------------------------------------------------
log "Installing Podman…"
apt-get install -y -qq podman

# Enable lingering so the user manager survives beyond login sessions and
# starts automatically at boot.
loginctl enable-linger "${AGENT_USER}"

# Start the user manager now (linger triggers it on next boot; we need it now).
systemctl start "user@${AGENT_UID}.service"

# Give the user manager a moment to initialize its runtime directory.
sleep 2

# Enable and start the user Podman socket.
XDG_RUNTIME_DIR="/run/user/${AGENT_UID}" \
    runuser -u "${AGENT_USER}" -- \
    systemctl --user enable --now podman.socket

log "Podman installed: $(podman --version)"
log "Podman socket: /run/user/${AGENT_UID}/podman/podman.sock"

# ---------------------------------------------------------------------------
# 5. Create omp-server directory, agent mount dir, and compose file
# ---------------------------------------------------------------------------
log "Creating ${OMP_DIR} and ${AGENT_MOUNT_DIR}…"
mkdir -p "${OMP_DIR}"

# Shared filespace: the same absolute path must exist on the host and be
# bind-mounted at that identical path inside the container. docker/podman
# -v flags using this path resolve correctly on the host daemon.
mkdir -p "${AGENT_MOUNT_DIR}"
chown "${AGENT_UID}:${AGENT_GID}" "${AGENT_MOUNT_DIR}"

# docker-compose.yml — image reference is populated by setup-omp-server.sh
# via the .env file; the compose file uses variable substitution.
#
# Note: DOCKER_GID is the GID of the docker group on this host. Docker CE on
# Ubuntu 24.04 consistently assigns GID 999; captured here for the compose
# group_add so the container process can reach the docker socket.
DOCKER_GID=$(getent group docker | cut -d: -f3)

cat > "${OMP_DIR}/docker-compose.yml" << EOF
services:
  omp-server:
    image: \${IMAGE_REPO}:\${IMAGE_TAG}
    container_name: omp-server
    restart: unless-stopped
    privileged: true
    user: "${AGENT_UID}:${AGENT_GID}"
    group_add:
      - "${DOCKER_GID}"
    ports:
      - "7077:7077"
    volumes:
      - omp-data:/data
      # Docker socket — agents talk to the host Docker daemon
      - /var/run/docker.sock:/var/run/docker.sock
      # Podman user socket — owned by ${AGENT_USER}, no extra group needed
      - /run/user/${AGENT_UID}/podman/podman.sock:/run/user/${AGENT_UID}/podman/podman.sock
      # Shared filespace — identical absolute path on host and container
      - ${AGENT_MOUNT_DIR}:${AGENT_MOUNT_DIR}
    environment:
      OMP_SERVER_DATA_DIR: /data
      OMP_SERVER_PKI_DIR: /data/pki
      OMP_SERVER_PORT: "7077"
      OMP_SERVER_URL: \${OMP_SERVER_URL}
      OMP_SERVER_LOG_LEVEL: \${OMP_SERVER_LOG_LEVEL:-info}
      DOCKER_HOST: unix:///var/run/docker.sock
      CONTAINER_HOST: unix:///run/user/${AGENT_UID}/podman/podman.sock
      AGENT_MOUNT_DIR: ${AGENT_MOUNT_DIR}
    healthcheck:
      test: ["CMD", "bun", "-e",
        "const r = await fetch('https://localhost:7077/healthz', {tls:{rejectUnauthorized:false}}); if(!r.ok) process.exit(1)"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s

volumes:
  omp-data:
EOF

# .env stub — populated by setup-omp-server.sh
cat > "${OMP_DIR}/.env" << EOF
# Populated by setup-omp-server.sh — do not hand-edit while container is running.
IMAGE_REPO=registry.ci.mirantis.com/jnesbitt/omp-server
IMAGE_TAG=latest
OMP_SERVER_URL=
AGENT_MOUNT_DIR=${AGENT_MOUNT_DIR}
EOF

chown -R "${AGENT_UID}:${AGENT_GID}" "${OMP_DIR}"

# ---------------------------------------------------------------------------
# 6. Write sentinel
# ---------------------------------------------------------------------------
touch "${SENTINEL}"
log "Sentinel written to ${SENTINEL}."
log "First-boot provisioning complete."
log "SSH in and run setup-omp-server.sh to start omp-server."
