#!/usr/bin/env bash
set -euo pipefail

# ── PATH: mise + bun + omp ───────────────────────────────────────────────────
export PATH="${HOME}/.local/bin:${HOME}/.bun/bin:${PATH}"

# ── Seed $HOME from PVC + baked assets ───────────────────────────────────────
# PVC is source of truth for auth/workspace; image is source of truth for assets.
WORK_DIR="${HOME}/${OMP_SESSION_NAME}"
mkdir -p "${HOME}/.omp/agent" "${WORK_DIR}"

# Always overwrite baked assets (image is canonical for agent assets)
cp -a /opt/omp/agent/. "${HOME}/.omp/agent/"

# Seed <session>/.omp only if not already on PVC
if [[ ! -d "${WORK_DIR}/.omp" ]]; then
    cp -a /opt/omp/work-template/.omp "${WORK_DIR}/.omp"
fi

# Seed tiny-model weights from the image layer (one-time per session PVC).
# Target must match omp's transformers.js env.cacheDir. Per-model copy only
# if absent so runtime-refreshed files are never overwritten.
if [[ -d /opt/omp/hf-cache ]]; then
    HF_SEED_TARGET="${HOME}/.cache/huggingface/transformers"
    for _org_dir in /opt/omp/hf-cache/*/; do
        [[ -d "${_org_dir}" ]] || continue
        _org="$(basename "${_org_dir}")"
        for _model_dir in "${_org_dir}"*/; do
            [[ -d "${_model_dir}" ]] || continue
            _model="$(basename "${_model_dir}")"
            if [[ ! -d "${HF_SEED_TARGET}/${_org}/${_model}" ]]; then
                mkdir -p "${HF_SEED_TARGET}/${_org}"
                cp -a "${_model_dir}" "${HF_SEED_TARGET}/${_org}/${_model}"
            fi
        done
    done
    unset _org_dir _org _model_dir _model HF_SEED_TARGET
fi

# Render session name placeholder
sed -i "s/__SESSION_NAME__/${OMP_SESSION_NAME}/g" "${WORK_DIR}/.omp/AGENTS.md"

# ── Apply omp config from ConfigMap if present ───────────────────────────────
if [[ -f /etc/omp/config.yml ]]; then
    cp /etc/omp/config.yml "${HOME}/.omp/config.yml"
fi

# ── Start rootless dockerd (vfs driver, non-fatal) ───────────────────────────
export XDG_RUNTIME_DIR="${HOME}/.docker-run"
mkdir -p "${XDG_RUNTIME_DIR}"

dockerd-rootless.sh --storage-driver vfs \
    >"${HOME}/.omp/dockerd.log" 2>&1 &

export DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/docker.sock"

# Poll up to 30 s; non-fatal — omp still launches if docker never comes up
_docker_ready=false
for _i in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
        _docker_ready=true
        break
    fi
    sleep 1
done
if [[ "${_docker_ready}" == "false" ]]; then
    echo "[entrypoint] WARN: rootless dockerd did not start within 30s; docker may be unavailable" >&2
fi

# ── Launch omp under tmux, block on session lifetime ─────────────────────────
# Container lifetime = omp session lifetime.
# pod restartPolicy:Always restarts the container if omp exits.
cd "${WORK_DIR}"
# Resume the omp session for this work dir.
# Priority order:
#   1. RESUME_SESSION_ID — set by session-transfer to resume a specific transferred session
#      by ID regardless of cwd encoding (handles cross-path transfers).
#   2. -c / --continue   — resume the most recent session for this cwd (normal restarts).
#   3. fresh start       — no prior session found on PVC.
#
# OMP_MODEL (optional): pins the interactive TUI model, e.g. "ollama-cloud/glm-5.2".
# The config file's modelRoles.default only governs agent/print-mode; the interactive
# current-model is settable only via omp's --model flag, so it is injected here.
MODEL_ARG=""
if [[ -n "${OMP_MODEL:-}" ]]; then
    MODEL_ARG="--model=${OMP_MODEL}"
fi
if [[ -n "${RESUME_SESSION_ID:-}" ]]; then
    tmux new-session -d -s omp -x 220 -y 50 "exec omp --resume='${RESUME_SESSION_ID}' --allow-home ${MODEL_ARG}"
elif find "${HOME}/.omp/agent/sessions" -type f -name '*.jsonl' 2>/dev/null | grep -q .; then
    tmux new-session -d -s omp -x 220 -y 50 "exec omp -c --allow-home ${MODEL_ARG}"
else
    tmux new-session -d -s omp -x 220 -y 50 "exec omp --allow-home ${MODEL_ARG}"
fi

# ── Auto-dismiss the first-run setup wizard ───────────────────────────────────
# omp shows a 3-step wizard on a fresh PVC because agent.db has no registered
# credentials (env-var providers like GEMINI_API_KEY and ANTHROPIC_OAUTH_TOKEN
# are usable but not pre-registered). Escape safely dismisses all steps; it is
# a no-op at the chat prompt on subsequent starts.
(sleep 15 && tmux send-keys -t omp Escape && sleep 3 \
           && tmux send-keys -t omp Escape && sleep 3 \
           && tmux send-keys -t omp Escape) &

exec bash -c 'while tmux has-session -t omp 2>/dev/null; do sleep 5; done'
