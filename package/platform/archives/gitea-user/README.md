# gitea-user

Crossplane Configuration package that manages a single Gitea user lifecycle — create, update, and delete — through a Kubernetes-native XR claim.

Each `XGiteaUser` claim maps to one `provider-terraform` Workspace that owns one `gitea_user` resource. Deleting the claim deletes the user from Gitea.

## Prerequisites

Install these once per cluster before applying any claims:

```bash
kubectl apply -f providers/archive/provider-terraform.yaml
kubectl apply -f providers/function-patch-and-transform.yaml
kubectl apply -f providers/archive/providerconfig-terraform.yaml
```

## Install

### From a registry (GitOps)

Update `spec.package` in `configuration.yaml` to point to your published image, then apply:

```bash
kubectl apply -f package/platform/gitea-user/configuration.yaml
```

Crossplane pulls the OCI image and installs the XRD and Composition automatically.

### For development (direct apply)

Apply the XRD and Composition directly without publishing:

```bash
kubectl apply -f package/platform/gitea-user/xrd.yaml
kubectl apply -f package/platform/gitea-user/composition.yaml
```

## Credentials secret

Create a Secret in `crossplane-system` with the admin token and the new user's initial password in tfvars format:

```bash
kubectl create secret generic gitea-user-credentials \
  --from-literal=credentials='gitea_token = "your-admin-token"
password = "initial-user-password"' \
  -n crossplane-system
```

## Usage

```yaml
apiVersion: platform.wxops.cloud/v1alpha1
kind: XGiteaUser
metadata:
  name: alice
spec:
  parameters:
    giteaUrl: https://gitea.example.com
    username: alice
    email: alice@example.com
    fullName: Alice Platform
    admin: false
    mustChangePassword: true
    credentialsSecretRef:
      name: gitea-user-credentials
      namespace: crossplane-system
```

See `examples/gitea-user/xr.yaml` for a working example.

## Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `giteaUrl` | string | yes | — | Base URL of the Gitea instance |
| `insecure` | bool | no | `false` | Skip TLS verification |
| `username` | string | yes | — | Login username |
| `email` | string | yes | — | Email address |
| `fullName` | string | no | `""` | Display name in Gitea UI |
| `admin` | bool | no | `false` | Grant site admin privileges |
| `mustChangePassword` | bool | no | `true` | Force password change on first login |
| `credentialsSecretRef.name` | string | yes | — | Secret name |
| `credentialsSecretRef.namespace` | string | yes | — | Secret namespace |

## Build and publish

```bash
# Build the OCI package
crossplane xpkg build \
  -f package/platform/gitea-user \
  --name gitea-user

# Push to a registry
crossplane xpkg push \
  ghcr.io/wxops-idp/wxops-core/gitea-user:release-YYYY-MM-DD \
  -f gitea-user.xpkg

# Push to a private Gitea registry
crossplane xpkg push \
  gitea.example.com/<owner>/gitea-user:release-YYYY-MM-DD \
  -f gitea-user.xpkg
```
