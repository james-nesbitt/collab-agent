# syntax=docker/dockerfile:1
# Dockerfile — omp-server with agent tooling.
#
# Builds a custom image on top of the omp-server base that adds:
#   Terraform, Packer, AWS CLI v2, gcloud CLI, Azure CLI,
#   Docker CLI, podman-remote, git, uv, Node.js + npm
#
# Daemon model:
#   Docker and Podman daemons run on the HOST VM (see startup-script.sh).
#   This image contains only CLI clients. The container reaches the host
#   daemons via sockets mounted at runtime:
#     /var/run/docker.sock    → DOCKER_HOST
#     /run/podman/podman.sock → CONTAINER_HOST
#
# Build (see also build-image.sh):
#   docker buildx build \
#     --build-arg OMP_BASE_TAG=latest \
#     -t ghcr.io/OWNER/omp-server-agent:latest \
#     --load .
#
# All tool versions are ARGs — override at build time without editing this file:
#   --build-arg TERRAFORM_VERSION=1.11.0

ARG OMP_BASE_REPO=ghcr.io/OWNER/omp-server
ARG OMP_BASE_TAG=latest

# =============================================================================
# Stage 1 — installer
# Downloads and unpacks every tool into /tools (binaries) and /opt (SDK dirs).
# Uses Ubuntu 24.04 so we have a consistent apt/curl/unzip regardless of what
# the omp-server base image ships.
# =============================================================================
FROM ubuntu:24.04 AS installer

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

# Shared destination dirs
RUN mkdir -p /tools /opt

# ---------------------------------------------------------------------------
# Terraform — single static binary
# ---------------------------------------------------------------------------
RUN set -eux \
    && curl -fsSL \
       "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" \
       -o /tmp/tf.zip \
    && unzip -q /tmp/tf.zip terraform -d /tools \
    && rm /tmp/tf.zip \
    && /tools/terraform version

# ---------------------------------------------------------------------------
# Packer — single static binary
# ---------------------------------------------------------------------------
RUN set -eux \
    && curl -fsSL \
       "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_${TARGETARCH}.zip" \
       -o /tmp/packer.zip \
    && unzip -q /tmp/packer.zip packer -d /tools \
    && rm /tmp/packer.zip \
    && /tools/packer version

# ---------------------------------------------------------------------------
# Docker CLI — static binary (no daemon)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# uv — statically linked (musl), works on any Linux libc
# ---------------------------------------------------------------------------
RUN set -eux \
    && case "${TARGETARCH}" in \
         amd64) uarch="x86_64-unknown-linux-musl" ;; \
         arm64) uarch="aarch64-unknown-linux-musl" ;; \
         *) echo "Unsupported TARGETARCH: ${TARGETARCH}" && exit 1 ;; \
       esac \
    && curl -fsSL \
       "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uarch}.tar.gz" \
       -o /tmp/uv.tar.gz \
    && mkdir /tmp/uv-extract \
    && tar -xz -f /tmp/uv.tar.gz -C /tmp/uv-extract \
    && find /tmp/uv-extract -maxdepth 2 \( -name 'uv' -o -name 'uvx' \) \
       -exec cp {} /tools/ \; \
    && rm -rf /tmp/uv.tar.gz /tmp/uv-extract \
    && /tools/uv --version

# ---------------------------------------------------------------------------
# AWS CLI v2 — self-contained bundled installer
# ---------------------------------------------------------------------------
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
    && /tmp/awscli-src/aws/install \
       --install-dir /opt/aws-cli \
       --bin-dir /tools \
    && rm -rf /tmp/awscli.zip /tmp/awscli-src \
    && /tools/aws --version

# ---------------------------------------------------------------------------
# gcloud CLI — bundled SDK tarball with its own Python runtime
# ---------------------------------------------------------------------------
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
       --quiet \
       --usage-reporting=false \
       --command-completion=false \
       --path-update=false \
    && /opt/google-cloud-sdk/bin/gcloud --version

# ---------------------------------------------------------------------------
# Azure CLI — pip, isolated venv (brings its own Python environment)
# ---------------------------------------------------------------------------
RUN python3 -m venv /opt/azure-cli \
    && /opt/azure-cli/bin/pip install --quiet --upgrade pip \
    && /opt/azure-cli/bin/pip install --quiet azure-cli \
    && /opt/azure-cli/bin/az --version

