# Darlane — In-Cluster Developer Environment

Darlane is a platform-provisioned parallel deployment running alongside your production application inside the same Kubernetes namespace. It shares the same
infrastructure — Vault secrets, database connections, monitoring, logging, service mesh — with zero configuration required from the developer.

**Darlane is not a sandbox.** It does not simulate, mock, or duplicate production infrastructure. It is a second lane inside the real cluster, already wired to
everything your application needs, scaled to zero at rest.

---

**Table of Contents**
- [Darlane — In-Cluster Developer Environment](#darlane--in-cluster-developer-environment)
  - [Why this is different](#why-this-is-different)
  - [Darlane vs. `kubectl debug` / ephemeral containers](#darlane-vs-kubectl-debug--ephemeral-containers)
    - [What `kubectl debug` actually does](#what-kubectl-debug-actually-does)
    - [The fundamental difference](#the-fundamental-difference)
    - [Capability comparison](#capability-comparison)
    - [When `kubectl debug` is the right call](#when-kubectl-debug-is-the-right-call)
    - [When Darlane is the right call](#when-darlane-is-the-right-call)
    - [The underlying reason Darlane was introduced](#the-underlying-reason-darlane-was-introduced)
  - [How it works](#how-it-works)
  - [Quickstart](#quickstart)
  - [Developer workflows](#developer-workflows)
    - [1 — Exec and debug](#1--exec-and-debug)
    - [2 — File sync and hot reload (AI-era development)](#2--file-sync-and-hot-reload-ai-era-development)
    - [3 — Traffic mirroring (mirrord)](#3--traffic-mirroring-mirrord)
    - [4 — Traffic interception (Telepresence)](#4--traffic-interception-telepresence)
  - [A/B testing and feature flags](#ab-testing-and-feature-flags)
    - [Sticky sessions](#sticky-sessions)
    - [Header routing](#header-routing)
    - [Combining traffic modes](#combining-traffic-modes)
    - [Adding mirrord to the mix](#adding-mirrord-to-the-mix)
    - [Feature flags](#feature-flags)
    - [Honest trade-offs vs. dedicated flag services](#honest-trade-offs-vs-dedicated-flag-services)
  - [Combined workflow patterns](#combined-workflow-patterns)
    - [Pattern A — Feature flag / A/B test (manifest-only, no laptop required)](#pattern-a--feature-flag--ab-test-manifest-only-no-laptop-required)
    - [Pattern B — Local code handles real users (trafficWeight + mirrord steal)](#pattern-b--local-code-handles-real-users-trafficweight--mirrord-steal)
    - [Pattern C — Observe real traffic locally (mirrord mirror, read-only)](#pattern-c--observe-real-traffic-locally-mirrord-mirror-read-only)
    - [Pattern D — Code sync to pod (wxops darlane sync + fileSync, in-cluster)](#pattern-d--code-sync-to-pod-wxops-darlane-sync--filesync-in-cluster)
    - [Choosing a pattern](#choosing-a-pattern)
  - [Scenario reference](#scenario-reference)
    - [Tool × scenario matrix](#tool--scenario-matrix)
    - [Scenario playbooks](#scenario-playbooks)
      - [A/B Testing](#ab-testing)
      - [Feature Flags](#feature-flags-1)
      - [Debugging](#debugging)
      - [Canary / Temporary New Feature Delivery](#canary--temporary-new-feature-delivery)
      - [Hotfix / Emergency Patch](#hotfix--emergency-patch)
    - [When to reach outside Darlane entirely](#when-to-reach-outside-darlane-entirely)
  - [AI Agent workflow](#ai-agent-workflow)
  - [SRE Agent — intelligence injector](#sre-agent--intelligence-injector)
  - [Guardian Framework (platform-injected safety)](#guardian-framework-platform-injected-safety)
  - [Access control](#access-control)
  - [Safety model](#safety-model)
  - [Choosing between mirrord and Telepresence](#choosing-between-mirrord-and-telepresence)
  - [TTL enforcement (auto-scale-down)](#ttl-enforcement-auto-scale-down)
    - [XR configuration](#xr-configuration)
    - [How enforcement works](#how-enforcement-works)
    - [Kyverno policies](#kyverno-policies)
    - [Interaction with Crossplane](#interaction-with-crossplane)
  - [What's next: `XDarlane` XRD](#whats-next-xdarlane-xrd)
    - [Why a standalone XRD](#why-a-standalone-xrd)
    - [What `XDarlane` looks like](#what-xdarlane-looks-like)
    - [The agent model](#the-agent-model)
    - [What changes for developers](#what-changes-for-developers)
  - [Prerequisites](#prerequisites)


---

## Why this is different

| Traditional approach | Darlane approach |
|---|---|
| Spin up sandbox namespace + duplicate secrets + clone DB + wire monitoring | `darlane.enabled: true` → done |
| Test a Claude integration locally with a fake API key | Run code inside the cluster pod with the real Vault-injected key |
| Wait 8–15 min CI/CD cycle to test a changed prompt template | Sync file to pod → hot-reload → test in seconds |
| SRE SSHs into prod, guesses at fix, deploys via CI | Agent reads real logs → injects fix into darlane → validates with mirrored traffic → opens PR |

The core insight: **secrets, database connections, and monitoring already exist in the cluster.** Darlane inherits all of it without duplication. The cost is
one extra Deployment at `replicas: 0` most of the time.

---

## Darlane vs. `kubectl debug` / ephemeral containers

`kubectl debug` and ephemeral containers are Kubernetes-native debugging primitives. They are the right tool in specific situations — and the wrong tool for
everything Darlane is designed for. Understanding the difference matters for choosing correctly.

### What `kubectl debug` actually does

```bash
# Attach an ephemeral container to a running production pod
kubectl debug -it deployment/payment-api \
  --image=busybox \
  --target=payment-api

# OR: create a modified copy of the pod
kubectl debug deployment/payment-api \
  --copy-to=payment-api-debug \
  --image=ghcr.io/team/payment-api:debug
```

An ephemeral container is injected **directly into the target pod**. It shares the pod's network namespace (same IP, same sockets), optionally the PID namespace
(can `strace` the production process), and the pod's volumes. It cannot be restarted — if the process exits, the container is gone for the lifetime of that pod.

### The fundamental difference

```
kubectl debug / ephemeral container:
  └─ Injected INTO the production pod
       ├─ Shares PID namespace  → can inspect production process memory, strace it
       ├─ Shares network socket → same IP address as production pod
       ├─ Resource usage        → counts against the production pod's limits
       └─ Lifecycle             → cannot restart; lives until the pod restarts
       ⚠️  You ARE inside production. Anything you do is inside the live pod.

Darlane (<appName>-darlane Deployment):
  └─ Separate pod, separate lifecycle
       ├─ Own PID namespace     → cannot see production process
       ├─ Same cluster network  → reaches the same Services, DNS, endpoints
       ├─ Same Vault secrets    → DATABASE_URL, API keys, all credentials present
       └─ Own resource limits   → OOM in darlane does not OOM production
       ✅  Production pod is untouched. You operate a twin, not the original.
```

### Capability comparison

| Capability | `kubectl debug` / ephemeral | Darlane |
|---|---|---|
| Isolation from production process | ❌ Same pod, shared namespaces | ✅ Separate Deployment |
| Restart if process crashes | ❌ Ephemeral containers cannot restart | ✅ Standard pod restart policy |
| Hot-reload on code change | ❌ Image is fixed at injection time | ✅ `fileSync` + hot-reload command |
| Layer debug env on top of prod env | ❌ No mechanism | ✅ `darlane.env` wins on key collision |
| Traffic routing — A/B, canary | ❌ Not possible | ✅ `trafficWeight` + Traefik split |
| Scoped access without prod pod exec | ❌ Requires `pods/exec` on production pods | ✅ Dedicated `ServiceAccount` — bind your own `Role` to it |
| Declarative, versioned, auditable | ❌ Ad-hoc `kubectl` command | ✅ XR in git — visible in PR diffs |
| TTL / auto-cleanup | ❌ Lives until the pod restarts | ✅ Kyverno `ClusterCleanupPolicy` |
| mirrord traffic mirroring | ❌ No integration path | ✅ Target `<appName>-darlane` from CLI |
| Inspect production process memory | ✅ PID namespace sharing | ❌ Separate PID namespace by design |
| Postmortem: inspect crashed pod state | ✅ `--copy-to` preserves crashed state | ❌ Darlane is a running twin, not a snapshot |

### When `kubectl debug` is the right call

Darlane does not replace ephemeral containers for their core use case. Use `kubectl debug` when:

| Situation | Why ephemeral is right |
|---|---|
| Production pod is misbehaving RIGHT NOW and you need its exact process state | Need PID sharing to `strace`, inspect `/proc`, or attach a profiler to the running process |
| Postmortem: pod OOMKilled or crash-looping | `kubectl debug --copy-to` preserves the exact crashed state for inspection |
| You need to `strace` or `perf` the production process | Requires PID namespace sharing — only possible with ephemeral containers |
| Cluster access is locked down (no new Deployments allowed) | Ephemeral containers require only `pods/exec` on the target pod |

### When Darlane is the right call

| Situation | Why Darlane is right |
|---|---|
| Iterating on code with real secrets and a real database | Isolated, restartable, hot-reload, no production impact |
| Testing a feature with real traffic (A/B, canary, feature flag) | `trafficWeight` routes real users; production pod untouched |
| Debugging a bug by reproducing it with real traffic shapes | mirrord mirror — read-only, zero production risk |
| AI agent needs a reproducible, safe execution target | Declarative XR, scoped RBAC, automatic cleanup |
| SRE needs to validate a hotfix before promoting it | Mirror real traffic against the fix in a separate pod; promotes only when validated |
| Session needs an audit trail | XR in git, Kyverno TTL log, optional Guardian audit sidecar |

### The underlying reason Darlane was introduced

`kubectl debug` and `kubectl exec` into production both require you to enter the production pod or a container that is part of it. Every action you take is
inside the blast radius of a production workload: a memory-intensive operation risks an OOM that kills real user requests, a network call is made from a
production identity, a filesystem write is inside a production container.

The problem Darlane solves is different: **how do you get all the context of production (secrets, database, network, real traffic) without being inside
production?**

A separate Deployment with the same `envFrom`, `secretsFrom`, and network identity answers that question. The darlane pod is wired to the same infrastructure
but is independently scheduled, independently resourced, and carries no production request-handling responsibility — unless you explicitly opt in with
`trafficWeight`.

That's the design choice: isolation by default, access to production context by inheritance, production traffic routing only when explicitly declared.

---

## How it works

When `darlane.enabled: true`, the platform composes a second `<appName>-darlane` Deployment in the same namespace as your production app:

- **`replicas: 0` by default** — zero cost at rest, scale up on demand
- **No `Service` or `Ingress`** — zero external exposure unless you opt in
- **Inherits `env`, `envFrom`, `secretsFrom`** — same Vault secrets, same database
  credentials, same environment configuration
- **Same network identity** — reaches all in-namespace Services and cluster-internal
  endpoints exactly as the production pod does
- **Observable** — same logging stack, same Prometheus metrics, same tracing

```yaml
spec:
  parameters:
    appName: payment-api
    namespace: team-alpha
    image: ghcr.io/team-alpha/payment-api:1.4.2
    secretsFrom:
      app:
        enabled: true       # Vault-backed secret already mounted in prod
      database:
        enabled: true       # DB creds already mounted in prod

    darlane:
      enabled: true         # parallel pod, same secrets, zero external exposure
      replicas: 0           # scale up on demand
      command: ["uvicorn", "main:app", "--reload", "--host", "0.0.0.0"]
```

---

## Quickstart

```bash
# 1. Scale up darlane — patch the XR (Crossplane is the source of truth;
#    kubectl scale is overwritten on every reconcile cycle)
kubectl patch xtenantapp <xr-name> \
  --type='merge' \
  -p '{"spec":{"parameters":{"darlane":{"replicas":1}}}}'

# 2. Watch it start with the same env as prod
kubectl -n team-alpha logs -f deployment/payment-api-darlane

# 3. Exec in — real secrets, real DB, real network. No config.
kubectl -n team-alpha exec -it deployment/payment-api-darlane -- bash

# 4. Scale back down when done — patch the XR again
kubectl patch xtenantapp <xr-name> \
  --type='merge' \
  -p '{"spec":{"parameters":{"darlane":{"replicas":0}}}}'
```

> **Why not `kubectl scale`?** The darlane Deployment is Crossplane-managed. `kubectl scale` is a temporary override — the next Crossplane reconcile cycle
> (every ~30–60 seconds) resets replicas back to whatever `darlane.replicas` says in the XR. Always patch the XR to make the change persist.

---

## Developer workflows

### 1 — Exec and debug

The simplest use case. Scale the pod up, exec in, and interact with the running application in a real environment.

```bash
kubectl -n <namespace> exec -it deployment/<appName>-darlane -- bash

# Inside the pod: real secrets are in the environment
echo $ANTHROPIC_API_KEY       # Vault-injected, present already
psql $DATABASE_URL            # real DB connection, no config

# Run a one-off test against real infrastructure
python scripts/test_rag_pipeline.py
```

Useful for: quick inspection, running migration checks, verifying environment configuration, ad-hoc testing.

### 2 — File sync and hot reload (AI-era development)

For iterative development — especially AI integrations where the feedback loop must be seconds, not minutes.

**How it works:**

```
Edit code locally → sync to pod → hot-reload triggers → test with real data
```

**Platform side** (compose in `darlane`):
```yaml
darlane:
  enabled: true
  command: ["uvicorn", "main:app", "--reload"]  # or nodemon, air, watchmedo
  fileSync:
    enabled: true      # emptyDir volume at mountPath, writable regardless of
    mountPath: /app    # main app's readOnlyRootFilesystem setting
```

**Developer side** — use `wxops darlane sync` for continuous sync:

```bash
# Watch ./src and stream changes into the pod's /app
wxops darlane sync payment-api --local ./src --remote /app

# Exclude build artefacts and logs
wxops darlane sync payment-api --local ./src --exclude '*.log' --exclude '__pycache__/'

# Target a different environment (default: dev)
wxops darlane sync payment-api --env staging

# Files stream on every save (~100 ms debounce). Pod hot-reloads automatically.
# ANTHROPIC_API_KEY is already in the pod — no export, no .env file.

# Ctrl+C to stop sync
```

**Why this matters for AI development specifically:**

When iterating on prompt templates, RAG pipeline configuration, Claude tool definitions, or agent decision trees, you need real data and real API keys. A local
mock is insufficient; a full CI/CD cycle is too slow.

```
Change prompt template locally
  → wxops darlane sync streams the change (~100 ms debounce)
  → uvicorn --reload picks it up
  → pod sends real API request with real ANTHROPIC_API_KEY
  → real response in the logs
  → iterate again
```

The entire loop takes 3–5 seconds. The same change via CI/CD takes 8–15 minutes.

### 3 — Traffic mirroring (mirrord)

Mirror real production traffic into the darlane pod. Your code handles actual requests — without affecting the production pod or real users.

```bash
# Mirror traffic from the main Deployment to the darlane pod
# Your local process runs with the pod's environment (secrets included)
mirrord exec \
  --target deployment/payment-api-darlane \
  --target-namespace team-alpha \
  -- uvicorn main:app --reload
```

mirrord copies incoming requests to both the production pod and your process. The production pod still handles real users. You observe real request patterns,
real payloads, real edge cases — without any user seeing your changes.

**Modes:**

| Mode | Command | Effect |
|---|---|---|
| Mirror (default) | `mirrord exec --target ...` | Traffic copied to your process; prod unaffected |
| Steal | `mirrord exec --steal --target ...` | Traffic redirected to your process; use with care |

Mirror mode is safe in all environments. Steal mode on production requires `darlane.productionOverride: true` in the XR (double-opt-in, auditable).

### 4 — Traffic interception (Telepresence)

Full tunnel: your local process gets the pod's network identity and handles all traffic routed to the darlane pod.

```bash
telepresence connect --namespace <namespace>

telepresence intercept <appName>-darlane \
  --port <containerPort>:<containerPort> \
  --namespace <namespace>

# Optional: extract env vars to a local .env file instead of full intercept
telepresence intercept <appName>-darlane \
  --port <containerPort>:<containerPort> \
  --namespace <namespace> \
  --env-file .env.local
```

Telepresence is heavier (requires a cluster-side Traffic Manager) but gives you full network identity — useful when you need to test service-to-service calls
that originate from the pod's identity, not your laptop's.

---

## A/B testing and feature flags

When `darlane.trafficWeight` is set, the platform composes a `Service` for the darlane pod and a Traefik `TraefikService` weighted split between the production
Deployment and the darlane Deployment.

```yaml
darlane:
  enabled: true
  trafficWeight: 10    # route 10% of real traffic to darlane pod
```

This creates a three-mode spectrum via a single parameter:

| `trafficWeight` | Mode | Use case |
|---|---|---|
| `0` (default) | Off — darlane has no Service | Debug only, no external traffic |
| `1–99` | A/B split — real users reach darlane | Feature validation, performance comparison |
| `100` | Full canary — all traffic to darlane | Pre-promotion validation |

### Sticky sessions

By default `trafficWeight` distributes each request independently — a single user can hit both backends within the same session. For A/B tests this produces
noise: the same user sees both variants, and any stateful flow (cart, auth token, multi-step form) can break mid-session.

Enable `stickySession` to pin each client to one backend for the session lifetime. Traefik sets a session cookie on the first response; every subsequent request
from that browser is routed to the same backend.

```yaml
darlane:
  enabled: true
  trafficWeight: 20
  stickySession:
    enabled: true        # pin users to variant A or B for the session
    cookieName: darlane-ab   # override if multiple apps share the same domain
    secure: true         # Secure flag — HTTPS only (default)
    sameSite: lax        # lax | strict | none
```

**When to enable sticky sessions:**

| Scenario | Sticky needed? |
|---|---|
| A/B test — user must see one variant consistently | **Yes** |
| Feature flag — user must not toggle between flag states | **Yes** |
| Canary validation — aggregate error rate check | No — per-request is fine |
| Full canary (`trafficWeight: 100`) | No — all traffic goes to darlane |

**Browser clients only.** API clients that do not forward cookies (mobile SDKs, service-to-service calls, CLI tools) remain per-request regardless of this
setting. For API-client A/B testing, use a dedicated feature flag service with SDK-level targeting instead.

### Header routing

Send a specific HTTP header and every request goes directly to the darlane pod — no cookie, no session state, no random traffic spill. Works with
`trafficWeight: 0` (zero production impact) or alongside a weighted canary.

```yaml
darlane:
  enabled: true
  trafficWeight: 0   # 0 = no random traffic; combine with any weight 1–99 if needed
  headerRouting:
    enabled: true
    header: X-Target-Env   # case-sensitive
    value: darlane         # case-sensitive
```

```bash
curl -H "X-Target-Env: darlane" https://payment-api.example.com/api/checkout
```

The darlane `ClusterIP` Service is always emitted when header routing is active, independent of `trafficWeight`.

**How the routing is implemented:**

The composition emits **two separate `IngressRoute` objects** with fully explicit priorities. Same-IngressRoute priority handling is unreliable in Traefik when
routes mix `TraefikService` and plain `Service` backends — separate objects with explicit integers avoid that entirely:

```
IngressRoute: payment-api          priority: 1   (fallback — no header)
  Host(`…`) && PathPrefix(`/`)
  → TraefikService weighted split or main app

IngressRoute: payment-api-darlane  priority: 100 (wins when header present)
  Host(`…`) && PathPrefix(`/`) && Header(`X-Target-Env`, `darlane`)
  → payment-api-darlane Service
```

Traefik v3 uses `Header()` (singular) — not `Headers()`. Using `Headers()` produces an `unsupported function` parse error and drops the route silently.

Per the [Traefik priority documentation](https://doc.traefik.io/traefik/reference/routing-configuration/http/routing/rules-and-priority/#priority-calculation),
default priority equals rule string length, evaluated descending. `100 > 1` is a plain integer comparison — no length calculation, no ambiguity. See also:
[Traefik Weighted Round Robin](https://oneuptime.com/blog/post/2026-02-09-traefik-weighted-round-robin/view) for how separate IngressRoute priorities interact
with weighted splits.

### Combining traffic modes

`trafficWeight`, `stickySession`, and `headerRouting` are independent and compose freely. The table below shows the most useful combinations:

| `trafficWeight` | `stickySession` | `headerRouting` | Behaviour |
|---|---|---|---|
| `0` | — | disabled | Debug only — no external traffic reaches darlane. |
| `0` | — | enabled | **Explicit opt-in only.** Requests with the header go to darlane; everyone else hits the main app. No random traffic spill. Good for internal QA without affecting users. |
| `20` | disabled | disabled | **Raw A/B split.** Each request is independently 80/20 — the same user may see both versions within a session. |
| `20` | enabled | disabled | **Cohort A/B.** Traefik cookie pins browser sessions to one variant for the session lifetime. Required for a valid A/B measurement. |
| `20` | enabled | enabled | **Cohort A/B + developer escape hatch.** Normal traffic splits with stickiness. Any request carrying the header bypasses both the split and the cookie assignment — goes directly to darlane regardless. Useful for QA opt-in alongside a live canary. |
| `100` | — | disabled | **Full canary.** All traffic goes to darlane. |

**The composition rule:**

`headerRouting` adds a second, higher-priority route to the `IngressRoute`. `trafficWeight` controls what the lower-priority catch-all route points to. They are
layered, not mutually exclusive — the header route wins first; everything else falls through to the weight.

### Adding mirrord to the mix

mirrord is a session-bound CLI tool — it runs on the developer's machine and mirrors or steals traffic at the pod level without changing any XR parameter. It
layers on top of the manifest controls to unlock case studies that neither side can cover alone.

| Traffic config | mirrord mode | Target | What you get |
|---|---|---|---|
| `trafficWeight: 0` | `mirror` | `<appName>-darlane` | **Silent observer.** Production traffic is copied to your local process read-only. Darlane pod is running; prod completely untouched. Safe in any environment. |
| `trafficWeight: 0` | `mirror` | `<appName>` | **Direct production tap.** No darlane as a traffic sink — copy straight from the main Deployment. Observe real request shapes without touching a single resource. |
| `trafficWeight: 0` + `headerRouting` | `steal` + `--filter` | `<appName>-darlane` | **Scoped developer steal.** The header gates which requests reach darlane at the Ingress; `--filter` narrows to only those at the pod. Two independent guards. QA sends the header; their requests reach your local code. Everyone else stays on the main app. |
| `trafficWeight: 20` + `stickySession` | `mirror` | `<appName>-darlane` | **Observe the canary cohort.** Cohort B users land on darlane (cookie-pinned); your local process receives read-only copies of their requests. Darlane pod still serves responses — you only watch. |
| `trafficWeight: 20` + `stickySession` | `steal` | `<appName>-darlane` | **Live canary served locally.** Darlane's 20% share is stolen to your laptop. Cohort B users are now served by your local process. Iterate code; real responses go back to real users. |
| `trafficWeight: 100` | `mirror` | `<appName>-darlane` | **Full canary observation.** All traffic lands on darlane; you mirror it locally for debugging while the pod handles all responses. |

**The safest steal pattern — header filter as a double guard:**

```bash
# headerRouting gates at the Ingress; --filter gates at the pod.
# Only the opt-in header requests ever reach local code.
mirrord exec \
  --target deployment/<appName>-darlane \
  --target-namespace <namespace> \
  --steal \
  --filter "X-Target-Env: darlane" \
  -- uvicorn main:app --reload
```

With `headerRouting.header: X-Target-Env` active in the XR, only requests carrying that header reach the darlane pod at the Ingress level. mirrord's `--filter`
then narrows further at the pod level. Production users never touch local code — even if the `--filter` flag is accidentally omitted.

### Feature flags

The darlane Deployment inherits `env` and `envFrom` from the main app, but you can layer `darlane.env` on top to enable flags that differ from production:

```yaml
darlane:
  trafficWeight: 20
  stickySession:
    enabled: true
  env:
    - name: FEATURE_NEW_RANKING
      value: "true"
    - name: LOG_LEVEL
      value: debug
```

20% of real users are pinned to the darlane pod with the new ranking enabled. Metrics come from the same Prometheus stack. No feature flag service required.

> **Caution:** darlane with `trafficWeight > 0` carries the same responsibility as a canary deployment. If the darlane pod crashes, that percentage of traffic
> drops. This is a developer-controlled tool for validation — not a replacement for a production traffic-splitting strategy (use ArgoCD Rollouts for that).

### Honest trade-offs vs. dedicated flag services

Darlane's traffic controls are **not** a replacement for a mature feature flag SDK or A/B testing platform. We are honest about that.

**Where Darlane genuinely wins:**

- No SDK, no code change — toggle via env var or image tag in the XR; works for any language
- GitOps audit trail — flag state lives in git, visible in PR diffs and review
- Real infrastructure — the pod has real Vault secrets and DB connections, not a simulation
- Pod-level fault isolation — a darlane crash only affects the routed percentage

**Where a dedicated service wins — and you should use one:**

- **Per-user targeting** — Darlane is per-pod. If you need to target a specific user ID,
  plan tier, or cohort, Darlane cannot do that. Use [Unleash](https://github.com/Unleash/unleash)
  (self-hosted) or [Flagsmith](https://github.com/Flagsmith/flagsmith) (self-hosted).
- **Statistical experiment analysis** — Darlane routes traffic; it does not track
  conversion, significance, or variant attribution. Use [GrowthBook](https://github.com/growthbookio/growthbook)
  (open source) for that layer.
- **Real-time toggle** — SDK flag flips are instant. A Darlane `trafficWeight` change
  requires a Crossplane reconcile (~30 s).
- **Cookie-less stickiness** — `stickySession` only works for browser clients that
  forward cookies. API clients, mobile SDKs, and service-to-service calls remain
  per-request regardless.
- **Scale** — Darlane is a single pod with no autoscaler. It is not designed to carry
  a large percentage of production traffic long-term.

Use Darlane for the **developer inner loop**: pre-PR validation, QA opt-in, short-lived canaries measured in hours. When a flag needs to run at production scale
with user-segment targeting and statistical rigour, reach for a dedicated SDK. The two are complementary — they solve different parts of the problem.

---

## Combined workflow patterns

The manifest (XR parameters) and the developer tool layer (mirrord, wxops darlane sync) are independent — each works on its own, but they compose into four
patterns that cover the majority of developer and SRE workflows.

```
XR manifest (always active, Crossplane-reconciled):
  darlane.env           → env vars the darlane pod carries
  darlane.trafficWeight → % of real Ingress traffic routed to darlane pod
  darlane.stickySession → browser sessions pinned to one backend via cookie
  darlane.headerRouting → explicit caller opt-in via request header (bypasses weight)
  darlane.fileSync      → writable emptyDir volume for code sync

Developer tool layer (session-bound, active while developer is present):
  mirrord exec --target ...           → mirror mode (default) — read-only copy of traffic, prod unaffected
  mirrord exec --target ... --steal   → steal mode — intercepts darlane's traffic share to local process
  mirrord exec --target ... --steal --filter "Header: value"  → scoped steal, narrows to matching requests
  wxops darlane sync <service>        → watch local files and stream changes into the darlane pod
```

The XR is always active. The tool layer is optional and session-scoped.

---

### Pattern A — Feature flag / A/B test (manifest-only, no laptop required)

The darlane pod in the cluster handles the routed traffic. No developer present needed. Runs continuously after a single XR patch.

**Data flow:**
```
Ingress (Traefik)
  ├── 80% → main app Service → production pods   (untouched)
  └── 20% → darlane Service → darlane pod      (handles this share directly)
```

**XR:**

```yaml
darlane:
  enabled: true
  replicas: 1
  env:
    - name: FEATURE_NEW_CHECKOUT
      value: "true"          # env flag — wins over main app env on key collision
  # OR: image variant for A/B
  # image: ghcr.io/team/payment-api:variant-b
  trafficWeight: 20          # 20% of real Ingress traffic → darlane pod
  stickySession:
    enabled: true            # users pinned to their backend for the session
    cookieName: darlane-ab
  ttl: "8h"
```

```bash
kubectl patch xtenantapp payment-api --type=merge \
  -p '{"spec":{"parameters":{"darlane":{"replicas":1}}}}'
# No further action needed — darlane pod handles its traffic share autonomously
```

**When to use:** Feature flag for a percentage of users, A/B test running overnight, canary validation without a developer at their laptop.

---

### Pattern B — Local code handles real users (trafficWeight + mirrord steal)

The manifest routes a slice of Ingress traffic to the darlane pod. mirrord steals that slice and delivers it to your local process. Your local code handles real
user requests and serves responses — no image build, no restart, instant iteration.

**Data flow:**
```
Ingress (Traefik)
  ├── 80% → production pods    (untouched)
  └── 20% → darlane pod
               │
          mirrord steal (CLI)
               │
               ▼
         Local process          ← your new code, runs on laptop
         (darlane env: DATABASE_URL, ANTHROPIC_API_KEY, all Vault secrets)
         (darlane network: psql postgres-service:5432 works directly)
               │
               ▼
         Response → back to the 20% of real users
```

**XR (set once, stays active):**

```yaml
darlane:
  enabled: true
  replicas: 1
  trafficWeight: 20
  stickySession:
    enabled: true            # users stay on their backend — valid A/B, no toggling
    cookieName: darlane-ab
  ttl: "4h"
```

**Developer CLI (per session):**

```bash
mirrord exec \
  --target deployment/payment-api-darlane \
  --target-namespace team-alpha \
  --steal \
  -- uvicorn main:app --reload
```

Your local process inherits the darlane pod's complete environment — not just env vars, but the full network identity. `DATABASE_URL` resolves AND connects. You
reach `postgres-service:5432` directly as if your laptop is inside the cluster.

`Ctrl+C` exits mirrord. The darlane pod resumes handling that 20% with its base image.

**When to use:** Iterating on a feature where you need real user traffic and real production data, but aren't ready to build an image. Fastest possible inner
loop.

---

### Pattern C — Observe real traffic locally (mirrord mirror, read-only)

Your local process receives copies of real traffic. It runs your code, logs output, processes requests — but its responses are discarded. The production pod
handles every user normally. Zero risk to real users.

**Data flow:**
```
Production pod → handles all real users (responses go to users, unaffected)
      │
 mirrord mirror (read-only copy — your process receives, never responds)
      │
      ▼
Local process   ← your code branch, runs on laptop
(darlane env + network inherited via mirrord agent)
(responses discarded — real users only see production response)
```

**XR (add debug env to darlane so the mirrord session gets richer observability):**

```yaml
darlane:
  enabled: true
  replicas: 1
  env:
    - name: LOG_LEVEL
      value: debug
    - name: OTEL_TRACES_SAMPLER
      value: always_on
    - name: OTEL_TRACES_SAMPLER_ARG
      value: "1"
  ttl: "4h"
```

**Developer CLI — target darlane pod (debug env, production pod completely untouched):**

```bash
mirrord exec \
  --target deployment/payment-api-darlane \
  --target-namespace team-alpha \
  -- uvicorn main:app --reload
```

**Developer CLI — target production pod directly (production env, still read-only):**

```bash
# Mirror mode is always safe — even when targeting production directly
mirrord exec \
  --target deployment/payment-api \
  --target-namespace team-alpha \
  -- uvicorn main:app --reload
```

No `trafficWeight` needed — you are not routing users to darlane. You are a silent listener receiving copies of traffic that the production pod handles
normally.

**When to use:** Reproducing a bug with real traffic shapes, debugging a performance issue with real payloads, validating a fix against real request patterns
before opening a PR.

---

### Pattern D — Code sync to pod (wxops darlane sync + fileSync, in-cluster)

Code runs inside the darlane pod (not locally). `wxops darlane sync` continuously syncs your local `./src` into the pod's `/app`. The pod hot-reloads on each
change. Combine with `trafficWeight` to serve real users from the pod.

**Data flow:**
```
Local ./src
    │
wxops darlane sync payment-api --local ./src (~100 ms debounce)
    │
    ▼
darlane pod /app      ← your code runs here, inside the cluster
    │
uvicorn --reload       ← restarts automatically on file change
    │
    ▼
(optional) trafficWeight: 5 → real users reach the pod
```

**XR:**

```yaml
darlane:
  enabled: true
  replicas: 1
  command: ["uvicorn", "main:app", "--reload"]
  fileSync:
    enabled: true
    mountPath: /app
  env:
    - name: LOG_LEVEL
      value: debug
  trafficWeight: 5     # optional — remove if testing via port-forward only
  ttl: "8h"
```

**Developer CLI:**

```bash
# Scale up the darlane pod
kubectl patch xtenantapp payment-api --type=merge \
  -p '{"spec":{"parameters":{"darlane":{"replicas":1}}}}'

# Get pod name
POD=$(kubectl -n team-alpha get pods \
  -l app.kubernetes.io/name=payment-api,app.kubernetes.io/component=darlane \
  -o jsonpath='{.items[0].metadata.name}')

# Watch local ./src and stream changes into the pod's /app
wxops darlane sync payment-api --local ./src --remote /app

# Watch logs — hot-reload fires automatically on every file save
kubectl -n team-alpha logs -f deployment/payment-api-darlane

# Ctrl+C to stop sync, then scale down
kubectl patch xtenantapp payment-api --type=merge \
  -p '{"spec":{"parameters":{"darlane":{"replicas":0}}}}'
```

**When to use:** AI agent workflows (agent syncs code, doesn't need a local mirrord session), testing code that must run inside the cluster network, validating
with real users while maintaining a persistent in-cluster process.

---

### Choosing a pattern

| Goal | Pattern | Key tools |
|---|---|---|
| Feature flag or A/B test, no laptop needed | **A** | XR manifest only |
| A/B test with code still on local machine, instant iteration | **B** | `trafficWeight` + mirrord `--steal` |
| Debug by observing real traffic, prod completely untouched | **C** | mirrord mirror |
| Hotfix: observe first, then route % to validated fix | **C** then **A** | mirrord mirror → `trafficWeight` |
| AI agent injects and tests code changes | **D** | `fileSync` + `wxops darlane sync` |
| Canary: real users, code iterates in pod | **D** | `fileSync` + `wxops darlane sync` + `trafficWeight` |

**The composition rule:** `trafficWeight` routes Ingress traffic to the darlane pod. mirrord `--steal` moves that traffic from the darlane pod to your local
process. They compose: the split is decided at the Ingress by `trafficWeight`; mirrord works inside the darlane pod's share once traffic arrives there.

When you stop mirrord (`Ctrl+C`), the darlane pod resumes handling its traffic share with its base image — production is never involved. Scale
`darlane.replicas` to `0` in the XR when the session is done.

---

## Scenario reference

Five scenarios, five different tool combinations. The matrix below maps each scenario to the Darlane controls that drive it, then calls out where to reach for
something outside Darlane entirely.

### Tool × scenario matrix

The columns are Darlane controls. A cell shows whether a tool is the **primary driver**, plays a **supporting role**, or is **not needed** for that scenario.

| Scenario | `darlane.env` | `fileSync` | `trafficWeight` | mirrord mirror | mirrord steal | `ttl` | `productionOverride` |
|---|---|---|---|---|---|---|---|
| **A/B Testing** | ✅ flag / variant | — | ✅ 1–99% | — | — | ✅ cleanup | ⚠️ if prod |
| **Feature Flag** | ✅ toggle the flag | — | ▸ expose subset | — | — | ✅ | ⚠️ if prod |
| **Debugging** | ✅ LOG + OTEL | ✅ iterate fix | — | ✅ real traffic | — | ✅ session window | ⚠️ if prod |
| **Canary / New Feature** | ▸ if needed | ✅ inject code | ✅ 5% → 100% | — | — | ✅ | ⚠️ if prod |
| **Hotfix / Patch** | ✅ OTEL max | ✅ inject fix | ▸ validate % | ✅ observe | ⚠️ targeted only | ✅ | ✅ required |

✅ primary · ▸ supporting · — not needed · ⚠️ use with explicit intent

---

### Scenario playbooks

#### A/B Testing

Route a percentage of real users to the darlane pod running a different configuration or image variant. Both pods run in the same namespace with the same
infrastructure.

```yaml
darlane:
  enabled: true
  image: ghcr.io/team/payment-api:new-ranking   # variant B image (or same image)
  env:
    - name: RANKING_MODEL
      value: v2                                  # or any env-driven variant switch
  trafficWeight: 20                              # 20% to variant B, 80% to main app
  stickySession:
    enabled: true      # pin users to variant A or B — required for a valid A/B test
    cookieName: darlane-ab
  ttl: "8h"                                      # auto-cleanup after the test window
```

**Risk:** darlane pod is single-replica, no HPA. If it crashes, that 20% of traffic drops until it restarts. Keep `trafficWeight` below 30% for initial
validation.

**What this is not:** not a statistical A/B test framework. Metrics comparison requires your Prometheus/Grafana stack. Darlane routes the traffic; you read the
results.

**Alternative when to reach outside Darlane:**

| Situation | Use instead |
|---|---|
| Test needs to run for days or weeks | ArgoCD Rollouts — weighted canary with automated metric analysis |
| Need user-level split (specific user IDs, cohorts) | Feature flag service (see below) |
| Need automatic rollback on error rate spike | ArgoCD Rollouts analysis |

---

#### Feature Flags

Darlane provides env-based, per-pod feature flags — no feature flag service required. Layer `darlane.env` on top of the main app's env (darlane wins on
collision).

```yaml
darlane:
  enabled: true
  env:
    - name: FEATURE_NEW_CHECKOUT_FLOW
      value: "true"
    - name: FEATURE_RECOMMENDATION_V2
      value: "true"
    - name: LOG_LEVEL
      value: debug                     # extra observability while the flag is hot
  trafficWeight: 10                    # expose to 10% of real users
  stickySession:
    enabled: true      # users in the 10% stay on darlane for their full session
  ttl: "24h"
```

**What this is good for:** quick on/off flags that live in your app's env config. Zero infrastructure — no SDK, no dashboard, no additional service.

**The fundamental limit:** env-based flags are **per-pod, not per-user**. Every request hitting the darlane pod sees the flag enabled — sticky sessions ensure
the same user doesn't toggle between flag-on and flag-off, but you cannot target a specific user ID while leaving everyone else on the default path.

**Alternative when to reach outside Darlane:**

| Situation | Use instead |
|---|---|
| Targeting by user segment, plan tier, or percentage of users | [Unleash](https://www.getunleash.io/) (self-hosted) or [Flagsmith](https://flagsmith.com/) |
| A/B test with statistical significance tracking | LaunchDarkly, GrowthBook |
| Flag that needs to be toggled in real-time without a pod restart | Feature flag service with SDK — env flags require pod restart or hot-reload |

---

#### Debugging

Reproduce a production issue with real traffic and real secrets, without touching the production pod or affecting real users.

**Three-phase loop:**

```
Phase 1 — Reproduce the issue
  fileSync: sync local branch into darlane pod
  darlane.env: LOG_LEVEL=debug + OTEL_TRACES_SAMPLER=always_on
  → Pod hot-reloads, captures full traces, reproduces the error

Phase 2 — Understand with real traffic (mirrord mirror)
  mirrord exec --target deployment/payment-api-darlane -- uvicorn main:app --reload
  → Real production requests copied to local process (read-only)
  → Error appears in local logs with full trace context
  → Production pod unaffected — real users see no change

Phase 3 — Validate the fix
  Edit locally → mirrord delivers next mirrored request → verify error gone
  OR: fileSync syncs fix into pod → pod reloads → observe pod logs
  → Check logs / Prometheus / traces: error resolved → Open PR
```

**XR (manifest side):**

```yaml
darlane:
  enabled: true
  replicas: 1
  command: ["uvicorn", "main:app", "--reload"]
  env:
    - name: LOG_LEVEL
      value: debug
    - name: OTEL_TRACES_SAMPLER
      value: always_on                           # full traces in darlane, low sample in prod
    - name: OTEL_TRACES_SAMPLER_ARG
      value: "1"
  fileSync:
    enabled: true
    mountPath: /app
  ttl: "4h"
  serviceAccount:
    create: true    # emits a dedicated SA — bind your team's Role to it manually
```

**Developer CLI (mirrord mirror — read-only, prod unaffected):**

```bash
mirrord exec \
  --target deployment/payment-api-darlane \
  --target-namespace team-alpha \
  -- uvicorn main:app --reload
```

**No `trafficWeight` needed.** Debugging does not route real users to darlane — mirrord mirror makes a read-only copy of production traffic. Real users only
ever see the production pod.

**Alternative when to reach outside Darlane:**

| Situation | Use instead |
|---|---|
| Always-on production profiling (CPU, memory) | Pyroscope, Datadog Continuous Profiler in the main Deployment |
| Need to inspect production pod in-place (not a copy) | `kubectl exec` into production (with care) — Darlane is the safer path |
| Distributed trace across multiple services | Jaeger / Tempo — Darlane only gives you the one service's side |

---

#### Canary / Temporary New Feature Delivery

Validate a new feature with real production traffic before the PR lands. The darlane pod runs the new code; the main Deployment continues serving the rest.

```yaml
darlane:
  enabled: true
  command: ["uvicorn", "main:app", "--reload"]
  fileSync:
    enabled: true
    mountPath: /app
  trafficWeight: 5     # start at 5%, monitor error rate + latency
  ttl: "8h"
```

**Workflow:**

```
1. fileSync syncs new feature code into darlane
2. trafficWeight: 5 — 5% of real users reach the new feature
3. Watch Prometheus: error rate, p99 latency (same stack as prod)
4. If clean → bump trafficWeight to 20, then 50, then 100
5. Validated → open PR → CI/CD deploys to main Deployment
6. Reset trafficWeight to 0 — main Deployment now carries all traffic
```

**What this is not:** not a production-grade progressive delivery mechanism. darlane is a single pod with no HPA and no automated rollback. This is pre-PR
validation, not a substitute for a proper release pipeline.

**Alternative when to reach outside Darlane:**

| Situation | Use instead |
|---|---|
| Feature needs to run in production for days with health analysis | ArgoCD Rollouts (canary strategy, metric analysis, automatic rollback) |
| Need automated rollback on SLO breach | ArgoCD Rollouts + Prometheus metric analysis |
| Multi-service feature that spans more than one Deployment | Coordinate Darlane per-service or use a dedicated staging environment |

---

#### Hotfix / Emergency Patch

Production is degraded. An agent or on-call engineer needs to develop, validate, and promote a fix — fast, with a full audit trail.

**XR (manifest side):**

```yaml
darlane:
  enabled: true
  replicas: 1
  productionOverride: true              # required when environment: prod
  command: ["uvicorn", "main:app", "--reload"]
  env:
    - name: OTEL_TRACES_SAMPLER
      value: always_on                  # maximum observability for the fix session
    - name: OTEL_TRACES_SAMPLER_ARG
      value: "1"
  fileSync:
    enabled: true
    mountPath: /app
  trafficWeight: 5                      # after validating with mirror, route 5% for confirmation
  ttl: "2h"                             # tight window — this is an incident, not a dev session
  serviceAccount:
    create: true
    name: payment-api-darlane           # SRE agent + on-call bind their own Role to this SA
```

**Staged validation loop:**

```
1. Sync fix into darlane pod: `wxops darlane sync <service> --local ./src`
2. Mirror real production traffic to local process (read-only):
     mirrord exec --target deployment/payment-api-darlane -- uvicorn main:app --reload
3. Observe darlane logs + traces — confirm error rate drops with the fix applied
4. Stop mirrord. Set trafficWeight: 5 in XR → route 5% of real users to darlane pod
5. Confirm error rate stays down in Prometheus → expand or promote
6. Open PR with metrics evidence attached
7. CI/CD promotes fix to main Deployment — darlane TTL expires or scale to 0
```

**Developer CLI — mirror mode (read-only observation):**

```bash
mirrord exec \
  --target deployment/payment-api-darlane \
  --target-namespace team-alpha \
  -- uvicorn main:app --reload
```

**Developer CLI — steal with header filter (targeted, high-risk):**

```bash
# Steals only requests matching the header — real users stay on production pod
# Requires productionOverride: true in XR + explicit intent
mirrord exec \
  --target deployment/payment-api-darlane \
  --target-namespace team-alpha \
  --steal \
  --filter "x-debug-user: sre-agent" \
  -- uvicorn main:app --reload
```

Only use steal mode when mirror is insufficient — it routes specific real requests to your local process. Pair with Guardian audit when available.

**Alternative when to reach outside Darlane:**

| Situation | Use instead |
|---|---|
| Fix requires schema migration | Follow full release process — Darlane cannot run migrations safely |
| Fix involves infrastructure change | Standard GitOps change, not a pod-level patch |
| Incident is a security breach | Follow your incident response runbook — Darlane is not an isolation boundary |

---

### When to reach outside Darlane entirely

Darlane covers the inner loop: dev/staging debugging, pre-PR canary validation, feature flag toggling via env, incident response. These scenarios belong
elsewhere:

| Need | Why Darlane doesn't fit | Reach for |
|---|---|---|
| Long-running production canary (days) | Single pod, no HPA, no automated rollback | ArgoCD Rollouts — weighted canary with Prometheus analysis |
| Per-user feature targeting | Env flags are per-pod, not per-user | Unleash (self-hosted), Flagsmith, GrowthBook |
| Statistical A/B test with significance tracking | No experiment framework built in | GrowthBook + your analytics pipeline |
| Always-on production profiling | darlane is opt-in, not always-on | Pyroscope, Datadog Continuous Profiler |
| Cross-service traffic routing | darlane is one Deployment in one namespace | Gateway API HTTPRoute (future W'xOps XRD) |
| Blue/green deployment | Needs two production-grade Deployments + atomic switch | ArgoCD Rollouts blue/green strategy |
| Production load testing | Real user traffic during load test = bad day | k6, Locust against a staging environment |

The pattern: Darlane is fast, low-ceremony, and developer-controlled. It handles anything where you need real infrastructure access without waiting for CI/CD.
When you need durability, statistical rigor, or automated rollback, a dedicated tool is the right call.

---

## AI Agent workflow

The darlane pod provides a pre-wired execution target for AI coding agents — real secrets, real database, real network — without any environment setup.

**Pattern:**

```
AI Agent generates code change
  → syncs to darlane pod (`wxops darlane sync <service> --local ./src`)
  → darlane hot-reloads
  → agent reads pod logs / calls health endpoint
  → validates correctness against real infrastructure
  → opens PR if good, iterates if not
```

**What makes this work:**
- The agent needs no Vault configuration, no DB credentials, no API keys — they
  are already in the pod
- The agent uses the dedicated `ServiceAccount` (from `darlane.serviceAccount`) to exec and
  scale — the platform team binds a scoped `Role` to it; no cluster-admin access required
- Mirrord provides real traffic for the agent to test against
- The platform's logging stack captures all activity automatically

**Example: testing a new Claude integration without deploying to prod:**

```python
# Agent writes the integration, syncs it to darlane
subprocess.run(["kubectl", "cp", "claude_integration.py",
                f"team-alpha/{darlane_pod}:/app/claude_integration.py"])

# Trigger a test inside the pod
result = subprocess.run([
    "kubectl", "exec", darlane_pod, "-n", "team-alpha",
    "--", "python", "-c",
    "from claude_integration import run; print(run('test query'))"
], capture_output=True)

# ANTHROPIC_API_KEY was already in the pod — real API call, real response
# Agent reads result and decides: iterate or promote to PR
```

---

## SRE Agent — intelligence injector

The SRE Agent is the most advanced use of Darlane: an AI system that autonomously debugs production incidents by injecting targeted fixes into the darlane pod
and validating them against mirrored production traffic — without any human intervention in the diagnosis and validation loop.

**Incident response flow:**

```
Alert fires (latency spike / error rate / availability)
    ↓
SRE Agent reads logs + metrics (already instrumented — no setup)
    ↓
Forms hypothesis: "DB connection pool exhausted under load"
    ↓
Generates targeted fix (increase pool size, add retry backoff)
    ↓
Injects fix into darlane pod (exec + file sync)
    ↓
Enables traffic mirror (mirrord) — real production traffic hits darlane
    ↓
Validates: error rate drops in darlane metrics, latency normalizes
    ↓
Opens PR with fix + validation evidence
    ↓
Human SRE reviews PR — fix already validated against real traffic
```

**What the platform provides for the SRE Agent:**

The composition emits a dedicated `ServiceAccount` for the darlane pod when `darlane.serviceAccount.create: true`. The platform team creates a `Role` +
`RoleBinding` separately and binds it to that SA — granting the agent's identity exactly:
- `deployments/scale` on `<appName>-darlane`
- `pods/exec`, `pods/portforward`, `pods/log` scoped to darlane pods
- Read access to the namespace's `Events`

The agent authenticates as the SA — a real, auditable Kubernetes identity, not cluster-admin access. All activity is logged by the platform's audit stack.

**Why "no manual reproduction steps" matters:**

Traditional incident response: alert → on-call engineer woken up → SSH access requested → reproduce locally (or not) → guess at fix → deploy to staging →
validate → deploy to prod. 45–90 minutes minimum.

SRE Agent with Darlane: alert → agent activates → fix injected → validated → PR ready. Human reviews a validated fix, not a hypothesis. Incident resolution time
measured in minutes, not hours.

---

## Guardian Framework (platform-injected safety)

Guardian is the platform's safety layer for Darlane sessions — sidecars injected into the darlane pod that provide scanning, audit trail, and AI code review
without requiring any developer action. Guardian is a long-term workstream independent of the Darlane XRD roadmap.

See [development-docs/core-ideas/guardian.md](guardian.md) for the full Guardian architecture and vision.

---

## Access control

The composition creates a dedicated `ServiceAccount` for the darlane pod when `darlane.serviceAccount.create: true`. RBAC is **not** composed automatically —
the platform team creates the `Role` + `RoleBinding` manually and binds them to that `ServiceAccount`.

**Compose the SA (in the XR):**

```yaml
darlane:
  serviceAccount:
    create: true
    name: payment-api-darlane          # defaults to {appName}-darlane
    annotations:                       # optional — workload identity (IRSA, GCP WI)
      eks.amazonaws.com/role-arn: arn:aws:iam::123456789:role/darlane
```

**Create the Role + RoleBinding separately (GitOps / platform layer):**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: payment-api-darlane
  namespace: team-alpha
rules:
  - apiGroups: ["apps"]
    resources: ["deployments/scale"]
    resourceNames: ["payment-api-darlane"]
    verbs: ["get", "patch", "update"]
  - apiGroups: [""]
    resources: ["pods/exec", "pods/portforward", "pods/log"]
    verbs: ["create", "get"]
  - apiGroups: [""]
    resources: ["pods", "events"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: payment-api-darlane
  namespace: team-alpha
subjects:
  - kind: ServiceAccount
    name: payment-api-darlane
    namespace: team-alpha
  - kind: Group                        # also bind developer OIDC group directly
    name: team-alpha-developers
    apiGroup: rbac.authorization.k8s.io
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: payment-api-darlane
```

**Why manual RBAC:**

The `Role` rules and subjects differ per team, per environment, and per agent type. Composing them inside the XRD would require exposing the full RBAC schema as
XR parameters — that is the platform team's domain, not the tenant's. Keeping the `Role`/`RoleBinding` in GitOps lets the platform team audit and evolve them
independently of the app lifecycle.

The `ServiceAccount` is composed because it must exist before the pod starts and needs a stable, predictable name for the binding to reference.

---

## Safety model

| Scenario | Risk | Guardrail |
|---|---|---|
| Mirror mode, `staging` | Low — read-only, prod unaffected | None required |
| Steal mode, `staging` | Medium — dev handles real requests | Use HTTP header filter (`x-debug-user`) |
| Mirror mode, `prod` | Medium — real user data visible | `darlane.productionOverride: true` required |
| Steal mode, `prod` | High — dev code handles real prod traffic | `productionOverride: true` in XR (double opt-in) + mirrord `--steal` CLI flag + Guardian audit |
| Abandoned session | Medium — intercepted requests dropped | Kyverno `ClusterCleanupPolicy` deletes expired darlane Deployment; Crossplane re-creates at `replicas: 0`. See [TTL enforcement](#ttl-enforcement-auto-scale-down). |

The platform enforces the production override at the KCL composition level — a darlane pod cannot be enabled in `environment: prod` without the explicit
`productionOverride: true` flag visible in the XR diff and PR.

---

## Choosing between mirrord and Telepresence

| | mirrord | Telepresence |
|---|---|---|
| Default mode | Mirror (read-only copy) | Intercept (redirects traffic) |
| Cluster footprint | None — agent injected per-session | Traffic Manager Deployment required |
| Scope | Single pod — natural fit for darlane | Namespace or service-wide |
| Best for | Fast attach, real-traffic observation, AI agent workflows | Full network identity replacement, preview URLs |
| W'xOps recommendation | Primary path | Fallback for existing users |

Neither tool is installed by the composition — same model as cert-manager for TLS. Install once per cluster, use from any darlane pod.

---

## TTL enforcement (auto-scale-down)

The `darlane.ttl` field adds a `wxops.cloud/darlane-ttl` annotation to the darlane Deployment. Enforcement is a **cluster-level Kyverno policy** — not part of
the Composition itself. The policy file lives at `providers/policies/darlane-ttl.yaml`.

### XR configuration

```yaml
darlane:
  enabled: true
  ttl: "4h"           # Go duration: 4h, 8h, 90m, etc.
  replicas: 0         # keep 0 in XR — scale up via kubectl on demand
```

`ttl` accepts any [Go duration string](https://pkg.go.dev/time#ParseDuration): `30m`, `4h`, `8h`, `24h`, and so on.

### How enforcement works

```
Developer/portal: kubectl patch xtenantapp <name> --type=merge \
                    -p '{"spec":{"parameters":{"darlane":{"replicas":1}}}}'
                  └─ XR updated → Crossplane reconciles → darlane Deployment at replicas=1
                  └─ wxops.cloud/darlane-ttl: "4h" annotation on Deployment

Kyverno (every 30 min):
  ├─ Checks creationTimestamp + "4h" < now?
  ├─ If yes within 30 min of expiry → adds wxops.cloud/darlane-ttl-warning: expiring-soon
  └─ If yes past expiry → DELETES the darlane Deployment

Crossplane provider-kubernetes:
  └─ Detects Deployment missing → re-creates from XTenantApp Composition
     └─ Reads darlane.replicas from XR

Portal (on TTL expiry):
  └─ Also patches XR darlane.replicas: 0 → Crossplane reconciles to 0 replicas
```

The warning annotation (`wxops.cloud/darlane-ttl-warning: expiring-soon`) fires 30 minutes before expiry. The portal can watch this annotation to show a
"Darlane expiring in 30 min" banner so the developer can save work.

### Kyverno policies

Two policies ship in `providers/policies/darlane-ttl.yaml`:

| Policy | Kind | What it does |
|---|---|---|
| `darlane-ttl-warning` | `ClusterPolicy` (kyverno.io/v2) | Mutates expiring Deployments with warning annotation 30 min before expiry |
| `darlane-ttl-scaledown` | `ClusterCleanupPolicy` (kyverno.io/v2alpha1) | Deletes expired darlane Deployments on a 30-minute schedule |

Install:
```bash
# Kyverno (once per cluster)
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install kyverno kyverno/kyverno -n kyverno --create-namespace

# Apply the Darlane TTL policies
kubectl apply -f providers/policies/darlane-ttl.yaml
```

Requires **Kyverno v1.11+** (`CleanupPolicy` GA in v1.12+).

### Interaction with Crossplane

Kyverno deletes the darlane Deployment (not the `XTenantApp` XR). Crossplane's `provider-kubernetes` sees the Deployment missing and re-creates it from the
Composition, which reads `darlane.replicas` from the XR.

The XR is always the source of truth. `darlane.replicas` in the XR determines what Crossplane reconciles the Deployment to. `kubectl scale` is overwritten on
every reconcile cycle and must not be used — always patch the XR.

**TTL scale-down requires two coordinated actions:**
1. **Kyverno** deletes the darlane Deployment when TTL expires.
2. **The portal** patches the XR `darlane.replicas: 0` at the same time.

Kyverno alone is insufficient — if the XR still has `darlane.replicas: 1`, Crossplane re-creates the Deployment at 1 replica immediately after Kyverno deletes
it. Both the Deployment deletion (Kyverno) and the XR patch (portal) are required for a clean scale-down.

> **Portal responsibility:** when activating Darlane, set `darlane.replicas: 1` in the XR. When TTL expires or the developer finishes, reset it to `0`. Kyverno
> provides a safety-net deletion; the XR patch is what makes it stick.

---

## What's next: `XDarlane` XRD

The current `darlane.*` block inside `XTenantApp` is the proven foundation. The next evolution promotes Darlane to a **standalone Crossplane XRD** — a
purpose-built developer workspace that lives independently from the app it mirrors, with native integrations for file sync, debugging, feature flags, A/B
testing, and AI agent workflows baked in as first-class fields rather than nested parameters.

### Why a standalone XRD

The debug-twin-as-a-field model has one structural limitation: Darlane's lifecycle is tied to the app XR. Every Darlane change is a change to the app spec.
Multiple concurrent Darlane sessions (dev + hotfix + SRE agent) cannot coexist as independent claims. The portal cannot create and destroy Darlane workspaces
on-demand without touching the app XR.

A standalone `XDarlane` resolves all of this:

| Current (`darlane.*` on `XTenantApp`) | Future (`XDarlane` standalone) |
|---|---|
| One Darlane per app | Multiple concurrent XDarlane claims per app |
| Darlane lifecycle tied to app XR | Independent lifecycle, TTL-managed by design |
| App team controls Darlane config | Portal, SRE agent, or developer holds their own claim |
| All Darlane fields nested under `darlane.*` | Flat, ergonomic top-level schema |
| Guardian wired manually | Guardian opt-in at the XDarlane level |

### What `XDarlane` looks like

```yaml
apiVersion: platform.wxops.cloud/v1alpha1
kind: XDarlane
metadata:
  name: payment-api-dev-alice
spec:
  parameters:
    appRef:
      name: payment-api          # the XTenantApp this workspace mirrors
      namespace: team-alpha
    ttl: "8h"                    # mandatory — ephemeral by design

    # File sync — native, no separate emptyDir wiring needed
    fileSync:
      enabled: true
      mountPath: /app
      initFromImage: true

    # Debug port — language-server-aware, DAP-compatible
    debugPort:
      enabled: true
      protocol: dap              # Debug Adapter Protocol (VS Code, nvim, etc.)
      port: 5678
      language: python           # pre-wires debugpy entrypoint in the command

    # Feature flags — version-controlled env overlays, portal-surfaced
    featureFlags:
      - name: NEW_CHECKOUT_FLOW
        value: "true"
      - name: RANKING_MODEL
        value: v2

    # A/B traffic — independent of the app's Ingress config
    traffic:
      weight: 20
      stickySession:
        enabled: true
        cookieName: darlane-alice

    # Guardian — scanning and audit injected as sidecars
    guardian:
      enabled: true
      scanning: true             # CVE + SAST on file changes
      audit: true                # session log → SIEM

    # Who can access this workspace
    rbac:
      subjects:
        - kind: User
          name: alice@wxops.cloud
```

### The agent model

With `XDarlane` as a standalone XRD, each consumer holds their own claim:

```
Developer (Alice)   → XDarlane: payment-api-dev-alice     (ttl: 8h)
SRE Agent           → XDarlane: payment-api-sre-hotfix    (ttl: 2h, productionOverride)
AI Coding Agent     → XDarlane: payment-api-agent-branch  (ttl: 4h, no traffic)
```

The app XR (`XTenantApp`) never changes. Each workspace is independently scheduled, resourced, TTL-managed, and audited. When the session ends, the `XDarlane`
claim is deleted — no cleanup needed in the app XR.

### What changes for developers

The current `darlane.*` fields on `XTenantApp` continue to work. Migration is additive — the `XDarlane` XRD is a new path, not a replacement. Existing apps gain
the option to use standalone claims; no forced migration.

---

## Prerequisites

- `darlane.enabled: true` in the `XTenantApp` XR
- OIDC identity configured (Impersonate Proxy + Vault Kubernetes Auth)
- **For mirrord:** `mirrord` CLI installed locally (open-source, no operator required).
- **For telepresence:** Traffic Manager installed in-cluster
  (`telepresence helm install`), `telepresence` CLI installed locally.
- **For file sync:** `wxops` CLI installed locally — `wxops darlane sync <service> [flags]`.
- **For A/B / traffic weight:** Traefik with `TraefikService` CRD available
  (default in W'xOps clusters).
