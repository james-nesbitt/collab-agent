# Future work — backlog

Consolidated backlog of follow-ups for the GKE remote-agent platform. Each item
records the problem, a proposed approach, and rough size. Grounded in loose ends
surfaced during the platform redesign (PRs #16–#18) and operations since.

Status legend: **[ ]** open · **[~]** in progress · **[x]** done.

---

## Collab / join links

> Validated by the 2026-07-11 restore test (deleted all session pods, confirmed
> resume): conversation/data restore from the PVC is solid, but the collab-link
> lifecycle across restarts is fragile. Three concrete gaps below.

- [ ] **Re-host + recapture the join link on pod restarts.**
  omp does **not** auto-re-share collab on `--resume`, and the operator only
  captures the link when *it* creates the pod — `reconcile`'s guard skips
  recapture when the StatefulSet (not the operator) recreated `omp-0`. Net: after
  a node event / StatefulSet-driven restart, collab is off and the old room is
  dead. Fix: have the operator detect a (re)started pod (pod watch or Ready
  transition) and re-host (`/collab`) + recapture the link regardless of who
  created the pod. The annotation-driven recapture path (`on_recapture`) also
  failed to refresh in testing — make it reliably re-derive the *live* link.
  _Size: M._

- [ ] **`status.joinLink` is stale/untrustworthy after restarts.**
  In the restore test the operator kept a **truncated, pre-restart token** in
  `status.joinLink` while the true live room (captured from the pane and
  browser-verified) was different. Consumers (manager skill,
  `ompctl session link`) shouldn't trust `status.joinLink` until
  recapture-on-restart lands. Fix ships with the item above; interim: document
  that the pane is the source of truth. _Size: S (docs) → folds into the fix._

- [ ] **`collab-link.json` is not written by the pinned omp image.**
  The operator's primary link path (`_read_join_link_file`) reads
  `~/.omp/collab-link.json`, but the 16.3.11 session image never writes it — so
  the operator **always** falls back to the fragile tmux scrape, and the file
  path is effectively dead code. Decide: adopt an omp build that emits the file
  (with a verified `joinLink`/`viewLink` schema, guarded against drift), or make
  the tmux path the sanctioned primary and harden it (below). _Size: S._

- [ ] **Harden the tmux join-link fallback.**
  `operator/session_operator.py:_tmux_capture_join_link` greps `omp join "..."`
  from the pane and takes `tail -1`. That can grab a **stale token** left in
  scrollback by a prior `/collab view`, or the wrong read-write vs read-only
  variant. Fixes: parse by the labeled lines (`Join from another terminal:` for
  read-write, `Read-only link:` for view) instead of a blind `tail -1`; clear or
  bound the capture window right before sending `/collab`.
  _Size: S._

## Infrastructure / scaling

- [x] **GKE cluster autoscaling.** _(PR #20, applied 2026-07-11.)_
  The `default` node pool now autoscales: `initial_node_count` +
  `autoscaling { min_node_count = 1, max_node_count = 6, location_policy = "BALANCED" }`
  plus `management { auto_repair, auto_upgrade }` in `infra/main.tf`, with
  `min_node_count`/`max_node_count` vars. Session pods already declare resource
  requests (main `500m`/`1Gi`, sidecar `50m`/`128Mi`), so scale-up triggers on
  `Pending` pods and scale-down on drain; verified in-place (no node recreation).
  Remaining if desired: surface the min/max knobs through
  `charts/omp-platform/values.yaml` and revisit scale-down vs. PVC retention
  under sustained load.
  _Size: M — done._

## Images / deployment

- [ ] **Fix the stale operator default session image.**
  The operator's default `sessionImageTag` / redeploy resolved to an old build
  (16.2.1), so new unpinned sessions don't land on `latest`. Drive the default
  from CI (`latest` or a digest) via Helm values, and confirm a
  rebuild→redeploy path bumps it. Until fixed, sessions need an explicit
  `spec.image` pin.
  _Size: S._

- [x] **Repoint the live operator off local Artifact Registry overrides.** _(applied 2026-07-11.)_
  The operator now runs the CI-published GHCR image
  `ghcr.io/james-nesbitt/collab-agent/omp-operator:latest` (built from `main`
  including the self-heal fix). Removed the `operatorRegistry`/`operatorImageTag`
  AR overrides from `infra/terraform.tfvars` (falls back to `registry` +
  `latest`) and applied. Sessions were already on GHCR (`registry` + `sha-…`
  pin). Remaining nicety: digest-pin `latest` for reproducibility (see the
  security item).
  _Size: S — done._

## ompctl

- [ ] **Use the Kubernetes Python client instead of shelling to `kubectl`.**
  `cmd_auth` and `cmd_port_forward` still call `kubectl exec -it` /
  `kubectl port-forward`, requiring the `kubectl` binary + `gke-gcloud-auth-plugin`
  on PATH (unlike the cred/session commands, which use the API). Move these to
  the API (exec stream + port-forward) to remove the binary dependency and the
  interactive-TTY brittleness.
  _Size: M._

- [ ] **Package ompctl properly.**
  It's currently a single-file `uv`-shebang script (self-provisions via PEP 723).
  Consider a pipx-installable package with a console entry point for durable
  distribution, while keeping the zero-setup `uv run` path.
  _Size: M._

## Consolidation / hygiene

- [ ] **Make Helm the single source for manifests.**
  Raw `k8s/*.yaml` (crd-session, operator-deploy/rbac, vap-credential-secrets,
  clustersecretstore, omp-config) duplicate `charts/omp-platform/templates/*`.
  Drop or generate the raw manifests from the chart and update docs/skills that
  still reference `k8s/`.
  _Size: M._

- [ ] **Bring omp-config profiles under the chart / Terraform.**
  `omp-config-anthropic` was applied to the cluster by hand. Version all config
  profiles (base, glm, anthropic, gemini) in the chart (or Terraform) so they're
  reproducible rather than live-only edits.
  _Size: S._

- [ ] **Consolidate `docs/planning/*` historical records.**
  Deferred in PR #17. Fold superseded design docs together and mark clearly which
  are canonical vs historical, so the planning folder stays a usable record.
  _Size: S._

## Security (Group B — deferred from the redesign)

- [ ] **Dedicated minimal node service account** for the session node pool
  (least privilege instead of the default compute SA).
- [ ] **Digest-pin the omp image** (not just a tag) for the operator and sessions.
- [ ] **Document accepted residual risks:** collab/exec implies full session
  access to any guest with the link; the session main container runs privileged
  for rootless-docker-in-pod; ESO IAM `secretmanager.viewer` grants are applied
  outside Terraform (`administrator.sh vault-add`) — decide whether to bring them
  under IaC.
  _Size: M (mostly analysis + docs)._
