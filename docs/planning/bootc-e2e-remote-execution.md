# Running the bootc-mke3 e2e test as a remote session

## Goal

Execute `bootc-mirantis`'s `bootc-e2e-test` skill (a multi-hour AWS end-to-end
test of the bootc-mke3 stack) inside a remote session on this platform, instead
of a local agent session that must stay open for the run's duration.

The run's phases and their wall-clock cost are defined by the skill itself
(`bootc-mirantis/.claude/skills/bootc-e2e-test/SKILL.md`): provision → install →
access → controllers → 25-worker no-touch join → machine-config → cross-version
upgrade → ledger → teardown. Phase F's serial reboot rollout is ~1 node/minute;
Phase G runs on the order of hours against the CR's 4 h default timeout. This
duration is the entire reason for hosting the run remotely: a session pod runs
its agent under tmux independent of any client connection
(`docs/farm-out-execution.md`), so the run survives laptop sleep, network loss,
and harness restarts.

## What already works

Verified 2026-08-10 against the live cluster and vault, not inferred:

- **Session hosting.** `omp-cluster` (`europe-west1-b`) serving; an existing
  session reached `Hosting`. Per-session 50 Gi PVC `$HOME` persists the run's
  scratch directory, evidence files, and provider tokens across pod restarts
  (`docs/architecture.md` §4).
- **Anthropic model access.** ConfigMap `omp-config-anthropic` exists and is in
  use by a live session; `ompctl auth <session> anthropic` completes the device
  flow, and its OAuth callback port-forward is arranged automatically
  (`ompctl:552-566`).
- **GitHub.** `users/jnesbitt/github-token` is present in the vault, delivered
  to the pod as `GITHUB_TOKEN` and as `/etc/omp-creds/GITHUB_TOKEN`. In-pod
  `gh auth login --with-token` + `gh auth setup-git` covers both the repo
  checkouts the skill reads (`bootc-mke3`, `cluster-upgrade-controller`,
  `machine-config-controller`) and the doc-improvement PRs it produces.
- **AWS.** The test's dev account `prodeng-team` is `533267045383`
  (`bootc-mirantis/docs/release-pipeline-permissions.md:422`). Under profile
  `docker-testing-533267045383` in `us-east-2`: dev AMIs resolve (newest
  observed `bootc-mke3-dev-r9-cloud-mcr29.6.1-mke3.9.5-b28`) and the
  On-Demand Standard vCPU quota (`L-1216C47A`) is 512 — sufficient for the
  skill's 3 managers + 25 workers. `aws sso login --no-browser` via
  `ompctl auth <session> aws` (`ompctl:532`) is a device flow over 443, so it
  is not itself affected by the egress restriction in B1.

Credential provisioning for such a session is therefore solved. The blockers
below are about execution capability, not credentials.

## Blockers

Each item is independently resolvable and independently useful. Numbering is
referenced by the driving work; it is not a priority order.

### B1 — Session egress permits only TCP 443, so `ansible` cannot reach EC2

`_network_policies` (`operator/session_operator.py:220-278`) applies three
policies per session namespace: default-deny both directions, DNS to
`kube-system`, and egress to TCP 443 on `0.0.0.0/0` excluding RFC1918 and
`169.254.169.254/32`.

Consequences for the e2e run:

- Phase B (`ansible-playbook mke-install-playbook.yml`) transports over SSH to
  port 22 on the manager instances. Blocked. This is the first phase that does
  real work, so the run cannot start.
- Phase D/F/G SSH spot-verification and the in-image proof (`docker images`
  diff on a manager, `bootc status` post-upgrade) are blocked by the same rule.
- MKE's Kubernetes API on 6443 (client bundle `kube.yml`) is outside the
  allowance, so Phase C onward cannot use `kubectl` against the cluster under
  test even though the AWS control-plane APIs on 443 are reachable.

`openssh-client` is present in the image (`Dockerfile:9`), so the transport
itself is available — only the network policy prevents its use.

Options, with the tradeoff each carries:

1. **Per-session opt-in egress** — a new `Session` spec field (e.g.
   `extraEgressPorts`) that the operator merges into `allow-egress-https`.
   Preserves deny-by-default for every other session; costs a CRD field, an
   operator change, chart schema update, and a VAP decision about who may
   request which ports.
