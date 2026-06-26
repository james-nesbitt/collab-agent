# Session transfer: local → GKE (and back)

## Investigation findings

### What a session is on disk

omp stores sessions under `$PI_CODING_AGENT_DIR/sessions/<encoded-cwd>/`:

| File | Content | Transferable? |
|---|---|---|
| `<timestamp>_<uuid>.jsonl` | Conversation history (JSON lines). First entry carries `{type:"session", cwd, id, version}`. No binary content in the entries themselves. | ✓ plain text, copy directly |
| `agent.db` | SQLite: auth credentials, model settings, usage history, cache. Shared across all sessions. | ✓ with WAL checkpoint |
| `models.db` | Model picker state / usage stats. | ✓ optional |
| `history.db` | Command history. | ✓ optional |
| `blobs/` | Tool output blobs (images, etc.) referenced by sessions. | ✓ if referenced |

The agent dir in the pod is `~/.omp/agent/` (default; no `PI_CODING_AGENT_DIR` set in the pod env).

### Path encoding — the critical piece

omp encodes the session's `cwd` into a directory name by stripping the home prefix, replacing `/` with `-`, and prepending `-`:

```
encoded = "-" + cwd.relative_to(HOME).replace("/", "-")
```

| Machine | HOME | cwd | encoded |
|---|---|---|---|
| local | `/home/jnesbitt` | `/home/jnesbitt/prodeng-3468` | `-prodeng-3468` |
| pod | `/home/omp` | `/home/omp/prodeng-3468` | `-prodeng-3468` |

**They match** when the project lives directly under `$HOME` with the same name. Since the pod always uses `WORK_DIR="${HOME}/${OMP_SESSION_NAME}"` (one level under home, named after the session), a local checkout at `~/<session-name>` encodes identically. A local checkout at a deeper path (e.g. `~/Documents/Mirantis/research/my-project`) does **not** match the pod's `-my-project`.

### Resume flags

omp provides three mechanisms that bypass or extend path-based lookup:

| Flag | Effect |
|---|---|
| `-c` / `--continue` | Resume the most recent session for the current cwd (path-matched). |
| `-r <id>` / `--resume=<id>` | Resume any session by ID prefix or path — **no cwd constraint**. |
| `--session-dir=<dir>` | Use a different root for session lookup (changes where omp looks for encoded dirs). |
| `--cwd=<dir>` | Override the launch cwd used for path encoding. |

`--resume=<id>` is the key for cross-path transfer: copy the `.jsonl` anywhere on the PVC and start omp with `--resume=<uuid-prefix>`.

### agent.db — auth and model state

The `agent.db` SQLite database holds:
- `auth_credentials` — OAuth tokens (Anthropic, Gemini, etc.), API keys, identity hints
- `settings` — user preferences, model selection
- `model_usage`, `usage_history` — stats only

Transferring `agent.db` carries the auth state across. Caveat: OAuth tokens are time-limited; transferring a stale db doesn't break anything but doesn't provide auth either. The right model: transfer `auth_credentials` rows selectively, or just re-auth in the pod via `./administrator.sh auth`.

---

## Transfer scenarios

### A — Same-name shallow project (drop-in, no path gymnastics)

**When:** Local session is at `~/<session-name>` (same as the GKE session name).

```
local:  /home/jnesbitt/prodeng-3468  →  -prodeng-3468
pod:    /home/omp/prodeng-3468        →  -prodeng-3468  ✓ same
```

**Transfer:**
1. Copy the `.jsonl` file(s) to the pod PVC at the matching path.
2. `omp -c` on the next pod start resumes it automatically.

No entrypoint change needed.

### B — Deeper local path (ID-based resume)

**When:** Local session is at `~/Documents/Mirantis/research/gke` → `-Documents-Mirantis-research-gke`, but the pod cwd is `~/gke` → `-gke`.

