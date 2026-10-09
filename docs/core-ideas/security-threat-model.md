# Security Threat Model — trust boundaries, mitigations, and honest gaps

> **Status: consolidation, current as of v0.4.0.** The security posture is
> real but scattered — across the multi-cluster identity work, Guardian's
> data boundaries, recorded decisions, the test invariants, and decisions buried in
> session history. This document puts it in one place: assets, trust
> boundaries, threats mapped to existing mitigations, and the gaps stated
> plainly. It is the content basis for [`SECURITY.md`](../../SECURITY.md), and the review artifact
> for the OSS release.

## Assets — what an attacker would want

| Asset | Where it lives | Worst case |
|---|---|---|
| Tenant secrets & DB credentials | Vault (KV2), materialised as Secrets by ESO | Cross-tenant data access |
| Spoke cluster credentials | **Nowhere, by design goal** — the multi-cluster architecture is largely shaped by refusing to create this asset | Fleet-wide compromise |
| Production traffic & payloads | In-cluster; reachable in Darlane steal-mode sessions | Data exfiltration |
| The composition supply chain | `kcl/` → `composition.yaml` → OCI packages → every cluster | Malicious resources rendered fleet-wide |
| provider-kubernetes's ClusterRole | `providers/rbac-provider-kubernetes.yaml` | The platform's own privilege ceiling becomes the attacker's |
| The Gitea archive / GitHub repo | Forges | History tampering, workflow injection |

## Trust boundaries

```
end user ──▶ Traefik ingress ──▶ tenant app          (tenant namespace)
                                      │ B4
portal / developer ──▶ hub API ──▶ Crossplane ──▶ provider-kubernetes ──▶ spokes
        │ B1                │ B2                          │ B3
   Pinniped/OIDC       XR schema (B2a)              scoped ClusterRole
                       pr-validate gate (B2b)       structured authn (future)
                                      │
developer / SRE agent ──▶ Darlane pod (real secrets, real traffic)   ← B5, Guardian
```

