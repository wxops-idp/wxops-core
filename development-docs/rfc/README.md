# Requests for Comments

One committed file per proposal — a design argued *before* it is built. An RFC lays out the option space and asks for
comment; when it is accepted, it becomes the tracked plan for the work, and the decisions it settles are recorded
permanently as [ADRs](../adr/README.md).

**Template:** [`TEMPLATE.md`](TEMPLATE.md) — copy it, don't start from a blank page.

## When to write one

Use an RFC when the change touches an XRD's public schema, adds a package, changes what a composition emits, or commits
the platform to a new tool or external system. A small additive tweak doesn't need one — a
[feature request](../../.github/ISSUE_TEMPLATE/feature_request.md) is enough. Before writing, check this index's own `Status`
column, each RFC's own rejections and open questions, the archived
[`development-docs/_archives/ROADMAP.md`](../_archives/ROADMAP.md) *Decided and rejected*, and
[`solution-matrix`](../../docs/core-ideas/solution-matrix.md): the idea may already be tracked, planned or closed.

## Lifecycle

1. **Draft** — open an [RFC issue](../../.github/ISSUE_TEMPLATE/rfc.md). The issue is where community discussion
   happens, so it stays open to anyone. A maintainer-authored RFC can start directly as a file in a pull request.
2. **In review** — the RFC file is proposed as `NNN-title.md` in a pull request, numbered sequentially, using the
   template, with the issue linked in its *Status*. Review happens on the PR and the issue; the file is edited freely
   while it is still a draft.
3. **Accepted / Declined / Withdrawn** — the file is merged with its final *Status*. A declined RFC is kept, not
   deleted: the reasons it lost are the point.
4. **Implemented** — *Status* flips once the work ships, and the *Rollout Plan* is the checklist that tracks it. From
   acceptance on, only *Status* and *Rollout Plan* progress change; a change of design is a new RFC that says so.

Each decision an RFC settles gets its own [ADR](../adr/README.md) when it qualifies — an RFC argues an option space
across many questions, an ADR records one answer. An RFC that only ever produced work and no lasting decision needs no
ADR.

## RFC issue vs RFC file

| | GitHub issue | `development-docs/rfc/NNN-title.md` |
|---|---|---|
| Purpose | Intake and discussion | The tracked, versioned proposal |
| Who | Anyone, including the community | A maintainer merges it |
| Lives | While being discussed | Permanently, alongside the code it changes |

The issue template's sections map onto the file template's: *Proposed design* → *Detailed Design*, *Alternatives
considered* → *Alternatives*, *Motivation / problem statement* → *Motivation*.

## Index

| RFC | Title | Status |
|---|---|---|
| [002](002-migrate-terraform-to-opentofu.md) | Migrate the Workspace engine from Terraform to OpenTofu | Implemented |
| [003](003-scm-connections-and-resources.md) | SCM connections and resources — Gitea, GitHub and GitLab behind one API, with Vault-tracked credentials | Implemented (Phase 1) |
| [004](004-dex-identity-and-portal-authentication.md) | Dex as the identity provider — Core-rendered configuration, OpenBao-held secrets, Portal authentication | Accepted |
| [005](005-git-mapped-authorization.md) | Authorization mapped one-to-one to Git — RBAC for who may act, Kyverno ABAC for on what | Draft |
| [006](006-cloudflare-r2-object-storage-and-backup.md) | Cloudflare R2 as the first third-party service — provisioned backup and object storage | Draft |
| [007](007-package-layout-by-api-group.md) | Package layout by API group, with a Kustomization per category | Accepted |
| [008](008-openbao-as-a-platform-api.md) | The secret store as a platform API — OpenBao mounts, policies and access as resources | Draft |
