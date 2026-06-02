# docker-compose.yml.tpl — Reference template for the omp-server compose file.
#
# This file is embedded in startup-script.sh and written to /opt/omp-server/
# on the GCP instance. It is also kept here as a standalone reference for
# local modification. Variables are sourced from /opt/omp-server/.env.
#
# To update the running instance after editing this file:
#   scp docker-compose.yml.tpl <INSTANCE>:/opt/omp-server/docker-compose.yml
#   ./manage.sh ssh -- sudo docker compose -f /opt/omp-server/docker-compose.yml up -d

services:
  omp-server:
    image: ${IMAGE_REPO}:${IMAGE_TAG}
    container_name: omp-server
    restart: unless-stopped
    ports:
      - "7077:7077"
    volumes:
      - omp-data:/data
    environment:
      OMP_SERVER_DATA_DIR: /data
      OMP_SERVER_PKI_DIR: /data/pki
      OMP_SERVER_PORT: "7077"
      OMP_SERVER_URL: ${OMP_SERVER_URL}
      OMP_SERVER_LOG_LEVEL: ${OMP_SERVER_LOG_LEVEL:-info}
    healthcheck:
      test: ["CMD", "bun", "-e",
        "const r = await fetch('https://localhost:7077/healthz', {tls:{rejectUnauthorized:false}}); if(!r.ok) process.exit(1)"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s

volumes:
  omp-data:
