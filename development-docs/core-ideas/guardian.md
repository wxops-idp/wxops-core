# Guardian Framework

Guardian is the platform's long-term safety layer for Darlane — a set of sidecars injected into the developer workspace pod that provide scanning, audit, and
AI-assisted code review without requiring any developer action or configuration.

This document describes the Guardian architecture and vision. Guardian is not yet implemented and has no scheduled release. It is tracked here as a design
document, not a roadmap item.

---

**Table of Contents**
- [What Guardian is](#what-guardian-is)
- [Design principles](#design-principles)
- [Architecture](#architecture)
  - [Phase 1 — Tooling and scanning](#phase-1--tooling-and-scanning)
  - [Phase 2 — Audit and compliance](#phase-2--audit-and-compliance)
  - [Phase 3 — AI guardrail](#phase-3--ai-guardrail)
- [XR interface (future)](#xr-interface-future)
- [Why not a standalone agent](#why-not-a-standalone-agent)
- [Prerequisites and dependencies](#prerequisites-and-dependencies)

---

## What Guardian is

When a developer or SRE agent opens a Darlane session on a production environment, they have access to real secrets, real database connections, and — optionally
— real user traffic via steal mode. Guardian exists to make that access defensible.

**Guardian is not a blocker.** It does not prevent developers from doing their work. Findings are advisory during the session. The commit gate in CI/CD is where
enforcement lives. Guardian's job is to surface information and create an audit trail — not to interrupt the inner loop.

```
Pod: <appName>-darlane (or XDarlane workspace)
├── container: app             ← developer's process — untouched by Guardian
├── init: guardian-tools       ← pre-installed debugger/profiler tooling
├── sidecar: guardian-scan     ← continuous SAST + CVE scanning
├── sidecar: guardian-audit    ← session log: exec, file changes, network
└── sidecar: guardian-ai       ← real-time code review (Phase 3, opt-in)
```

All sidecars are injected by the platform at pod creation time. The developer sees none of them unless they look at the pod spec.

---

## Design principles

**Additive, never blocking.** Guardian adds information. It does not gate the session, interrupt hot-reload, or prevent a developer from exec-ing a command. The
inner loop must stay fast.

**Platform-owned, not developer-configured.** The developer does not install Guardian tools. The platform image is versioned, scanned, and auditable. Every
workspace that opts in gets the same toolset — no drift between developers.

**Audit trail as infrastructure.** Every shell command, file change, and network connection in a Darlane steal-mode session on production is logged to a
structured sink. This is what makes `productionOverride: true` defensible to a compliance team — not just the double opt-in, but the fact that everything that
happened is recorded.

**AI review as a second set of eyes, not a wall.** The guardian-ai sidecar watches file changes in real time and surfaces findings — potential SQL injection,
missing input validation, privilege escalation patterns, drift from established codebase conventions. It is advisory. A developer can proceed despite a finding.
The finding is logged.

---

## Architecture

### Phase 1 — Tooling and scanning

**`guardian-tools` init container**

Pre-installs a curated set of debugging and profiling tools into a shared `emptyDir` volume at `/opt/guardian-tools`. The developer's container mounts the same
volume read-only. The rootfs stays read-only; no `apt install` needed.

Default toolset (by language ecosystem):

| Ecosystem | Tools |
|---|---|
| General | `curl`, `jq`, `netcat`, `strace`, `tcpdump`, `grpcurl` |
| Python | `debugpy`, `py-spy`, `memray`, `psutil` |
| Node | `node --inspect` (pre-configured), `clinic`, `0x` |
| Go | `dlv`, `pprof` (via `go tool pprof`) |
| Database | `psql`, `pgbadger`, `redis-cli` |

The init container pulls from a platform-maintained image per ecosystem, versioned and continuously scanned. The catalog is updated independently of the Darlane
composition.

**`guardian-scan` sidecar**

Runs continuously alongside the developer's process. Watches the `fileSync` mountPath for file changes (inotify). On each change, runs:
- **Trivy/Grype** — dependency manifest scan (requirements.txt, package.json, go.sum)
  for known CVEs. Findings reported at image-build time are baseline; only new
  findings introduced by code changes surface as alerts.
- **Semgrep** — SAST scan with the platform's rule set (OWASP Top 10, SQL injection,
  secret literals, privilege escalation patterns). Rule set managed at platform level.

Findings are written to:
- Pod annotations (`guardian.wxops.cloud/scan-status`, `guardian.wxops.cloud/high-findings`)
- Structured JSON logs (same sink as application logs)
- Optionally: `XDarlane` status subresource (future)

Advisory only — the developer's process is never interrupted.

---

### Phase 2 — Audit and compliance

**`guardian-audit` sidecar**

Captures the full activity record for the session. Required for steal mode on production to satisfy audit requirements.

| Activity | Capture method |
|---|---|
| Shell commands | Shared PID namespace + `auditd` / eBPF |
| File changes | inotify on mountPath |
| Network connections | conntrack / eBPF socket trace |
| mirrord session events | Guardian reads mirrord agent annotations |
| kubectl exec events | Kubernetes API audit log (cluster-level) |

Output: structured JSON per event → platform SIEM (Loki, Elasticsearch, or equivalent). Retention managed by the platform's log policy, not by the developer.

**Findings in XR status (future)**

When Guardian is enabled on an `XDarlane` claim, the composition writes scan results back to the XR status:

```yaml
status:
  guardian:
    lastScanAt: "2026-07-10T08:30:00Z"
    highFindings: 0
    criticalFindings: 0
    auditActive: true
```

Kyverno policies can alert when a workspace has been alive >2h with unresolved HIGH findings, or when steal mode is active without audit enabled.

---

### Phase 3 — AI guardrail

**`guardian-ai` sidecar**

Watches file changes in the darlane pod's `fileSync` volume in real time and provides feedback through the developer's preferred channel (pod logs, VS Code
annotation, portal notification).

Designed for the hotfix-under-pressure scenario: CI is bypassed, a developer is directly patching code in a steal-mode session, and the usual review process is
not available.

**What it reviews:**
- SQL query construction (raw string interpolation, missing parameterization)
- Input validation at HTTP handler boundaries
- Privilege escalation patterns (`subprocess`, `eval`, `exec`, `os.system`)
- Hardcoded secrets or API keys introduced in the change
- Drift from established patterns in the existing codebase (via RAG over the repo)
- Missing error handling in paths that touch external services

**What it does not do:**
- Block the developer from writing to the file
- Gate the session on approval
- Connect to any external LLM API

The AI component runs entirely in-cluster against a self-hosted model. The darlane pod has access to production secrets and real user traffic — no third-party
API call is acceptable. Options: Ollama in-cluster, a private Claude endpoint behind the cluster's VPN boundary, or a dedicated inference node.

**Why in-cluster LLM matters:**

A developer debugging a production incident with steal mode enabled is sending real user payloads to their local process — or to the darlane pod. If
`guardian-ai` forwarded those payloads to an external API for review, that would constitute a data exfiltration path. The audit sidecar would flag it.
Guardian-ai must run local.

---

## XR interface (future)

When Guardian ships on `XDarlane`, the interface will look like:

```yaml
spec:
  parameters:
    guardian:
      enabled: true          # opt-in per workspace
      tools: true            # Phase 1: init container with debugger toolset
      scanning: true         # Phase 1: guardian-scan SAST + CVE sidecar
      audit: true            # Phase 2: guardian-audit session log sidecar
      ai: false              # Phase 3: guardian-ai review sidecar (requires LLM infra)
      ecosystem: python      # determines which guardian-tools image to pull
```

Platform operators can set cluster-level policy (via Kyverno) requiring Guardian on all steal-mode production sessions regardless of the developer's XR
configuration.

---

## Why not a standalone agent

Guardian could be implemented as a separate controller or operator that intercepts Darlane pods and mutates them. This was considered and rejected:

The `XDarlane` XRD owns the pod spec. Guardian sidecars are part of that spec — they are composed alongside the developer container, not injected after the
fact. This keeps the composition deterministic, auditable, and testable with `make render`. A mutation webhook (Kyverno `mutate`) is acceptable for
platform-level policy enforcement (e.g. requiring audit in prod), but the sidecar images and configuration are owned by the composition.

---

## Prerequisites and dependencies

Guardian has no target release. It depends on:

1. **`XDarlane` XRD** — Guardian is designed for the standalone XRD model, not the
   current `darlane.*` field on `XTenantApp`. The sidecar lifecycle and status
   writeback require a dedicated XR.
2. **In-cluster LLM infrastructure** — Phase 3 only. Ollama or a private model
   endpoint. Not required for Phase 1 or Phase 2.
3. **Platform SIEM** — Phase 2 structured log output needs a configured destination
   (Loki stack or equivalent). Phase 1 findings go to pod logs only.
4. **Kyverno** — for cluster-level policy enforcement (`guardian: audit: true`
   required in prod steal mode). Kyverno is already a prerequisite for Darlane
   TTL enforcement.
