# syntax=docker/dockerfile:1
# Dockerfile — omp-server-agent
#
# Multi-stage build, entirely self-contained on the build host:
#
#   Stage 1 (omp-builder)    — builds the omp-server from source using
#                              oven/bun:1; no pre-built image required
#   Stage 2 (tool-installer) — downloads all CLI tool binaries on
#                              ubuntu:24.04 (reliable curl/unzip/python3)
#   Stage 3 (final)          — fedora:latest base; dnf for system packages,
#                              app copied from stage 1, tools from stage 2
#
# Build context layout (assembled by manage.sh build):
#   ./Dockerfile
#   ./build-image.sh
#   ./src/                   ← pi-team source tree
#       package.json
#       bun.lock
#       tsconfig.json
#       packages/
#           server/
#           shared/
#           client/
#
# Usage (via manage.sh — normal path):
#   GCP_PROJECT=my-project ./manage.sh build
#
# Direct build:
#   docker buildx build -t omp-server-agent:latest --load .

# =============================================================================
# Stage 1 — omp-builder
# Compile the omp-server application from source.
# Mirrors the build stage in the upstream pi-team Dockerfile.
# =============================================================================
FROM oven/bun:1 AS omp-builder

WORKDIR /build

# Install dependencies first for layer-cache efficiency
COPY src/package.json src/bun.lock* ./
COPY src/packages/shared/package.json  packages/shared/
COPY src/packages/server/package.json  packages/server/
COPY src/packages/client/package.json  packages/client/
RUN bun install --frozen-lockfile

# Build server
COPY src/tsconfig.json .
COPY src/packages/ packages/
RUN bun build packages/server/src/main.ts \
      --outdir packages/server/dist \
      --target bun

# =============================================================================
# Stage 2 — tool-installer
# Download all CLI tools on Ubuntu 24.04.
# Binaries land in /tools; SDK dirs in /opt.
# =============================================================================
FROM ubuntu:24.04 AS tool-installer

ARG TARGETARCH
ARG TERRAFORM_VERSION=1.10.5
ARG PACKER_VERSION=1.11.2
ARG DOCKER_CLI_VERSION=27.5.1
ARG UV_VERSION=0.6.14
ARG AWSCLI_VERSION=2.24.17
ARG GCLOUD_VERSION=519.0.0
ARG NODE_VERSION=22.15.0

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install -y -qq \
        curl \
        unzip \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /tools

# --- Terraform ---
RUN set -eux \
    && curl -fsSL \
       "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" \
       -o /tmp/tf.zip \
    && unzip -q /tmp/tf.zip terraform -d /tools \
    && rm /tmp/tf.zip \
    && /tools/terraform version

# --- Packer ---
RUN set -eux \
    && curl -fsSL \
       "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_${TARGETARCH}.zip" \
       -o /tmp/packer.zip \
    && unzip -q /tmp/packer.zip packer -d /tools \
    && rm /tmp/packer.zip \
    && /tools/packer version

# --- Docker CLI (no daemon) ---
RUN set -eux \
    && case "${TARGETARCH}" in \
         amd64) darch="x86_64" ;; \
         arm64) darch="aarch64" ;; \
         *) echo "Unsupported TARGETARCH: ${TARGETARCH}" && exit 1 ;; \
       esac \
    && curl -fsSL \
       "https://download.docker.com/linux/static/stable/${darch}/docker-${DOCKER_CLI_VERSION}.tgz" \
       -o /tmp/docker.tgz \
    && tar -xz -f /tmp/docker.tgz --strip-components=1 -C /tools docker/docker \
    && rm /tmp/docker.tgz \
    && /tools/docker --version

# --- uv (statically linked) ---
RUN set -eux \
    && case "${TARGETARCH}" in \
         amd64) uarch="x86_64-unknown-linux-musl" ;; \
         arm64) uarch="aarch64-unknown-linux-musl" ;; \
         *) echo "Unsupported TARGETARCH: ${TARGETARCH}" && exit 1 ;; \
       esac \
    && mkdir /tmp/uv-extract \
    && curl -fsSL \
       "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uarch}.tar.gz" \
       -o /tmp/uv.tar.gz \
    && tar -xz -f /tmp/uv.tar.gz -C /tmp/uv-extract \
    && find /tmp/uv-extract -maxdepth 2 \( -name 'uv' -o -name 'uvx' \) -exec cp {} /tools/ \; \
    && rm -rf /tmp/uv.tar.gz /tmp/uv-extract \
    && /tools/uv --version

# --- AWS CLI v2 ---
RUN set -eux \
    && case "${TARGETARCH}" in \
         amd64) awsarch="x86_64" ;; \
         arm64) awsarch="aarch64" ;; \
         *) echo "Unsupported TARGETARCH: ${TARGETARCH}" && exit 1 ;; \
       esac \
    && curl -fsSL \
       "https://awscli.amazonaws.com/awscli-exe-linux-${awsarch}-${AWSCLI_VERSION}.zip" \
       -o /tmp/awscli.zip \
    && unzip -q /tmp/awscli.zip -d /tmp/awscli-src \
    && /tmp/awscli-src/aws/install --install-dir /opt/aws-cli --bin-dir /tools \
    && rm -rf /tmp/awscli.zip /tmp/awscli-src \
    && /tools/aws --version

