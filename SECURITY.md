# Security Policy

W'xOps Core is a Crossplane Configuration library: XRDs and Compositions that render Kubernetes
objects via `provider-opentofu`, `provider-terraform`, `provider-kubernetes`, and `function-kcl`. It has no server of
its own — most of what a "vulnerability" means here is a composition that can be made to produce
something it shouldn't (an RBAC grant, a credential leak, a privilege escalation via a composed
resource), or a supply-chain issue in a published package. See
[`docs/core-ideas/security-threat-model.md`](docs/core-ideas/security-threat-model.md) for the full
threat model, trust boundaries, and known gaps — this file is only the reporting process.

## Supported versions

Releases are named by date (`release-YYYY-MM-DD`), not semver; compatibility is carried by the XRD
API version, held additive-only by `tests/api_compat.py`. Only the **latest release** is supported.
There is no backport policy — a fix lands on `main` and ships in the next release.

## Reporting a vulnerability

**Please do not open a public issue for a security report.**

Use [GitHub Security Advisories](https://github.com/wxops/wxops-core/security/advisories/new) to
report privately — this reaches the maintainer directly and lets us coordinate a fix before
disclosure. Include:

- What's affected (a specific package, a composition pattern, a CI/release script)
- What an attacker gains, and what's required to reach that state (cluster access level, RBAC
  already held, etc.)
- Steps to reproduce, if you have them

We'll acknowledge a report within a few days and aim to have a fix or a mitigation plan before any
public disclosure. Credit is given in the release notes unless you ask otherwise.

## Scope

In scope: the XRDs, Compositions, KCL source, the release/publish pipeline (`.github/workflows/`,
`.gitea/scripts/`), and anything a Configuration package composes that could escalate beyond what
its own XR should grant — see
[Compositions never emit Kubernetes RBAC](CONTRIBUTING.md#boundaries) for the standing rule this
guards.

Out of scope: the operators this project composes but does not implement (CloudNativePG, Vault,
cert-manager, Traefik, Kyverno — report to those projects directly), and the portal / CLI / Guardian
sidecars, which live in separate repositories.
