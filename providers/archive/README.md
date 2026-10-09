# providers/archive

Provider and function manifests that no active package uses any more. They are **kept, not removed**,
so the reasoning and the pinned versions stay discoverable, and they are **not installed**: `make
providers` applies `PROVIDER_MANIFESTS` (function/provider/runtimeconfig/rbac files directly under
`providers/`), which does not descend into this directory.

| File | Why archived | Reference |
|---|---|---|
| `function-go-templating.yaml` | No Composition uses it; KCL (`function-kcl`) covers conditional composition, and `function-patch-and-transform` the single-resource Workspaces. | [`kcl/README.md`](../../kcl/README.md) |
| `provider-terraform.yaml`, `providerconfig-terraform.yaml` | Superseded by `provider-opentofu` for all new work. The only packages that ran on it — `gitea-user`/`-org`/`-team`/`-repository` — are themselves archived (see `package/platform/archives/`), so nothing active needs this provider. If those packages are ever resurrected, this file and its `ProviderConfig` go with them. | [RFC-002](../../development-docs/rfc/002-migrate-terraform-to-opentofu.md) |

Archiving is not uninstalling. A cluster that already runs one of these keeps it until an operator
removes it by hand.
