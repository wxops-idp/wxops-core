# ADR-001: Package channel label (`stable`/`nightly`) over a guardrailed rollout system

## Status
<!-- Matches spec.docStatus — single source of truth is the YAML, this is for readers -->
Accepted

## Context

Compositions in this repo are applied fleet-wide the instant a new `CompositionRevision` activates — every XR on `compositionUpdatePolicy: Automatic` with no
selector adopts a new release simultaneously, whether or not it was ready for that change. There was no way to tell a production-tracking XR apart from one
that's fine running whatever's newest, and no cheap way to try a development build without touching production.

An earlier attempt at solving this explored a much heavier, guardrail-and-automation-based rollout system. None of it was ever built — it was reviewed and
rejected while still a design, as too complex to operate or explain to a future contributor. This is a single-maintainer project; a mechanism that only the
person who designed it can reason about fails the goal even if it's technically sound.

## Decision

Use a single Kubernetes-native mechanism, nothing custom-built:

- Every `package/<pkg>/composition.yaml` carries `metadata.labels.channel: stable`, committed in Git.
  `make build`/`make push`/`make release` package the file unchanged — every release ships labelled
  `stable` with zero additional tooling.
- `package/dev/kustomization.yaml` carries a Kustomize `labels:` transformer overriding `channel` to
  `nightly` for anything applied via `make install-dev`. Dev installs don't build or publish an OCI
  package at all, so there's nothing to tag — the label is set at `kubectl apply -k` time, not build
  time.
- An XR opts into a channel with Crossplane's own fields: `compositionRevisionSelector.matchLabels`
  plus `compositionUpdatePolicy: Automatic` to auto-track a channel, or `compositionUpdatePolicy:
  Manual` with an explicit `compositionRevisionRef` to never auto-move at all. `Manual` is recommended
  as the default for production XRs — see
  [`development-docs/development/releasing.md#channels`](../development/releasing.md#channels) for the full
  mapping and why.

Crossplane copies a Composition's labels onto every `CompositionRevision` it creates ([composition
revisions](https://docs.crossplane.io/v2.4/composition/composition-revisions/)); that single fact is the entire mechanism.

## Consequences

**Easier:** the whole thing is one paragraph to explain — a label, and two native XR fields. Nothing to install, nothing to operate, nothing that can silently
drift out of sync with what Crossplane itself does, because there is no separate system layered on top of Crossplane's own behaviour.

**Harder, accepted as a cost:** there is no enforcement. A production XR can select `nightly` by mistake and nothing stops it. If that becomes a real incident
rather than a theoretical one, that's the trigger to revisit this decision, not a reason to pre-build guardrails against a risk that hasn't materialized.

`CompositionRevision` retention has no documented limit or garbage-collection behaviour from Crossplane itself — old revisions accumulate. Unresolved by this
ADR, not new to it.

This also establishes `development-docs/adr/` as where a decision like this one lives from now on — a small, deliberate change from the ADR convention
`development-docs/core-ideas/knowledge-architecture.md` originally proposed (decisions recorded as a linked GitHub issue plus a `development-docs/ROADMAP.md`
row, no file tree). A committed file outlives and out-diffs an issue, which better serves the goal this ADR itself exists for: keeping *why* a decision was made
discoverable without depending on anything outside this repo.

## Alternatives Considered

- **A heavier, guardrail-and-automation-based rollout system** — rejected before anything was built:
  too complex for a single-maintainer project to operate or explain to a new contributor. Not
  detailed here because none of it exists anywhere in this repo; if a concrete future need makes a
  heavier approach worth it, that's a new ADR built from the actual need, not a resurrection of an
  unbuilt design.
- **An OCI tag as the only channel signal** (`:stable` vs `:nightly-<sha>`, no Composition label) —
  rejected: doesn't compose with Crossplane's own `compositionRevisionSelector` mechanism, and a dev
  install here (`make install-dev`) never produces an OCI package in the first place, so there would
  be nothing to tag.
- **GitHub-issue-only ADRs**, per the existing `knowledge-architecture.md` convention — superseded by
  this decision's own existence: see Consequences above.
