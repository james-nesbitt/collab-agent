#!/usr/bin/env bash
# build-image.sh — Build (and optionally push) the omp-server-agent image.
#
# Usage:
#   ./build-image.sh [--push] [--platform PLATFORM] [--tag TAG]
#
# Options:
#   --push               Push after a successful build (default: local load only)
#   --platform PLATFORM  Target platform(s), comma-separated
#                        (default: linux/amd64)
#                        Multi-platform example: linux/amd64,linux/arm64
#                        Note: multi-platform requires --push (no local load)
#   --tag TAG            Output image tag, e.g. v1.2.3 (default: latest)
#   --base-repo REPO     omp-server base image repo
#                        (default: ghcr.io/OWNER/omp-server)
#   --base-tag TAG       omp-server base image tag (default: latest)
#   --output-repo REPO   Output image repo
#                        (default: ghcr.io/OWNER/omp-server-agent)
#
# Tool version overrides (passed through to docker buildx build --build-arg):
#   TERRAFORM_VERSION, PACKER_VERSION, DOCKER_CLI_VERSION, UV_VERSION,
#   AWSCLI_VERSION, GCLOUD_VERSION, NODE_VERSION
#
# Examples:
#   # Build locally, load into docker, default versions
#   ./build-image.sh
#
#   # Build and push with a specific tag
#   ./build-image.sh --push --tag v1.0.0
#
#   # Override a tool version
#   TERRAFORM_VERSION=1.11.0 ./build-image.sh --push
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PUSH=false
PLATFORM="linux/amd64"
OUTPUT_TAG="${OUTPUT_TAG:-latest}"
BASE_REPO="${BASE_REPO:-ghcr.io/OWNER/omp-server}"
BASE_TAG="${BASE_TAG:-latest}"
OUTPUT_REPO="${OUTPUT_REPO:-omp-server-agent}"
EXTRA_BUILD_ARGS=()

# Tool version defaults (can be overridden via env)
TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.10.5}"
PACKER_VERSION="${PACKER_VERSION:-1.11.2}"
DOCKER_CLI_VERSION="${DOCKER_CLI_VERSION:-27.5.1}"
UV_VERSION="${UV_VERSION:-0.6.14}"
AWSCLI_VERSION="${AWSCLI_VERSION:-2.24.17}"
GCLOUD_VERSION="${GCLOUD_VERSION:-519.0.0}"
NODE_VERSION="${NODE_VERSION:-22.15.0}"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --push)        PUSH=true ;;
        --platform)    shift; PLATFORM="$1" ;;
        --tag)         shift; OUTPUT_TAG="$1" ;;
        --base-repo)   shift; BASE_REPO="$1" ;;
        --base-tag)    shift; BASE_TAG="$1" ;;
        --output-repo) shift; OUTPUT_REPO="$1" ;;
        --build-arg)   shift; EXTRA_BUILD_ARGS+=("--build-arg" "$1") ;;
        --help|-h)
            sed -n '2,/^set -/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

FULL_IMAGE="${OUTPUT_REPO}:${OUTPUT_TAG}"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }

# Multi-platform builds cannot be loaded locally; they require a push target.
if [[ "${PLATFORM}" == *","* && "${PUSH}" == "false" ]]; then
    echo "ERROR: multi-platform builds require --push (docker buildx cannot load multi-arch images locally)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
echo "Building ${FULL_IMAGE}"
echo "  Base image : ${BASE_REPO}:${BASE_TAG}"
echo "  Platform   : ${PLATFORM}"
echo "  Push       : ${PUSH}"
echo ""
echo "Tool versions:"
echo "  terraform  ${TERRAFORM_VERSION}"
echo "  packer     ${PACKER_VERSION}"
echo "  docker CLI ${DOCKER_CLI_VERSION}"
echo "  uv         ${UV_VERSION}"
echo "  AWS CLI    ${AWSCLI_VERSION}"
echo "  gcloud     ${GCLOUD_VERSION}"
echo "  Node.js    ${NODE_VERSION}"
echo ""

BUILD_ARGS=(
    --build-arg "OMP_BASE_REPO=${BASE_REPO}"
    --build-arg "OMP_BASE_TAG=${BASE_TAG}"
    --build-arg "TERRAFORM_VERSION=${TERRAFORM_VERSION}"
    --build-arg "PACKER_VERSION=${PACKER_VERSION}"
    --build-arg "DOCKER_CLI_VERSION=${DOCKER_CLI_VERSION}"
    --build-arg "UV_VERSION=${UV_VERSION}"
    --build-arg "AWSCLI_VERSION=${AWSCLI_VERSION}"
    --build-arg "GCLOUD_VERSION=${GCLOUD_VERSION}"
    --build-arg "NODE_VERSION=${NODE_VERSION}"
)

OUTPUT_FLAGS=()
if [[ "${PUSH}" == "true" ]]; then
    OUTPUT_FLAGS=(--push)
else
    OUTPUT_FLAGS=(--load)
fi

docker buildx build \
    "${BUILD_ARGS[@]}" \
    "${EXTRA_BUILD_ARGS[@]}" \
    --platform "${PLATFORM}" \
    --tag "${FULL_IMAGE}" \
    "${OUTPUT_FLAGS[@]}" \
    --file "${SCRIPT_DIR}/Dockerfile" \
    "${SCRIPT_DIR}"

echo ""
echo "Done: ${FULL_IMAGE}"
if [[ "${PUSH}" == "false" ]]; then
    echo ""
    echo "Image loaded locally. To use it, set in /opt/omp-server/.env:"
    echo "  IMAGE_REPO=${OUTPUT_REPO}"
    echo "  IMAGE_TAG=${OUTPUT_TAG}"
fi
