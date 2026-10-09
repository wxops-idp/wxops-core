---
name: ADR — architecture decision proposal
about: Propose recording (or revisiting) a decision of lasting consequence
title: "[ADR] "
labels: adr, needs-review
assignees: ''

---

<!--
An ADR records ONE decision: context → decision → consequences. Use this
when the outcome constrains future work regardless of any single feature —
tool adoption, an architectural boundary, a convention, a deliberate
rejection. Use the RFC template instead when the open question is a design
with an option space; an accepted RFC often produces an ADR as its residue.

Revisiting an existing decision? Check development-docs/adr/README.md's index and the archived
development-docs/_archives/ROADMAP.md "Decided and rejected" for the standing rule: the burden is
to say WHAT CHANGED since the original decision — restating preference is not new information.
Link the original.
-->

## Decision to be made

One sentence, phrased as the decision — e.g. "Compositions never emit
Kubernetes RBAC", not "we should discuss RBAC".

## Status

Proposed <!-- → Accepted / Declined / Supersedes #NNN -->

## Context

The forces at play: what makes this decision necessary now, what constraints
bound it (existing ADRs/decisions, the reference stack, security posture),
and what happens if it stays undecided.

## Options

| Option | For | Against |
|---|---|---|
| A — … | | |
| B — … | | |

## Recommendation

Which option and the deciding argument — the one consideration that outweighs
the others, not a restatement of the whole table.

## Consequences

What becomes easier, what becomes harder, and what this commits us to
maintaining or enforcing (invariant? CI check? doc?). Honest costs included —
a consequences section with no downsides wasn't finished.

---
<!--
Lifecycle: on acceptance, the decision is committed as development-docs/adr/NNN-title.md
(see development-docs/adr/README.md), with this issue linked as the permanent, immutable
record. A later reversal is a NEW ADR issue that supersedes this one —
this issue is never edited after acceptance.
-->
