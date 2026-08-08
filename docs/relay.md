# Self-hosted collab relay

Every session's collab traffic (`/collab`, `omp join`) routes through a relay we run
ourselves on the cluster, not the public `wss://my.omp.sh`. This is the cluster-wide
**default** — no per-session opt-in is needed.

## Why

The public relay can be unreachable from a given network (DNS sinkhole / security
filter interception, corporate proxy, outage) with no way for us to fix it. Running
our own relay on a plain GCP static IP puts availability under our control and keeps
collab traffic off third-party infrastructure entirely.

## What it is

- A single-replica Deployment (`omp-relay`, `omp-system`) vendoring the upstream omp
  collab-relay room-routing contract (`relay/relay.ts` + `relay/link.ts`) — it blindly
  routes sealed ciphertext frames between a session (host) and its guests; it never
  sees plaintext.
- Fronted by a `LoadBalancer` Service pinned to a **reserved static IP**
  (`infra/main.tf` → `google_compute_address.relay`; current value:
  `terraform output relay_ip` from `infra/`), reachable at `<ip>.sslip.io` — sslip.io
  resolves that hostname to the embedded IP with no DNS record to manage.
- TLS via a real **Let's Encrypt** certificate (a `certbot` sidecar container issues
  and renews it on a shared PVC, HTTP-01 challenge served on port 80); no self-signed
  cert, no client-side trust config needed.
- Rooms are in-memory — **never scale this Deployment beyond 1 replica.**

## Provisioning (administrator)

Controlled by three Terraform variables in `infra/terraform.tfvars`:

```hcl
self_relay_enabled = true
self_relay_email   = "you@example.com"   # Let's Encrypt account/expiry email
```

The static IP (`google_compute_address.relay`) is created unconditionally by
`terraform apply`; the Deployment/Service/PVC only render when `self_relay_enabled`
is true (`charts/omp-platform/templates/relay-*.yaml`, gated on `.Values.selfRelay.enabled`).

```bash
cd infra && terraform apply
terraform output relay_ip   # the reserved static IP
```

If the chart-only templates change without a Terraform value change (e.g. editing
`relay/relay.ts` or a `relay-*.yaml` template), `terraform apply` reports "no
changes" — Terraform doesn't hash chart file contents. Force it directly instead:

```bash
helm get values omp-platform -n omp-system -o yaml > /tmp/values.yaml
helm upgrade omp-platform charts/omp-platform -n omp-system -f /tmp/values.yaml
kubectl -n omp-system rollout restart deployment/omp-relay      # relay.ts changes
kubectl -n omp-system rollout restart deployment/omp-operator   # operator.py changes
```

The relay image itself is built and pushed by CI (`build-images.yml` /
`daily-rebuild.yml`, context `relay/`) like `omp-session`/`omp-operator` — a rollout
restart re-pulls `:latest` (`imagePullPolicy: Always`).

## How sessions pick it up

`collab.relayUrl` is set to the self-hosted relay in every `omp-config*` ConfigMap
(the Helm-templated base and the three manually-applied model profiles under `k8s/`).
This is enough for a **brand-new** session with no prior collab history.

It is **not** enough on its own for an existing session: a resumed session (`omp -c`,
used on every restart per `docker/entrypoint.sh`) restores its own previously-used
collab-relay preference from its session state and ignores the config default. The
durable fix lives in the **operator**: `OMP_SELF_RELAY` (wired from
`.Values.selfRelay.host`, set on the `omp-operator` Deployment) makes
`_tmux_capture_join_link` in `operator/session_operator.py` send an explicit
`/collab wss://<relay>` instead of a bare `/collab` in every automatic hosting path —
initial reconcile, the `collab_healthcheck` timer's post-crash re-host, and the
recapture-handler's tmux fallback. This is safe because both automatic call sites
only host when there is no active room to conflict with.

**A session already hosting on the wrong relay will not switch on its own** — sending
`/collab wss://<relay>` while a room is already active on a different relay is a
no-op (it just reprints the current status). To force a switch: `/collab stop` then
`/collab wss://<relay>` from a chat prompt, or restart the pod (`ompctl session
restart NAME`) so the automatic re-host path — which now always uses the explicit
relay — runs against a genuinely-down room.

## Verifying it's healthy

```bash
HOST=$(cd infra && terraform output -raw relay_ip).sslip.io

# Health endpoint (plain HTTP, port 80 — not the wss room-routing port)
curl -sS -o /dev/null -w '%{http_code}\n' "http://$HOST/healthz"   # expect 200

# Certificate issuer and expiry
echo | openssl s_client -connect "$HOST:443" -servername "$HOST" 2>/dev/null \
  | openssl x509 -noout -issuer -dates                             # expect O = Let's Encrypt

kubectl -n omp-system get pod -l app=omp-relay                     # expect 2/2 Running
kubectl -n omp-system logs deploy/omp-relay -c certbot --tail=20   # renewal loop status
```

`https://$HOST/healthz` (not `http://`) returns `404` — that's expected, it hits the
room-routing port (8443), which only answers `/r/<roomId>` upgrade requests.

## Troubleshooting

- **`TLS handshake failed` joining a link.** First suspect: is the relay actually
  reachable from the joining machine? Check for network-level interception:
  ```bash
  echo | openssl s_client -connect <host>:443 -servername <host> 2>/dev/null \
    | openssl x509 -noout -issuer
  ```
  If the issuer is anything other than `Let's Encrypt` (e.g. a corporate/DNS-filter
  CA — seen in practice: `Whalebone Sinkhole CA`), the relay's hostname is being
  intercepted by a network security filter on the joining machine's network, not a
  relay problem. Try from a different network, or route around the filter.
- **`Error: Failed to join collab session: protocol mismatch: host speaks vX, guest
  sent vY`.** The relay only carries bytes — this is a client/host **omp version**
  mismatch, unrelated to the relay. Match the joining client's `omp --version` to the
  session pod's (`kubectl exec -n omp-session-NAME omp-0 -c omp -- omp --version`).
  Collab protocol versions are not strictly tied to semver the way you'd expect —
  test the exact versions rather than assuming "latest" on both ends matches.
- **Cert renewal / hot-reload.** `relay.ts` watches the cert file and calls
  `server.reload({ tls })` on change; if that throws (`server.reload({tls})`
  unsupported on the current Bun build — a real, observed failure mode, not
  hypothetical), it falls back to `process.exit(0)`, and the Deployment restarts the
  pod, which boots with the already-renewed cert from the PVC. A single relay-pod
  restart around each renewal (~60-day cadence) is expected behavior, not a bug —
  it briefly drops any active rooms.
- **A long-idle session drops its connection** ("Collab relay connection lost,
  reconnecting" on the host; "room closed" for a guest). Fixed by `idleTimeout: 0` in
  `relay/relay.ts` — Bun's automatic WebSocket pings don't reliably reset its default
  120s idle-close (a known Bun issue, oven-sh/bun#26554), and the setting is
  uint8-capped at 255s regardless, too short for a real agent turn with no guest
  traffic. If this recurs, confirm the deployed relay image actually has the fix
  (`kubectl -n omp-system get pod -l app=omp-relay -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'`
  and compare against the latest `omp-relay` build).
