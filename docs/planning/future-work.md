# Future work — backlog

Consolidated backlog of follow-ups for the GKE remote-agent platform. Each item
records the problem, a proposed approach, and rough size. Grounded in loose ends
surfaced during the platform redesign (PRs #16–#18) and operations since.

Status legend: **[ ]** open · **[~]** in progress · **[x]** done.

---

## Collab / join links

- [ ] **Harden the tmux join-link fallback.**
  `operator/session_operator.py:_tmux_capture_join_link` greps `omp join "..."`
  from the pane and takes `tail -1`. That can grab a **stale token** left in
  scrollback by a prior `/collab view`, or the wrong read-write vs read-only
  variant. Fixes: parse by the labeled lines (`Join from another terminal:` for
  read-write, `Read-only link:` for view) instead of a blind `tail -1`; clear or
  bound the capture window right before sending `/collab`; and prefer
  `collab-link.json` as the sole source when present, treating tmux purely as a
  last resort.
  _Size: S._

- [ ] **Verify `collab-link.json` schema across omp versions.**
  The file-read path (`_read_join_link_file`) assumes `joinLink` / `viewLink`
  keys. Confirm which omp releases actually write the file and with what keys
  (16.3.11 baseline); guard the parser so a schema drift falls back cleanly
  rather than silently mis-populating status. Ties into the fallback hardening
  above.
  _Size: S._

## Infrastructure / scaling

- [ ] **GKE cluster autoscaling.**
  The node pool in `infra/terraform` is fixed-size; session pods don't scale
  with demand. Add the cluster autoscaler (or node auto-provisioning) with
  sensible `min`/`max` node counts, per-session CPU/memory requests so the
  scheduler can pack and scale, and a scale-down policy. Validate interaction
  with per-session PVC retention (nodes shouldn't scale down out from under a
  bound PVC mid-session). Wire the knobs through `infra/terraform.tfvars` and
  `charts/omp-platform/values.yaml`.
  _Size: M._

## Images / deployment

- [ ] **Fix the stale operator default session image.**
  The operator's default `sessionImageTag` / redeploy resolved to an old build
  (16.2.1), so new unpinned sessions don't land on `latest`. Drive the default
  from CI (`latest` or a digest) via Helm values, and confirm a
  rebuild→redeploy path bumps it. Until fixed, sessions need an explicit
  `spec.image` pin.
  _Size: S._

- [ ] **Repoint the live operator/session off local Artifact Registry overrides.**
  The running operator used local AR overrides (`operator:platform-redesign`,
  session `glm-overlay`). Drop the `operatorRegistry` override and pin to the
  CI-published GHCR images (`latest` or digest) so the cluster runs released
  artifacts, not local builds.
  _Size: S._

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