**Transfer:**
1. Copy the `.jsonl` to the pod PVC at `~/.omp/agent/sessions/-gke/` (the pod's encoded cwd).
2. Start omp with `--resume=<uuid-prefix>` targeting that file.

Or use `--session-dir` to point omp at a temporary directory that contains the jsonl under the **original** encoding, making `-c` work:
```bash
mkdir -p /tmp/xfr/-Documents-Mirantis-research-gke
cp session.jsonl /tmp/xfr/-Documents-Mirantis-research-gke/
omp --session-dir=/tmp/xfr -c --allow-home
```

### C — Code + conversation together

The `.jsonl` carries the conversation; the actual files (repo, work artefacts) are separate. Full transfer:

1. Push local working branch to GitHub (or whatever remote).
2. Clone in the pod (already works via `gh` CLI + `GITHUB_TOKEN`).
3. Copy the `.jsonl`.
4. omp resumes with both the conversation and the right code context.

### D — Reverse: GKE → local

Same mechanism in reverse: `kubectl cp` the `.jsonl` off the pod PVC, place it in the local session dir at the matching encoded path, then `omp -c` locally.

---

## What to build

### Phase 1 — `administrator.sh session-transfer` (local → GKE)

```bash
./administrator.sh session-transfer WORK NAME [SESSION_ID]
```

- `WORK` — local working directory (the directory omp was running in locally)
- `NAME` — GKE session name
- `SESSION_ID` — optional; defaults to most recent session for that cwd

Steps:
1. Find the most recent (or specified) `.jsonl` for `WORK` in the local agent dir.
2. Create the Session CR if it doesn't exist (or require it to exist — TBD).
3. `kubectl cp` the `.jsonl` to the right encoded path on the pod PVC.
4. Annotate the session with a `resumeId` (new annotation) so the entrypoint can use `--resume=<id>` instead of `-c` (avoids the path-encoding problem for scenario B).

### Phase 2 — Entrypoint: prefer `--resume` over `-c` when a specific session is targeted

Add to `docker/entrypoint.sh`: check for a `RESUME_SESSION_ID` env var (injected via `spec.env` in the Session CR). When set, launch with `--resume="${RESUME_SESSION_ID}"` instead of `-c`.

```bash
if [[ -n "${RESUME_SESSION_ID}" ]]; then
    exec omp --resume="${RESUME_SESSION_ID}" --allow-home
elif find "${HOME}/.omp/agent/sessions" -type f -name '*.jsonl' 2>/dev/null | grep -q .; then
    exec omp -c --allow-home
else
    exec omp --allow-home
fi
```

`RESUME_SESSION_ID` is a one-shot: after omp loads the session it writes new entries under the pod's own cwd encoding, so subsequent restarts fall back to `-c` naturally (the session file is now in the right place). Clear the env via a `spec.env` patch after first start, or let it no-op (omp will just look for a session with that ID; once found, `-c` would work anyway since the session is now in the local encoding dir).

### Phase 3 — Auth state transfer (optional)

Copy `agent.db` to the pod PVC. Since the DB may have stale tokens, only copy `auth_credentials` rows matching non-expired entries:

```bash
# Extract current valid Anthropic credential from local db, inject into pod db
# via omp auth-broker import (if the CLI supports it) or direct sqlite INSERT
```

More practical: use `./administrator.sh auth NAME anthropic` to re-auth interactively; skip DB transfer unless the user has a specific need to carry session-specific model selections or cache.

---

## Constraints & gaps

| Constraint | Impact |
|---|---|
| RWO PVC — only one pod can mount at a time | Can't `kubectl cp` to PVC while pod is running... **actually can**: `kubectl cp` works via `kubectl exec` + tar, which goes through the running container. PVC is mounted by the pod, copy goes through the pod. ✓ |
| Session `.jsonl` references cwd in its header | When omp reads the session, it sees the original local cwd. This is cosmetic (used for display); the actual file operations use the pod's cwd. No functional impact. |
| Blobs directory | Large tool outputs (images, screenshots) referenced from the jsonl are stored in `blobs/`. The session will display correctly without them (blobs are output artefacts, not inputs). Transfer them only if you need to re-read tool results. |
| WAL files | `agent.db` has `-wal` and `-shm` companions. Copy all three, or `PRAGMA wal_checkpoint(TRUNCATE)` on the source first to collapse them. |
| omp version drift | Local omp may differ from the pod's omp. The `.jsonl` format is versioned (`"version": 3`); older readers may not parse newer entries. Pin the pod image to the same version or use `--resume` which is forward-compatible. |
| Two agent dirs | Local machine has both `~/.local/share/omp/` (omp 16.x) and `~/.omp/agent/` (omp pre-16). Pod uses `~/.omp/agent/`. Use `PI_CODING_AGENT_DIR` env to determine which local dir to read from. |

---

## Simplest possible end-to-end transfer (today, no code changes)

```bash
SESSION=prodeng-3468
LOCAL_CWD=~/prodeng-3468
NS="omp-session-${SESSION}"

# 1. Find the most recent local session jsonl for this cwd
LOCAL_HOME=$(eval echo ~)
ENCODED="-$(realpath --relative-to="${LOCAL_HOME}" "${LOCAL_CWD}" | tr '/' '-')"
JSONL=$(ls -t "${LOCAL_HOME}/.local/share/omp/sessions/${ENCODED}"/*.jsonl 2>/dev/null | head -1)
SESSION_ID=$(basename "${JSONL}" .jsonl | cut -d_ -f2)

echo "Transferring session ${SESSION_ID} (${JSONL})"

# 2. Copy jsonl to the pod PVC (through the running pod)
kubectl exec -n "${NS}" omp -- mkdir -p "/home/omp/.omp/agent/sessions/${ENCODED}"
kubectl cp "${JSONL}" "${NS}/omp:/home/omp/.omp/agent/sessions/${ENCODED}/$(basename "${JSONL}")"

# 3. Restart the pod; the -c entrypoint will pick up the session
kubectl patch session "${SESSION}" -n omp-system \
  --type=merge -p "{\"spec\":{\"image\":null},\"metadata\":{\"annotations\":{\"omp.mirantis.io/restartedAt\":\"$(date +%s)\"}}}"
```

For scenario B (deeper path), also pass `RESUME_SESSION_ID` via `spec.env` — but that requires the entrypoint change from Phase 2.
