# gitea-repository

Crossplane Configuration package that manages a single Gitea repository lifecycle — create, update, and delete — through a Kubernetes-native XR claim.

Each `XGiteaRepository` claim maps to one `provider-terraform` Workspace owning one `gitea_repository` resource. This is the primary target for IDP scaffolding flows: a developer portal or template engine emits one claim per repository, and Crossplane reconciles it independently of all other repositories.

## Prerequisites

Install these once per cluster before applying any claims:

```bash
kubectl apply -f providers/archive/provider-terraform.yaml
kubectl apply -f providers/function-patch-and-transform.yaml
kubectl apply -f providers/archive/providerconfig-terraform.yaml
```

## Install

### From a registry (GitOps)

```bash
kubectl apply -f package/platform/gitea-repository/configuration.yaml
```

### For development (direct apply)

```bash
kubectl apply -f package/platform/gitea-repository/xrd.yaml
kubectl apply -f package/platform/gitea-repository/composition.yaml
```

## Credentials secret

```bash
kubectl create secret generic gitea-credentials \
  --from-literal=credentials='gitea_token = "your-admin-token"' \
  -n crossplane-system
```

## Usage

```yaml
apiVersion: platform.wxops.cloud/v1alpha1
kind: XGiteaRepository
metadata:
  name: team-alpha-api-service
spec:
  parameters:
    giteaUrl: https://gitea.example.com
    orgName: team-alpha
    repoName: api-service
    description: Alpha squad API service
    private: true
    autoInit: true
    defaultBranch: main
    hasIssues: true
    hasPullRequests: true
    credentialsSecretRef:
      name: gitea-credentials
      namespace: crossplane-system
```

See `examples/gitea-repository/xr.yaml` for a working example.

## IDP scaffolding integration

When a developer portal (Backstage, Port, etc.) scaffolds a new service, it emits a `XGiteaRepository` manifest and commits it to the GitOps repository. Crossplane picks it up and creates the repository — no manual Gitea UI interaction needed.

The connection secret written after provisioning exposes:

| Key | Value |
|---|---|
| `repo_id` | Numeric Gitea repository ID |
| `clone_url` | HTTPS clone URL |
| `ssh_url` | SSH clone URL |
| `html_url` | Web browser URL |

Use these in downstream scaffolding steps (e.g. seeding the repo with template files, configuring CI).

## Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `giteaUrl` | string | yes | — | Base URL of the Gitea instance |
| `insecure` | bool | no | `false` | Skip TLS verification |
| `orgName` | string | yes | — | Organization that owns the repository |
| `repoName` | string | yes | — | Repository name (immutable after creation) |
| `description` | string | no | `""` | Short description |
| `private` | bool | no | `false` | Make the repository private |
| `autoInit` | bool | no | `true` | Initialize with a README |
| `defaultBranch` | string | no | `main` | Default branch name |
| `hasIssues` | bool | no | `true` | Enable issues |
| `hasWiki` | bool | no | `false` | Enable wiki |
| `hasProjects` | bool | no | `false` | Enable projects |
| `hasPullRequests` | bool | no | `true` | Enable pull requests |
| `credentialsSecretRef.name` | string | yes | — | Secret name |
| `credentialsSecretRef.namespace` | string | yes | — | Secret namespace |

## Build and publish

```bash
crossplane xpkg build \
  -f package/platform/gitea-repository \
  --name gitea-repository

crossplane xpkg push \
  ghcr.io/wxops-idp/wxops-core/gitea-repository:release-YYYY-MM-DD \
  -f gitea-repository.xpkg
```
