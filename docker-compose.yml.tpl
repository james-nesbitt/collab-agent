# docker-compose.yml.tpl — Reference template for the omp-server compose file.
#
# This file is embedded verbatim in startup-script.sh and written to
# /opt/omp-server/docker-compose.yml on the GCP instance at first boot.
# It is also kept here as a standalone reference for local modification.
# Variables are sourced from /opt/omp-server/.env.
#
# Daemon model:
#   Docker daemon  — runs on the host VM; socket mounted at /var/run/docker.sock
#   Podman daemon  — runs on the host VM; socket mounted at /run/podman/podman.sock
#   The container holds only CLI clients; no daemons run inside it.
#
# Shared filespace:
#   AGENT_MOUNT_DIR is bind-mounted at the same absolute path on both the host
#   and the container. When agents run `docker run -v $AGENT_MOUNT_DIR/foo:/bar`
#   the host Docker daemon resolves the path on the host filesystem, which is
#   the same directory the agent wrote into inside the container. The path must
#   be identical on both sides — never use ~ here.
#
# To propagate edits to the running instance:
#   gcloud compute scp docker-compose.yml.tpl \
#     <INSTANCE>:/opt/omp-server/docker-compose.yml --zone=europe-west1-b
#   ./manage.sh ssh -- sudo docker compose -f /opt/omp-server/docker-compose.yml up -d

services:
  omp-server:
    image: ${IMAGE_REPO}:${IMAGE_TAG}
    container_name: omp-server
    restart: unless-stopped
    privileged: true
    ports:
      - "7077:7077"
    volumes:
      - omp-data:/data
      # Docker socket — agents talk to the host Docker daemon
      - /var/run/docker.sock:/var/run/docker.sock
      # Podman socket — agents talk to the host Podman daemon (rootful)
      - /run/podman/podman.sock:/run/podman/podman.sock
      # Shared filespace — same absolute path on host and container.
      # Both sides must be identical so that docker/podman -v flags written
      # by agents resolve correctly against the host daemon.
      - ${AGENT_MOUNT_DIR}:${AGENT_MOUNT_DIR}
    environment:
      OMP_SERVER_DATA_DIR: /data
      OMP_SERVER_PKI_DIR: /data/pki
      OMP_SERVER_PORT: "7077"
      OMP_SERVER_URL: ${OMP_SERVER_URL}
      OMP_SERVER_LOG_LEVEL: ${OMP_SERVER_LOG_LEVEL:-info}
      # Point CLI tools at the host daemons via the mounted sockets
      DOCKER_HOST: unix:///var/run/docker.sock
      CONTAINER_HOST: unix:///run/podman/podman.sock
      # Expose the shared mount path so agent code can reference it without
      # hardcoding the directory
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