# ---------------------------------------------------------------------------
# Node.js + npm — official binary tarball
# ---------------------------------------------------------------------------
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
    && /opt/nodejs/bin/npm --version

# =============================================================================
# Stage 2 — final image
#
# Assumes a Debian/glibc-based omp-server image (the oven/bun official image
# uses Debian Bookworm, which satisfies this requirement). Tools that are
# statically linked (terraform, packer, uv) work on any Linux base.
# =============================================================================
# Stage 2 — final image
#
# Assumes a Debian/glibc-based omp-server image (the oven/bun official image
# uses Debian Bookworm, which satisfies this requirement). Tools that are
# statically linked (terraform, packer, uv) work on any Linux base.
#
# Runs as uid=1000 (jnesbitt) matching the local workstation so file ownership
# is consistent across host, container, and any spawned containers.
# =============================================================================
FROM ${OMP_BASE_REPO}:${OMP_BASE_TAG}

# UID/GID must match the agent user on the host VM (jnesbitt, 1000:1000).
# DOCKER_GID must match the docker group GID on the host; Docker CE on
# Ubuntu 24.04 consistently assigns GID 999.
ARG AGENT_USER=ubuntu
ARG AGENT_UID=1000
ARG AGENT_GID=1000
ARG DOCKER_GID=999

ENV DEBIAN_FRONTEND=noninteractive

# git: source control for agent tasks
# podman-remote: Podman CLI client only; talks to host daemon via CONTAINER_HOST
#   (the host daemon is installed by startup-script.sh — no daemon runs here)
# ca-certificates: ensure TLS trust for cloud API calls
RUN apt-get update -qq && apt-get install -y -qq \
        git \
        podman-remote \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# --- Static / self-contained binaries ---
COPY --from=installer /tools/terraform      /usr/local/bin/terraform
COPY --from=installer /tools/packer         /usr/local/bin/packer
COPY --from=installer /tools/docker         /usr/local/bin/docker
COPY --from=installer /tools/uv             /usr/local/bin/uv
COPY --from=installer /tools/uvx            /usr/local/bin/uvx
COPY --from=installer /tools/aws            /usr/local/bin/aws

# --- SDK / runtime directories ---
COPY --from=installer /opt/aws-cli          /opt/aws-cli
COPY --from=installer /opt/google-cloud-sdk /opt/google-cloud-sdk
COPY --from=installer /opt/azure-cli        /opt/azure-cli
COPY --from=installer /opt/nodejs           /opt/nodejs

# Wire all SDK and runtime paths
ENV PATH="/opt/google-cloud-sdk/bin:/opt/nodejs/bin:/opt/azure-cli/bin:${PATH}"

# az lives in the venv bin dir; expose it at the standard location
RUN ln -s /opt/azure-cli/bin/az /usr/local/bin/az

# podman-remote installs as 'podman-remote'; alias to 'podman' so agent code
# can call 'podman' without knowing about the remote variant
RUN ln -s /usr/bin/podman-remote /usr/local/bin/podman

# Create the agent user with matching uid/gid.
# Create a 'docker' group with the host's docker GID so the process can reach
# /var/run/docker.sock (compose also passes group_add as a belt-and-suspenders).
RUN groupadd -g "${AGENT_GID}" "${AGENT_USER}" 2>/dev/null || true \
    && useradd -m -u "${AGENT_UID}" -g "${AGENT_GID}" -s /bin/bash "${AGENT_USER}" \
    && groupadd -g "${DOCKER_GID}" docker 2>/dev/null || true \
    && usermod -aG docker "${AGENT_USER}" \
    # /app is the omp-server application directory (client bundles written here).
    # /data is the runtime data volume mount point.
    # Both must be writable by the agent user; /data ownership is also fixed at
    # first run by setup-omp-server.sh for the named volume case.
    && mkdir -p /app /data \
    && chown -R "${AGENT_UID}:${AGENT_GID}" /app /data \
    && chmod 755 /app /data

# Smoke-test every tool as root before dropping privileges — build fails here
# if any binary is broken or missing
RUN terraform version \
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

USER ${AGENT_USER}