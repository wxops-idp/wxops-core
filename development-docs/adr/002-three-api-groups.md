# ADR-002: Three API groups — `scm`, `auth` and `platform` — and replacing, not converting, the `gitea-*` kinds

## Status
<!-- Matches spec.docStatus — single source of truth is the YAML, this is for readers -->
Accepted

## Context

Every Core kind lives in one API group, `platform.wxops.cloud`. The RFCs in flight add a lot of new kinds: Git-hosting resources
([RFC-003](../rfc/003-scm-connections-and-resources.md)), identity configuration ([RFC-004](../rfc/004-dex-identity-and-portal-authentication.md)), and object
storage ([RFC-006](../rfc/006-cloudflare-r2-object-storage-and-backup.md)). One group would mix three audiences with three different trust boundaries: tenants
asking for workloads, tenants and the platform dealing with external Git hosts, and platform operators deciding who can log in.
[RFC-007](../rfc/007-package-layout-by-api-group.md) is the directory layout and tooling move this split actually needed (`package/<group>/<name>/`,
`VERSIONS.yaml`'s `group`/`path`) — this ADR decides the split, RFC-007 is how the repo carries it.

Two constraints shape the answer. A released XRD is additive-only and cannot change group, so anything already released stays where it is. And the four
`gitea-*` kinds, released in `release-2026-09-16`, are Git-hosting resources that the `XScm*` family fully replaces.

## Decision

Split the API by trust boundary, not by technology:

| Group | Holds | Audience |
|---|---|---|
| `scm.wxops.cloud` | `XScmConnection`, `XScmOrg`, `XScmTeam`, `XScmUser`, `XScmRepository`, `XScmOAuthApp` | tenants (all but `XScmConnection`, which is platform-only) |
| `auth.wxops.cloud` | `XDexConnector`, `XOIDCClient` | platform operators |
| `platform.wxops.cloud` | `XTenantApp`, `XTenantDatabase`, `XPlatformDatabaseCluster`, `XObjectBucket`, `XRandomPassword` | tenants and platform |

- **New kinds start in their group; released kinds do not move.** Nothing Git-related is created in `platform` from now on.
- **The `gitea-*` kinds are replaced, then removed.** `XScm*` supersedes them from the release it ships in; they are removed in a later
  release through an allowlisted break, after the migration in RFC-003 has been run. Removal comes second because deleting an XRD deletes
  its XRs and, through their Workspaces, the Gitea objects.
- **Secrets integration is not a group.** ESO with Vault or OpenBao is a dependency every credential-producing kind shares, held to
  one convention (`PushSecret`, `remoteKey` without the KV prefix), not a boundary.
- **A group is not an install unit.** Installation stays per package. Date-named tags cannot be targeted by a `dependsOn` range, so no
  group-level meta-package is built.
- **Policies are not kinds.** The Kyverno policies of RFC-005 sit outside every group.

## Consequences

- RBAC can grant by `apiGroups:`: tenants get `scm` and `platform`, only operators get `auth`, and `XScmConnection` is withheld from tenants.
- Anything that hardcodes `platform.wxops.cloud` must learn three groups: the API-compatibility and invariant tests, the release-notes
  template, the docs and examples, provider RBAC, and the portal client. This is a one-off cost, and cheaper before the new kinds ship.
- Each package's XRD is versioned independently as before; `VERSIONS.yaml` gains the group per package.
- The `gitea-*` kinds stay served until their removal release, so there are two ways to create a Gitea repository for a while.
- A kind in the wrong group cannot be fixed later by moving it, only by replacing it, so placement of future kinds needs care.

## Alternatives Considered

- **One group.** No migration or tooling change, but tenant and operator kinds share one RBAC surface and the group stops saying what
  a kind is for.
- **Group per package.** Too fine: `kubectl api-resources` becomes a list of groups, and RBAC grants multiply.
- **Group per technology** (a `vault` or `dex` group). Names the implementation, which RFC-004 deliberately hides behind the schema.
- **Convert the `gitea-*` kinds in place.** Impossible: a released XRD cannot change group, and a new group means new kinds anyway.
- **Supersede `gitea-*` forever.** Safe, but leaves dead kinds in the API permanently and contradicts the point of a clean `scm` group.