2. **Widen the shared policy** to include 22 and 6443. One change, but every
   session on the cluster gains outbound SSH, which weakens the containment
   property the current policy exists to provide.
3. **Keep 443 and reach instances over AWS SSM** (or an HTTPS-tunnelled jump
   host). No platform change. However the `bootc-mke3` runbooks the skill
   exists to validate specify plain SSH as `cloud-user`; substituting a
   different access path means the run no longer validates the documented
   operator procedure, which is the skill's stated purpose.

Acceptance: from a session pod, `ssh cloud-user@<ec2-public-ip>` connects and
`kubectl --kubeconfig <bundle>/kube.yml get nodes` succeeds against an MKE
cluster in the test account.

### B2 — Session image lacks `terraform`, `ansible`, `kubectl`, and `helm`

`Dockerfile:7-52` installs `tmux curl unzip git ca-certificates openssh-client`,
docker/containerd + rootless extras, gcloud, aws-cli v2, and azure-cli. None of
the four tools the e2e run depends on are present:

| Tool | Needed by |
|---|---|
| `terraform` | Phase A provision, teardown |
| `ansible` (+ `ansible-playbook`) | Phase B install, Phase D controller override |
| `kubectl` | Phases C–G (every checkpoint) |
| `helm` | Phase D chart override for machine-config-controller |

Open question for whoever resolves this: bake them into the image (available to
every session, larger image, versions pinned by CI) versus install per-session
via `mise` on the PVC (session-scoped, no image change, re-run cost on PVC
loss). The e2e skill pins no versions for these tools, so either satisfies it.

Acceptance: a fresh session pod reports all four on `PATH`, and
`terraform -version` / `ansible --version` / `kubectl version --client` /
`helm version` all succeed.

### B3 — No structured completion signal for a farmed-out run

`docs/farm-out-execution.md` documents submit-and-poll via `kubectl exec` +
`tmux send-keys`, with results read by `capture-pane`. Its own Limitations
section states the output is pane-scraping, unreliable to parse, and that
completion is inferred from a spinner versus an idle prompt. RPC mode is listed
as planned, with the concurrent-access question against a live TUI session
explicitly not yet investigated.

Impact specific to this run: the e2e protocol is checkpoint-driven, and several
checkpoints are decision points a human must clear — every doc-improvement push
and PR requires its own explicit approval (skill §12), and Phase G may
legitimately halt on a known upstream storage-driver defect that must be
recorded rather than worked around. Fire-and-forget submission of a whole phase
therefore stalls silently at the first gate.

The interim path that needs no new platform capability is collab: the remote
agent owns the run, an operator joins at phase gates to review evidence and
grant approvals, then disconnects while work continues. Whether that is
sufficient, or whether RPC mode should be resolved first, is a decision for the
driving work rather than a defect to fix here.

### B4 — Manager-side credential expiry interrupts supervision

Distinct from in-pod token expiry. During this investigation the local
`gcloud` token expired between two commands six minutes apart, after which
every `kubectl` call against the cluster failed
(`gke-gcloud-auth-plugin` → `Reauthentication failed. cannot prompt during
non-interactive execution`). Recovery required an interactive
`gcloud auth login`, which an agent cannot complete unattended.

The session pod is unaffected — it keeps running. What breaks is the
supervising side: `ompctl`, `kubectl exec`, link retrieval, and any polling
loop. A run supervised across a multi-hour phase will hit this. Related but
separate: AWS SSO tokens inside the pod live 8–12 h with no auto-refresh on the
default exec path (`docs/planning/credential-auth-flows.md:231-233`);
`spec.authBroker` addresses provider refresh for the model credential but not
the AWS SSO session used by `terraform`/`aws`.

Worth documenting at minimum, so an operator plans around it (re-auth before
starting a long phase; prefer collab, which does not depend on the manager's
Google credentials, over `kubectl exec` polling for check-back).

## Out of scope here

- Any change to the `bootc-e2e-test` skill itself; it lives in `bootc-mirantis`.
- Fixing the product defects the e2e run exists to find (e.g. the
  `mirantis/ucp upgrade checks` storage-driver blocker).
