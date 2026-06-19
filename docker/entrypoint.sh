#!/usr/bin/env bash
set -euo pipefail

# ── PATH: mise + bun + omp ───────────────────────────────────────────────────
export PATH="${HOME}/.local/bin:${HOME}/.bun/bin:${PATH}"

# ── Seed $HOME from PVC + baked assets ───────────────────────────────────────
# PVC is source of truth for auth/workspace; image is source of truth for assets.
mkdir -p "${HOME}/.omp/agent" "${HOME}/work"

# Always overwrite baked assets (image is canonical for agent assets)
cp -a /opt/omp/agent/. "${HOME}/.omp/agent/"

# Seed work/.omp only if not already on PVC
if [[ ! -d "${HOME}/work/.omp" ]]; then
    cp -a /opt/omp/work-template/.omp "${HOME}/work/.omp"
fi

# Render session name placeholder
sed -i "s/__SESSION_NAME__/${OMP_SESSION_NAME}/g" "${HOME}/work/.omp/AGENTS.md"

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
cd "${HOME}/work"
tmux new-session -d -s omp -x 220 -y 50 'exec omp'

# ── Auto-dismiss the first-run setup wizard ───────────────────────────────────
# omp shows a 3-step wizard on a fresh PVC because agent.db has no registered
# credentials (env-var providers like GEMINI_API_KEY and ANTHROPIC_OAUTH_TOKEN
# are usable but not pre-registered). Escape safely dismisses all steps; it is
# a no-op at the chat prompt on subsequent starts.
(sleep 15 && tmux send-keys -t omp Escape && sleep 3 \
           && tmux send-keys -t omp Escape && sleep 3 \
           && tmux send-keys -t omp Escape) &

exec bash -c 'while tmux has-session -t omp 2>/dev/null; do sleep 5; done'