- **B1 — who may act**: human identity via Pinniped (Gitea OIDC); agent
  identity via dedicated SAs; RBAC authored only in GitOps
  (`development-docs/_archives/ROADMAP.md` §Decided and rejected; the seam in [tenant-app.md](../api-reference/tenant-app.md#developer-access-and-rbac)).
- **B2 — what may enter the system**: XRD schema validation at admission
  (B2a) and, for changes to the platform itself, the pr-validate gate — XRD
  conformance, golden render diff, invariants, xpkg build (B2b). The gate is
  identity-blind: human and AI-authored changes pass the same bar.
- **B3 — what the platform may do to clusters**: the provider's ClusterRole
  enumerates exactly the API groups compositions emit; conspicuously absent
  is `rbac.authorization.k8s.io` (deliberate) — the provider cannot mint
  privilege. Multi-cluster keeps this shape: scoped roles per spoke,
  projected short-lived tokens, never standing cluster-admin
  ([multi-cluster.md](multi-cluster.md#layer-2--identity-and-authentication)).
- **B4 — tenant blast radius**: namespace isolation + Kyverno policies; the
  known honest limit is `pods/exec` being namespace-wide (documented wherever
  exec appears, sized-namespace guidance).
- **B5 — production data in debug sessions**: `productionOverride` double
  opt-in, TTL + Kyverno cleanup, and Guardian's phases — audit sidecar for
  steal-mode, and the **in-cluster-LLM rule**: nothing that sees payloads may
  call an external model API ([guardian.md](guardian.md#phase-3--ai-guardrail)).

## Threats → mitigations (STRIDE-flavoured, platform-specific)

| Threat | Vector | Mitigation today | Residual |
|---|---|---|---|
| **Privilege escalation via the provider** | Composition emits RBAC; provider's broad grants defeat K8s escalation checks | Decision recorded in `development-docs/_archives/ROADMAP.md` §Decided and rejected + grant commented with rationale + `no-rbac-emitted` invariant fails the PR mechanically | Provider ClusterRole is still wide *within* its groups; per-namespace scoping unexplored |
| **Malicious/buggy composition change** | PR altering rendered output subtly | Golden tests catch *any* output change; invariants catch classes (secrets-in-status, missing providerConfigRef, Vault path prefix); KCL-drift hook stops package≠source | Golden review discipline is human — a rubber-stamped `test-update` defeats it |
| **Secret leakage via status** | Terraform outputs / composition writing sensitive values to world-readable XR status | `initial_password` marked sensitive (never patched); `no-secrets-in-status` invariant; connection creds only via Vault/ESO path | Invariant is name-heuristic; a poorly named secret field could slip |
| **Supply chain — schema source** | Upstream CRDs-catalog changes what CI accepts | Catalog pinned by SHA in three places, bumped only by commit | Function/provider images pinned by tag, not digest; no image signing/verification yet |
| **Hub compromise → fleet compromise** | Hub holds spoke credentials | Today: no spokes, `InjectedIdentity` only. Design: projected tokens + structured authn, never `argocd cluster add`; OCM evolution removes hub-held creds entirely ([connectivity](multi-cluster-connectivity.md#the-three-trust-paths-the-thing-most-designs-miss)) | Push-model interim *does* hold scoped per-spoke creds across **three** independent trust paths; the CAPI trust-root decision is still open |
| **Darlane data exfiltration** | Dev/agent session with real traffic forwards data out | Guardian audit (planned), in-cluster LLM rule, TTL bounds, per-identity SAs | Guardian is 📋 designed, not built — today the mitigation is the opt-in gates + platform logging only |
| **Forge/workflow tampering** | Malicious PR edits CI to exfiltrate or self-approve | pr-validate on PRs; `no-commit-to-branch` local hook; release commits via explicit `SKIP` | **No branch protection asserted server-side** (the hook is local/bypassable); GitHub env secrets exposure via workflow edits unreviewed |
| **DoS / noisy tenant** | Metrics cardinality bombs, resource exhaustion | Composition-enforced `sampleLimit`; quotas via Kyverno policies | No `NetworkPolicy` emission; ResourceQuota not composed per tenant |
| **Information disclosure — infra details** | Docs/changelog leaking internal endpoints | Deliberate line drawn: Gitea hostname public (access-gated), SSH port never published; install manifests scrubbed to public registry | Periodic re-scan is manual; no CI check for hostname/port patterns |

## The rules that hold it together (cross-references)

1. **No custom controllers** (`CLAUDE.md` architecture rule; twice-validated per [multi-cluster-scale.md](multi-cluster-scale.md#gpu-pools--the-third-architecture-already-field-tested-here)) — smaller attack surface, everything renderable offline.
2. **No RBAC from compositions** + **the SA-in-status seam** — `development-docs/_archives/ROADMAP.md` §Decided and rejected; [tenant-app.md](../api-reference/tenant-app.md#developer-access-and-rbac).
3. **One write path for fixes — the PR gate** ([self-service-operations.md](self-service-operations.md#the-suggest-patch-loop--why-l4-is-structurally-cheap-here)); agents get read-only + PR, never kubectl-write (L5 gated behind Guardian).
4. **Payload/metadata corpus tiering** for any AI ([knowledge-architecture.md](knowledge-architecture.md#architecture-around-the-agent)).
5. **Access control over obscurity** — gates are real (Pinniped, RBAC, permission-gated forge), not hidden URLs; the only obscurity kept (SSH port) is a free scan-reduction, not a control.

## Gaps — ordered, honest

1. **Server-side branch protection** on GitHub before external contributors arrive — the local hook is advisory.
2. ~~`SECURITY.md`~~ — done: GitHub Security Advisories as the private disclosure channel; this doc is its content.
3. **Image digests + signing** (cosign or equivalent) for functions/providers and published packages.
4. **NetworkPolicy story** — either composed per tenant-app or explicitly delegated to Kyverno generate-policies; currently neither is written down. Note the ordering: **flow data is how a NetworkPolicy gets authored without breaking production** — observe what actually talks, then deny the rest. Doing this without O13 is guesswork.
5. **No runtime (kernel-level) detection** — Falco/Tetragon/KubeArmor are all absent, so a container that is compromised *after* admission is unobserved. The mitigations above are all preventive (admission, schema, RBAC); nothing detects post-exploitation. Deliberately not urgent at Tier 1 — every option is a privileged fleet-wide DaemonSet, and the real cost is rule tuning rather than install — but it is the largest structural blind spot in this table. Collection path and tool trade-offs: [`observability.md §the kernel plane`](observability.md#the-kernel-plane--flows-and-runtime-security); *what* to detect belongs here.
6. **Guardian Phase 1–2** — the Darlane-on-prod residual stays open until audit exists.
7. **Leak-pattern CI check** — grep gate for internal hostname/port patterns in tracked files, cheap insurance for the two-forge model.

## See also

[`multi-cluster.md`](multi-cluster.md) Layer 2 · [`guardian.md`](guardian.md) ·
[`observability.md`](observability.md#the-kernel-plane--flows-and-runtime-security) — how runtime
detections and flow data are collected, and why that stays one pipeline rather than two ·
[`solution-matrix.md`](solution-matrix.md) (M14, A11, A13, O13–O15 rows) ·
`tests/invariants.py` — the mechanically-enforced subset of this document.