# --- gcloud CLI ---
RUN set -eux \
    && case "${TARGETARCH}" in \
         amd64) gcparch="x86_64" ;; \
         arm64) gcparch="arm" ;; \
         *) echo "Unsupported TARGETARCH: ${TARGETARCH}" && exit 1 ;; \
       esac \
    && curl -fsSL \
       "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-${GCLOUD_VERSION}-linux-${gcparch}.tar.gz" \
       -o /tmp/gcloud.tar.gz \
    && tar -xz -f /tmp/gcloud.tar.gz -C /opt \
    && rm /tmp/gcloud.tar.gz \
    && /opt/google-cloud-sdk/install.sh \
       --quiet --usage-reporting=false --command-completion=false --path-update=false \
    && /opt/google-cloud-sdk/bin/gcloud --version

# --- Azure CLI ---
# Skipped in installer stage: pip venv built on Ubuntu can't be copied to Fedora
# (Python site-packages paths diverge). Installed via Microsoft's RPM repo in
# the final stage instead.

# --- Node.js + npm ---
RUN set -eux \
    && case "${TARGETARCH}" in \
         amd64) nodearch="x64" ;; \
         arm64) nodearch="arm64" ;; \
         *) echo "Unsupported TARGETARCH: ${TARGETARCH}" && exit 1 ;; \
       esac \
    && curl -fsSL \
       "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${nodearch}.tar.gz" \
       -o /tmp/node.tar.gz \
    && tar -xz -f /tmp/node.tar.gz -C /opt \
    && mv "/opt/node-v${NODE_VERSION}-linux-${nodearch}" /opt/nodejs \
    && rm /tmp/node.tar.gz \
    && /opt/nodejs/bin/node --version \
    && PATH="/opt/nodejs/bin:${PATH}" /opt/nodejs/bin/npm --version

# =============================================================================
# Stage 3 — final (Fedora)
# =============================================================================
FROM fedora:latest

ARG AGENT_USER=ubuntu
ARG AGENT_UID=1000
ARG AGENT_GID=1000
ARG DOCKER_GID=988

# System packages via dnf.
# Azure CLI: write the .repo file directly — avoids dnf config-manager whose
# --add-repo flag was removed in DNF5 (Fedora 41+).
RUN rpm --import https://packages.microsoft.com/keys/microsoft.asc \
    && printf '[azure-cli]\nname=Azure CLI\nbaseurl=https://packages.microsoft.com/yumrepos/azure-cli\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\n' \
       > /etc/yum.repos.d/azure-cli.repo \
    && dnf install -y \
           git \
           podman-remote \
           shadow-utils \
           ca-certificates \
           azure-cli \
    && dnf clean all

# --- omp-server application ---
WORKDIR /app
COPY --from=omp-builder /build/packages/server/dist/   ./dist/
COPY --from=omp-builder /build/node_modules/           ./node_modules/
COPY --from=omp-builder /build/packages/shared/        ./packages/shared/
COPY --from=omp-builder /build/package.json            ./

# bun runtime — copied directly from the builder image
COPY --from=omp-builder /usr/local/bin/bun /usr/local/bin/bun

# --- CLI tools from installer ---
COPY --from=tool-installer /tools/terraform   /usr/local/bin/terraform
COPY --from=tool-installer /tools/packer      /usr/local/bin/packer
COPY --from=tool-installer /tools/docker      /usr/local/bin/docker
COPY --from=tool-installer /tools/uv          /usr/local/bin/uv
COPY --from=tool-installer /tools/uvx         /usr/local/bin/uvx
# aws: symlink into /opt/aws-cli so the PyInstaller binary can find its dist/ sibling
COPY --from=tool-installer /opt/aws-cli          /opt/aws-cli
COPY --from=tool-installer /opt/google-cloud-sdk /opt/google-cloud-sdk
COPY --from=tool-installer /opt/nodejs           /opt/nodejs

ENV PATH="/opt/google-cloud-sdk/bin:/opt/nodejs/bin:${PATH}"
ENV OMP_SERVER_DATA_DIR=/data
ENV PI_CODING_AGENT_DIR=/data/agent

RUN ln -s /usr/bin/podman-remote /usr/local/bin/podman \
    && ln -sf /opt/aws-cli/v2/current/bin/aws /usr/local/bin/aws

# Agent user, docker group, ownership
RUN groupadd -g "${AGENT_GID}" "${AGENT_USER}" 2>/dev/null || true \
    && useradd -m -u "${AGENT_UID}" -g "${AGENT_GID}" -s /bin/bash "${AGENT_USER}" \
    && groupadd -g "${DOCKER_GID}" docker 2>/dev/null || true \
    && usermod -aG docker "${AGENT_USER}" \
    && mkdir -p /data /app/.clients \
    && chown -R "${AGENT_UID}:${AGENT_GID}" /app /data

# Smoke-test all tools before dropping privileges
RUN bun --version \
    && terraform version \
    && packer version \
    && docker --version \
    && uv --version \
    && aws --version \
    && gcloud version --format=none \
    && az --version \
    && git --version \
    && podman --version \
    && node --version \
    && npm --version

EXPOSE 7077

USER ${AGENT_USER}
ENTRYPOINT ["bun", "run", "dist/main.js"]
CMD ["start"]
