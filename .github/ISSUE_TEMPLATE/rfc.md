---
name: RFC — feature / design proposal
about: Propose a new capability or a significant design change, with the option space
title: "[RFC] "
labels: rfc, needs-review
assignees: ''

---

<!--
An RFC argues a change BEFORE it happens. For small additive tweaks, the
Feature request template is enough — use this when the change touches an
XRD's public schema, adds a package, changes a composition's emitted
resources, or commits the platform to a new tool.

Before writing: check the RFC index's Status column, each RFC's own rejections, the archived
development-docs/_archives/ROADMAP.md "Out of scope" and "Decided and rejected", and
docs/core-ideas/solution-matrix.md — your idea may be tracked, planned, or already
closed. Referencing that beats rediscovering it in review.
-->

## Summary

One paragraph: what is proposed and for whom.

## Motivation / problem statement

What breaks or is missing today. Concrete scenario over abstract benefit —
which tenant/operator action fails, and what it costs.

## Proposed design

The shape of the change:

- **API surface** — new/changed XRD fields (sketch the YAML)
- **Composition behaviour** — what gets emitted, under which conditions
- **Affected packages** — `tenant-app` / `tenant-database` / `platform-database-clusters` / `gitea-*` / new package
- **Provider RBAC** — any new API group the composed resources need

```yaml
# proposed spec.parameters sketch
```

## Alternatives considered

At least one real alternative and why it loses. "Do nothing" counts and
should usually be listed with its actual cost.

## Compatibility & change tier

- Change tier per `release-notes/README.md`'s taxonomy: `safe` / `careful` / `breaking`
- Existing XRs affected? Rename or immutable-field hazard involved?
- `VERSIONS.yaml` impact

## Testing plan

Which golden cases / invariants / negative cases prove it — a new emitted
kind needs a case per conditional branch (see `CONTRIBUTING.md`).

## Out of scope

What this RFC deliberately does not cover, so review stays bounded.

---
<!--
Lifecycle: needs-review → accepted (label) or declined (closed with reason).
An RFC worth keeping graduates to a committed file, development-docs/rfc/NNN-title.md
(see development-docs/rfc/README.md), or straight to a PR when small.
Decisions of lasting consequence also get a committed file in development-docs/adr/
(see development-docs/adr/README.md), linking back to this issue as the full record.
-->
