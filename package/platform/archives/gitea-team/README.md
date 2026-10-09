# gitea-team

Crossplane Configuration package that manages a Gitea team and its membership within an organization through a Kubernetes-native XR claim.

Each `XGiteaTeam` claim owns:
- One `gitea_team` resource (the team itself)
- One `gitea_team_membership` resource per member in the `members` list

Membership is **fully reconciled** on every sync — adding or removing a username from `members` adds or removes that user from the team on the next reconcile cycle. This makes team membership GitOps-native: a pull request to the XR manifest is the authoritative change process.

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
kubectl apply -f package/platform/gitea-team/configuration.yaml
```

### For development (direct apply)

```bash
kubectl apply -f package/platform/gitea-team/xrd.yaml
kubectl apply -f package/platform/gitea-team/composition.yaml
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
kind: XGiteaTeam
metadata:
  name: team-alpha-backend
spec:
  parameters:
    giteaUrl: https://gitea.example.com
    orgName: team-alpha
    teamName: backend
    description: Backend engineers
    permission: write
    units: "repo.code,repo.issues,repo.pulls,repo.releases"
    members: "alice,bob"
    credentialsSecretRef:
      name: gitea-credentials
      namespace: crossplane-system
```

See `examples/gitea-team/xr.yaml` for a working example.

## Managing membership via GitOps

To add a member, open a PR that appends their username to `members`:

```yaml
members: "alice,bob,carol"   # carol added
```

To remove a member, open a PR that removes their username:

```yaml
members: "alice,carol"       # bob removed
```

Crossplane reconciles the diff and calls the Gitea API. No manual Gitea UI interaction needed.

## Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `giteaUrl` | string | yes | — | Base URL of the Gitea instance |
| `insecure` | bool | no | `false` | Skip TLS verification |
| `orgName` | string | yes | — | Organization the team belongs to |
| `teamName` | string | yes | — | Team name within the organization |
| `description` | string | no | `""` | Team description |
| `permission` | string | no | `read` | `none`, `read`, `write`, `admin`, or `owner` |
| `units` | string | no | `repo.code,repo.issues,repo.pulls` | Comma-separated feature units |
| `includeAllRepositories` | bool | no | `false` | Auto-grant access to all org repos |
| `canCreateRepos` | bool | no | `false` | Allow members to create org repositories |
| `members` | string | no | `""` | Comma-separated Gitea usernames |
| `credentialsSecretRef.name` | string | yes | — | Secret name |
| `credentialsSecretRef.namespace` | string | yes | — | Secret namespace |

### Valid `units` values

| Unit | Feature |
|---|---|
| `repo.code` | Code browser |
| `repo.issues` | Issues |
| `repo.ext_issues` | External issues |
| `repo.wiki` | Wiki |
| `repo.pulls` | Pull requests |
| `repo.releases` | Releases |
| `repo.projects` | Projects |
| `repo.ext_wiki` | External wiki |

## Build and publish

```bash
crossplane xpkg build \
  -f package/platform/gitea-team \
  --name gitea-team

crossplane xpkg push \
  ghcr.io/wxops-idp/wxops-core/gitea-team:release-YYYY-MM-DD \
  -f gitea-team.xpkg
```
