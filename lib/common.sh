#!/usr/bin/env bash
# lib/common.sh — shared configuration and helpers for the remote-agent-machine
# tooling (administrator.sh + manager.sh). Sourced, never executed directly.
#
# A sourcing script SHOULD set LOG_TAG before sourcing (e.g. LOG_TAG=admin);
# it defaults to "omp".

# ---------------------------------------------------------------------------
# Configuration (override via environment)
# ---------------------------------------------------------------------------
GCP_PROJECT="${GCP_PROJECT:-tools-348616}"
ZONE="${ZONE:-europe-west1-b}"
REGION="${REGION:-europe-west1}"
CLUSTER_NAME="${CLUSTER_NAME:-omp-cluster}"
LOG_TAG="${LOG_TAG:-omp}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
info() { echo "[${LOG_TAG}] $*"; }
warn() { echo "[${LOG_TAG}] WARN: $*"; }
ok()   { echo "[${LOG_TAG}] OK: $*"; }
die()  { echo "[${LOG_TAG}] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# kubectl wrapper — targets the GKE cluster by context name
# ---------------------------------------------------------------------------
kctl() {
    kubectl --context "gke_${GCP_PROJECT}_${ZONE}_${CLUSTER_NAME}" "$@"
}

# ---------------------------------------------------------------------------
# GCP resource helpers
# ---------------------------------------------------------------------------
resource_exists() {
    # resource_exists <gcloud subcommand> <name> [extra flags...]
    local subcmd=$1; shift
    local name=$1; shift
    gcloud ${subcmd} describe "${name}" "$@" --project="${GCP_PROJECT}" \
        --format="value(name)" 2>/dev/null | grep -q .
}

# ---------------------------------------------------------------------------
# Cluster guard
# ---------------------------------------------------------------------------
require_cluster() {
    gcloud container clusters describe "${CLUSTER_NAME}" \
        --zone="${ZONE}" \
        --project="${GCP_PROJECT}" \
        --format="value(name)" >/dev/null 2>&1 \
        || die "GKE cluster '${CLUSTER_NAME}' not found. Run: ./administrator.sh provision"
}
