# scm-repository

Creates a repository on Gitea or GitHub, or observes one that already exists, through a single
OpenTofu module.

The vendor is **not** in this resource's spec: it comes from the [`scm-connection`](../connection)
named in `scmRef`, so the same manifest works against either host. One `Workspace` runs one module
that declares both vendors' Terraform providers and gates every block on the vendor it was handed —
all vendor behaviour is HCL, and the composition contains none of it.

## Prerequisites

```bash
kubectl apply -k providers/
```

That brings `provider-opentofu` and its ProviderConfig. You also need an `XScmConnection` whose
credential Secret exists — see [`package/scm/connection`](../connection).

## Install

### From a registry (GitOps)

```bash
kubectl apply -f package/install/scm/scm-repository.yaml
```

### For development (direct apply)

```bash
kubectl apply -k package/scm/repository
```

## Usage

```yaml
apiVersion: scm.wxops.cloud/v1alpha1
kind: XScmRepository
metadata:
  name: team-alpha-api-service
  labels:
    wxops.cloud/owner: team-alpha
spec:
  parameters:
    scmRef:
      name: github-wxops   # the org comes from here — no org field on this resource
    mode: managed
    repoName: api-service
    visibility: private
    topics:
      - wxops-managed
```

See [`examples/scm-repository/xr.yaml`](../../../examples/scm-repository/xr.yaml).

## Modes

| Mode | What Core does |
|---|---|
| `managed` | Creates and owns the repository (a `resource` in the module) |
| `observed` | Only reads it (a `data` source); never writes or deletes. The creation fields are not applied |

Deleting the XR **keeps** the repository by default (`retain: true` orphans the `Workspace`). Set
`retain: false` to delete the repository with the XR.

## What differs per vendor

| Concern | Gitea | GitHub |
|---|---|---|
| Resource / data source | `gitea_repository` / `data.gitea_repo` | `github_repository` / `data.github_repository` |
| Owner | `username` on the resource | `owner` on the provider |
| Visibility | a `private` boolean | a `visibility` string |
| Default branch | an attribute | a separate `github_branch_default` resource |
| `topics` | **unsupported by the provider** — a non-empty list fails the apply instead of being dropped | supported |

## Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `scmRef.name` | string | yes | — | The `XScmConnection` to act through. Also the sole source of the org/owner — there is no `org` field here |
| `repoName` | string | yes | — | Repository name |
| `mode` | string | no | `managed` | `managed` or `observed` |
| `description` | string | no | `""` | |
| `visibility` | string | no | `private` | `private` or `public` |
| `defaultBranch` | string | no | `main` | Applied on GitHub only when `autoInit` is true |
| `autoInit` | bool | no | `true` | Create an initial commit |
| `hasIssues` | bool | no | `true` | |
| `hasWiki` | bool | no | `false` | |
| `topics` | []string | no | `[]` | GitHub only |
| `retain` | bool | no | `true` | Keep the repository when the XR is deleted |

Full reference: [`docs/api-reference/scm-repository.md`](../../../docs/api-reference/scm-repository.md).

## Build and publish

```bash
crossplane xpkg build \
  -f package/scm/repository \
  --ignore kustomization.yaml

crossplane xpkg push \
  ghcr.io/wxops-idp/wxops-core/scm-repository:release-YYYY-MM-DD \
  -f scm-repository.xpkg
```
