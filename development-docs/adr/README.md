# Architecture Decision Records

One committed file per decision of lasting consequence — a tool adoption, an architectural boundary,
a convention, a deliberate rejection. An ADR records *why*, so the reasoning behind a decision stays
discoverable independent of anyone's memory of the conversation that produced it.

**Template:** [`TEMPLATE.md`](TEMPLATE.md) — copy it, don't start from a blank page.

## Lifecycle

1. **Proposed** — open a
   [GitHub issue](../../.github/ISSUE_TEMPLATE/adr.md) if the decision needs discussion first. Small,
   clearly-reasoned decisions can skip straight to step 2.
2. **Accepted** — committed here as `NNN-title.md`, numbered sequentially, using the template. The
   issue (if one existed) becomes the discussion trail; this file is the permanent record.
3. **Superseded** — a later decision that reverses or replaces an earlier one is a *new* ADR that
   says so in its own Context section and links back. An accepted ADR is never edited after the fact
   — that would erase the record this convention exists to keep.

Related: an [RFC](../rfc/README.md) argues a design *before* it happens, when the open question is an
option space rather than a single decision. An accepted RFC often produces an ADR as its residue.

## Index

| ADR | Decision |
|---|---|
| [001](001-package-channel-label.md) | Package channel label (`stable`/`nightly`) over a guardrailed rollout system |
| [002](002-three-api-groups.md) | Three API groups (`scm`, `auth`, `platform`), and replacing rather than converting `gitea-*` |
| [003](003-opentofu-workspace-engine.md) | OpenTofu as the Workspace engine, not Terraform — licensing, and why `gitea-*` was archived rather than migrated |
| [004](004-scm-repository-vendor-field.md) | `XScmRepository` repeats `vendor` to pick a Terraform provider — providers can't be conditional in HCL |
