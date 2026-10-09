---
name: Bug report
about: Something in a published package doesn't behave as documented
title: "[BUG] "
labels: bug
assignees: ''

---

**Affected package**
Which one — `platform-database-clusters`, `tenant-database`, `tenant-app`,
`scm-connection`, `scm-repository`, `scm-oauth-app`, or not sure?

**Package / Crossplane version**
- Package version: [e.g. tenant-app v0.2.5 — from `spec.package` or `VERSIONS.yaml`]
- Crossplane version: [e.g. v2.3.1 — `crossplane version`]

**Describe the bug**
A clear and concise description of what's wrong.

**To reproduce**
The smallest `spec.parameters` that triggers it. If you can reproduce it
offline with `crossplane composition render` (see `tests/README.md`), even
better — that rules out anything cluster-specific.

```yaml
# minimal XR here
```

**Expected behavior**
What you expected to happen instead.

**Logs / output**
`kubectl describe` on the XR or any stuck composed resource, provider logs, or
render output. Redact anything sensitive.

**Additional context**
Anything else worth knowing.
