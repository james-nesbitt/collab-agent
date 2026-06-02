# syntax=docker/dockerfile:1
# Dockerfile — omp-server-agent
#
# Multi-stage build:
#   Stage 1 (omp-app)       — extracts the compiled omp-server application
#                             from the upstream image; no code built here
#   Stage 2 (tool-installer)— downloads all CLI tool binaries on ubuntu:24.04
#                             which has reliable curl/unzip availability
#   Stage 3 (final)         — Fedora base; dnf for system packages and repos,
#                             tooling copied from stage 2, app from stage 1
#
# The upstream omp-server image is transferred to the build host by
# manage.sh before the build runs (docker save | docker load over SSH),
# so no registry credentials are needed on the remote machine.
#
# Build (via manage.sh — this is the normal path):
#   GCP_PROJECT=my-project ./manage.sh build
#
# Direct build (overriding base):
#   docker buildx build \
#     --build-arg OMP_BASE_REPO=my-repo/omp-server \
#     --build-arg OMP_BASE_TAG=latest \
#     -t omp-server-agent:latest --load .

ARG OMP_BASE_REPO=omp-server
ARG OMP_BASE_TAG=local

# =============================================================================
# Stage 1 — omp-app
# Extract the compiled server application from the upstream image.
# Nothing is built here; this stage exists solely as a copy source.
# =============================================================================
FROM ${OMP_BASE_REPO}:${OMP_BASE_TAG} AS omp-app

# =============================================================================
# Stage 2 — tool-installer
# Download all CLI tools on Ubuntu 24.04 (reliable curl/unzip/python3).
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

# --- uv (statically linked musl binary) ---
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

# --- Azure CLI (pip venv) ---
RUN python3 -m venv /opt/azure-cli \
    && /opt/azure-cli/bin/pip install --quiet --upgrade pip \
    && /opt/azure-cli/bin/pip install --quiet azure-cli \
    && /opt/azure-cli/bin/az --version

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
    && /opt/nodejs/bin/npm --version

# =============================================================================
# Stage 3 — final (Fedora)
# dnf provides git, podman-remote, and a consistent RPM ecosystem.
# Tools are copied from the installer stage; the omp-server app from stage 1.
# =============================================================================
FROM fedora:latest

ARG AGENT_USER=ubuntu
ARG AGENT_UID=1000
ARG AGENT_GID=1000
ARG DOCKER_GID=988

# System packages via dnf:
#   git          — source control for agent tasks
#   podman-remote— Podman CLI client; talks to host daemon via CONTAINER_HOST
#   shadow-utils — useradd/groupadd
RUN dnf install -y \
        git \
        podman-remote \
        shadow-utils \
        ca-certificates \
    && dnf clean all

# --- Static / self-contained binaries from installer ---
COPY --from=tool-installer /tools/terraform   /usr/local/bin/terraform
COPY --from=tool-installer /tools/packer      /usr/local/bin/packer
COPY --from=tool-installer /tools/docker      /usr/local/bin/docker
COPY --from=tool-installer /tools/uv          /usr/local/bin/uv
COPY --from=tool-installer /tools/uvx         /usr/local/bin/uvx
COPY --from=tool-installer /tools/aws         /usr/local/bin/aws

# --- SDK / runtime directories from installer ---
COPY --from=tool-installer /opt/aws-cli          /opt/aws-cli
COPY --from=tool-installer /opt/google-cloud-sdk /opt/google-cloud-sdk
COPY --from=tool-installer /opt/azure-cli        /opt/azure-cli
COPY --from=tool-installer /opt/nodejs           /opt/nodejs

# --- omp-server application from upstream image ---
COPY --from=omp-app /app /app

ENV PATH="/opt/google-cloud-sdk/bin:/opt/nodejs/bin:/opt/azure-cli/bin:${PATH}"

RUN ln -s /opt/azure-cli/bin/az /usr/local/bin/az \
    && ln -s /usr/bin/podman-remote /usr/local/bin/podman

# Create agent user, docker group, fix ownership
RUN groupadd -g "${AGENT_GID}" "${AGENT_USER}" 2>/dev/null || true \
    && useradd -m -u "${AGENT_UID}" -g "${AGENT_GID}" -s /bin/bash "${AGENT_USER}" \
    && groupadd -g "${DOCKER_GID}" docker 2>/dev/null || true \
    && usermod -aG docker "${AGENT_USER}" \
    && chown -R "${AGENT_UID}:${AGENT_GID}" /app \
    && mkdir -p /data && chown "${AGENT_UID}:${AGENT_GID}" /data

# Smoke-test all tools before dropping privileges
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
