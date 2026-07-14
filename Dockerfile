FROM ubuntu:24.04

# ── 1. System packages ──────────────────────────────────────────────────────
# Install base packages, rootless podman stack, iptables, and Docker CE
# (including rootless extras) from the official Docker apt repository.
# Single layer for apt-cache consistency; cleanup at the end.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        tmux curl unzip git ca-certificates openssh-client \
        podman slirp4netns fuse-overlayfs uidmap dbus-user-session \
        iptables && \
    # Add Docker CE apt repo
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
https://download.docker.com/linux/ubuntu noble stable" \
        > /etc/apt/sources.list.d/docker.list && \
    # Add GitHub CLI apt repo
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
        gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-ce-rootless-extras \
        gh && \
    rm -rf /var/lib/apt/lists/*

# ── 1b. Cloud CLIs: gcloud, aws-cli v2, azure-cli ───────────────────────────
# Each CLI is installed system-wide (as root) so all users can call them.
# Credentials are stored per-user under $HOME (on the PVC) and survive restarts.
RUN \
    # Google Cloud CLI — official apt repo
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
        gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloud.google.gpg] \
https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list && \
    # Azure CLI — official Microsoft apt repo
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
        gpg --dearmor -o /usr/share/keyrings/microsoft.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/microsoft.gpg] \
https://packages.microsoft.com/repos/azure-cli/ noble main" \
        > /etc/apt/sources.list.d/azure-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-cloud-cli azure-cli python3-crcmod && \
    # AWS CLI v2 — official installer (no apt package)
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip && \
    rm -rf /var/lib/apt/lists/*

# ── 2. Rename base user ubuntu → omp (preserves UID/GID 1000) ───────────────
RUN groupmod -n omp ubuntu && \
    usermod -l omp -d /home/omp -m -s /bin/bash ubuntu

# ── 3. Subordinate UID/GID ranges for rootless engines ──────────────────────
RUN echo 'omp:100000:65536' >> /etc/subuid && \
    echo 'omp:100000:65536' >> /etc/subgid

# ── 4. Install mise + bun + omp (as user omp) ───────────────────────────────
# OMP_VERSION is resolved to the latest published release by CI (daily build)
# and passed via --build-arg; defaults to a known-good pin for local builds.
# Keep this as the LAST heavy layer so a version bump only re-pulls the omp
# layer, not the base-OS / cloud-CLI layers above.
USER omp
WORKDIR /home/omp

ARG OMP_VERSION=16.3.11

RUN curl -fsSL https://mise.run | sh && \
    echo 'export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"' >> "$HOME/.profile" && \
    echo 'eval "$($HOME/.local/bin/mise activate bash --shims)" 2>/dev/null || true' >> "$HOME/.profile" && \
    "$HOME/.local/bin/mise" use -g bun@latest && \
    "$HOME/.local/bin/mise" exec bun -- bun install -g @oh-my-pi/pi-coding-agent@${OMP_VERSION}

# ── 5. vfs storage driver for podman ────────────────────────────────────────
# Uses vfs so no /dev/fuse device or device-plugin is needed in a
# non-privileged pod. fuse-overlayfs is present for a future overlay switch
# if a /dev/fuse device plugin is added.
RUN mkdir -p "$HOME/.config/containers" && \
    printf '[storage]\ndriver = "vfs"\n' > "$HOME/.config/containers/storage.conf"

# ── 6. Bake platform assets (as root) ───────────────────────────────────────
USER root

# Platform agent assets → /opt/omp/agent/ (read-only staging; entrypoint copies to $HOME)
COPY platform/AGENTS.md                          /opt/omp/agent/AGENTS.md
COPY platform/RULES.md                           /opt/omp/agent/RULES.md
COPY platform/secrets.yml                        /opt/omp/agent/secrets.yml
COPY platform/rules/                             /opt/omp/agent/rules/
COPY platform/commands/commit-push-pr.md         /opt/omp/agent/commands/commit-push-pr.md
COPY platform/skills/credential-access/SKILL.md  /opt/omp/agent/skills/credential-access/SKILL.md
COPY platform/skills/mirantis-services/SKILL.md  /opt/omp/agent/skills/mirantis-services/SKILL.md
COPY platform/skills/credential-rotation/SKILL.md /opt/omp/agent/skills/credential-rotation/SKILL.md

# Session work-tree template → /opt/omp/work-template/.omp/
COPY session-template/.omp/config.yml  /opt/omp/work-template/.omp/config.yml
COPY session-template/.omp/AGENTS.md   /opt/omp/work-template/.omp/AGENTS.md

RUN chown -R omp:omp /opt/omp && \
    # Compile a standalone omp binary so it survives the PVC mount shadowing /home/omp.
    # --external omp-legacy-pi-modules: since 16.4.3 the CLI bundle carries a lazy
    # `import("omp-legacy-pi-modules")` fallback for BUNDLED_PI_MODULES — a virtual
    # module only present in omp's own official compile. A third-party `bun build`
    # can't resolve it, so mark it external. The fallback is dead in normal operation
    # (nothing reads the global it sets); verified via `omp models`/`--help`.
    /home/omp/.local/bin/mise exec bun -- bun build \
        --compile \
        --external omp-legacy-pi-modules \
        --outfile /usr/local/bin/omp \
        /home/omp/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js && \
    chmod 755 /usr/local/bin/omp && \
    # Copy pi_natives addon alongside the compiled binary; bun compiled binaries cannot
    # embed native .node files and look in /usr/local/bin/ as one of their search paths
    cp /home/omp/.bun/install/global/node_modules/@oh-my-pi/pi-natives-linux-x64/pi_natives.linux-x64-modern.node /usr/local/bin/ && \
    cp /home/omp/.bun/install/global/node_modules/@oh-my-pi/pi-natives-linux-x64/pi_natives.linux-x64-baseline.node /usr/local/bin/

# ── 6b. Pre-download tiny-model weights (transformers.js FileCache layout) ──
# Layout MUST match @huggingface/transformers FileCache: <cacheDir>/<repo-id>/<file>
# (the cache key for revision 'main' is literally "<repo-id>/<file>").
# entrypoint.sh seeds these into ~/.cache/huggingface/transformers on first pod
# start per session PVC. curl -f makes a 404 fail the build loudly.
RUN set -eu; \
    CACHE=/opt/omp/hf-cache; \
    for repo in onnx-community/LFM2-350M-ONNX onnx-community/Qwen3-1.7B-ONNX; do \
        for f in config.json tokenizer.json tokenizer_config.json generation_config.json onnx/model_q4.onnx; do \
            mkdir -p "${CACHE}/${repo}/$(dirname "${f}")"; \
            curl -fsSL --retry 3 -o "${CACHE}/${repo}/${f}" \
                "https://huggingface.co/${repo}/resolve/main/${f}"; \
        done; \
    done; \
    chown -R omp:omp "${CACHE}"

# ── 7. Entrypoint ────────────────────────────────────────────────────────────
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# ── 8. Final image config ────────────────────────────────────────────────────
USER omp
WORKDIR /home/omp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
