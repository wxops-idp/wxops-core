# Application Onboarding — Golden Path

End-to-end flow for taking a developer from "pick a flavor and template" to a running [`tenant-app`](../api-reference/platform/tenant-app.md), tying together the
templates catalog, [`scm-repository`](../api-reference/scm/repository.md), and `tenant-app`'s `appFlavor`/`templateId`/`repository.url`/`secretsFrom` fields.
The portal/scaffolder that drives this flow lives outside `wxops-core` — this doc describes the contract between it and the packages in this repo. Steps 1–2,
4–7 are pure portal-backend logic (the host's API + git operations); only steps 3 and 8 touch this repo's XRDs.

> `XGiteaRepository` was this step's kind before `scm-repository` shipped. It is archived (`docs/api-reference/_archives/gitea-repository.md`), not removed —
> kept for the record, not used by any current flow.

## 1. User picks `appFlavor`

`appFlavor` (`webapp`, `ai`, `ai-webapp`, `geo-webapp`, `search-webapp`) is the broad category. The portal uses it to **filter/recommend** which `templateId`s
are offered — e.g. `appFlavor: ai-webapp` surfaces templates with vectordb-ready skeletons. `appFlavor` and `templateId` are separate `tenant-app` fields
because they serve different downstream consumers: `appFlavor` drives platform automation (e.g. a separate `XTenantDatabase` claim's `pgvector`/`postgis`
extension choices), while `templateId` is a catalog/source-of-scaffold link. Neither affects any resource `tenant-app` itself composes.

## 2. User picks `templateId`

The portal resolves `templateId` to a path in the templates catalog repo — `templates/<templateId>/skeleton/` (see [Templates catalog](#templates-catalog)
below).

## 3. Create the application repository — `XScmRepository`

The portal creates an [`XScmRepository`](../api-reference/scm/repository.md) resource, naming the platform's
[`XScmConnection`](../api-reference/scm/connection.md) — the connection carries the host and the org, so neither appears here:

```yaml
spec:
  parameters:
    scmRef:
      name: <platform-scm-connection>
    repoName: <appName>
    autoInit: false   # scaffolder provides the first commit (step 6)
    visibility: private
```

Poll/wait for `status.htmlUrl`/`status.cloneUrl` — these become `tenant-app`'s `repository.url` (step 8) and the git push target (step 6).

> **Import existing repo**: skip steps 3–6 entirely. Set `repository.url` directly to the existing repo's URL in the `tenant-app` claim (step 8). No
> `XScmRepository` resource needed — or set `mode: observed` on one to still track it through the API.

## 4. Fetch the template skeleton

The portal fetches the tarball/tree of `templates/<templateId>/skeleton` at a ref from the catalog repo via the host's API (Gitea's `contents`/`archive`
endpoints, or GitHub's/GitLab's equivalents) and extracts it locally. This is a plain subpath fetch — it works whether the catalog repo is a single monorepo
with one subfolder per template, or separate per-template repos; the host doesn't need to know anything about "templates."

## 5. Render placeholders

The portal templates placeholders (`appName`, `namespace`, etc.) into the extracted files — e.g. Nunjucks/mustache-style substitution, matching whatever
convention the skeleton's `template.yaml` declares.

## 6. Commit + push the initial commit

The portal `git init`s the rendered tree and pushes it to the repo created in step 3 (`status.cloneUrl`), using the same host credential the `XScmConnection`
holds. This becomes the repo's initial commit on `defaultBranch`.

## 7. CI builds the image

CI defined by the skeleton itself (pushed as part of step 6) builds and publishes the container image, producing the `image` reference (`repository:tag`) used
in step 8.

## 8. Create the application — `tenant-app`

Once the repo exists and CI has produced an image, the portal creates the [`XTenantApp`](../api-reference/platform/tenant-app.md) claim:

```yaml
metadata:
  labels:
    wxops.cloud/owner: <team>                 # the owning team's slug — see Labels below
spec:
  parameters:
    appName: <appName>
    namespace: <tenant-namespace>
    appFlavor: <appFlavor>                    # from step 1
    templateId: <templateId>                  # from step 2
    repository:
      url: <html_url from step 3>             # catalog link only
    image: <repository:tag built by CI from step 7>
```

The namespace the app lands in already has its defaults from the team's `tenants/<name>/` directory — see
[Namespace defaults](#namespace-defaults--from-gitops). The claim itself goes in the app's environment overlay.

## 9. (Optional) Wire database secrets

If the app needs a database, create a [`tenant-database`](../api-reference/platform/tenant-database.md) claim first (or alongside), then set
`secretsFrom.database.enabled: true` on the `tenant-app` claim — see [tenant-app's go-live ordering
contract](../api-reference/platform/tenant-app.md#vault-secrets--databases) for why the database/secret claim must exist before (or alongside) `tenant-app`.

## Labels the platform reads

A handful of labels decide who owns an application, who may change it, and how the Portal and catalog show it as platform-managed. Owners are team slugs,
matched exactly: group `<org>:<team>` owns `<team>`.

**Set by the platform team, once per namespace** — only the platform team may change them (`namespace-guard`):

| Label | On | Value | What reads it |
|---|---|---|---|
| `auth.wxops.cloud/tenant-namespace` | `Namespace` | `"true"` | [`XPersonaBinding`](../api-reference/auth/persona-binding.md) `scope: owned` finds the team's namespaces by it; `owner-stamp` runs only there |
| `wxops.cloud/owner` | `Namespace` | `<team>` | The namespace's owner — every object inside inherits it, and the team's persona binding lands only here |
| `wxops.cloud/environment` | `Namespace` | `dev`, `staging`, `prod`, … | The namespace's environment. Where an [`env-gate`](../api-reference/auth/platform-policy.md) guards it, only the persona trusted with that environment changes it by hand; everyone else deploys through Git |

**Set by you, in Git:**

| Label | On | Value | Why |
|---|---|---|---|
| `wxops.cloud/owner` | The `XTenantApp` and `XTenantDatabase` XRs | `<team>` | They are cluster-scoped, so there is no namespace to inherit from: without the label, [`owner-seal`](../api-reference/auth/platform-policy.md) refuses every person's change to them. Must be one of your own teams |
| `wxops.cloud/owner` | Every manifest you keep in a tenant namespace | `<team>` | `owner-stamp` adds it on create if it is missing, but then the live object carries a label Git does not — keep it in Git so Argo CD and the cluster agree |
| `wxops.cloud/protected` | Objects only the platform team may change or delete | `"true"` | The `protected` template refuses everyone else's update and delete. Argo CD is not matched — add `Prune=false` to keep its sync from deleting them |

**Set by `tenant-app` itself** on every composed resource — don't set them, read them:

| Label or annotation | Value | Shows |
|---|---|---|
| `app.kubernetes.io/managed-by` | `crossplane` | The resource is managed by the platform — change it through the XR, never with `kubectl edit` or `kubectl scale` |
| `app.kubernetes.io/name`, `app.kubernetes.io/instance` | `<appName>` | Which application a resource belongs to |
| `wxops.cloud/environment` | `dev`, `staging` or `prod` | The environment, for dashboards, cost reports and policies |
| `wxops.cloud/app-flavor` | `webapp`, `ai`, … | The category, for platform automation (database extensions, generated policies) |
| `wxops.cloud/template-id`, `wxops.cloud/repo-url` (annotations) | from steps 2–3 | The catalog link — which template it was scaffolded from, where its source lives |

User `labels` on `tenant-app` cannot override these. Within a tenant namespace, ServiceAccounts carry `wxops.cloud/owner` too (stamped on create):
`sa-guard` lets a person's workload run only as `default` or a ServiceAccount their team owns.

## Namespace defaults — from GitOps

A tenant namespace's defaults — quota, limits, network policy and registry credentials — come from the **GitOps repository**, not from `wxops-core` and not
from a Kyverno generate rule ([decided 2026-11-08](../../development-docs/core-ideas/access-model.md#namespace-defaults-come-from-gitops--decided-2026-11-08)).
Argo CD syncs a team's namespace and its apps as separate Applications, from ApplicationSets with git directory generators:

```
├── tenants                      ApplicationSet → git directory generator
│   └── tenant-<name>            one per tenants/<name>/ directory — the namespace's defaults live here
└── tenants-apps                 two ApplicationSets in one file
    ├── tenants-apps             git dir: overlays/dev — auto-sync, prune + selfHeal
    │   └── <team>-<app>-dev
    └── tenants-apps-stable      git dir: overlays/staging + production — manual sync gate
        └── <team>-<app>-staging / <team>-<app>-production
```

- **`tenants/<name>/`** holds the namespace's `ResourceQuota`, `LimitRange`, `NetworkPolicy` (default-deny, plus same-namespace, the ingress controller and
  DNS) and registry credentials. A team that needs more changes its own directory by pull request.
- **The app's overlays** hold its `XTenantApp` claim (step 8): `dev` syncs on merge; `staging` and `production` wait for a manual sync — the same line
  [`env-gate`](../api-reference/auth/platform-policy.md) draws for people changing a guarded namespace by hand.

| Concern | How |
|---|---|
| Owner label | Set `wxops.cloud/owner: <team>` on the defaults in `tenants/<name>/`, so Argo CD and the cluster agree |
| Teams changing defaults by hand | Label them `wxops.cloud/protected: "true"`: the `protected` policy refuses people's edits and deletes — changes go through the PR |
| A sync removing one | Argo CD is not checked by `protected`; add `argocd.argoproj.io/sync-options: Prune=false` to defaults that must never disappear |
| Registry credentials | An ESO `ExternalSecret` (`kubernetes.io/dockerconfigjson`) from OpenBao, never a Secret in Git — or one ESO `ClusterExternalSecret` selecting `auth.wxops.cloud/tenant-namespace: "true"`. The app names it in `imagePullSecrets` |
| Production stricter than dev | Separate tenant directories per environment's namespace, each with its own defaults |

## Templates catalog

A single `software-templates` repo with one subfolder per language/stack — `templates/golang-service/`, `templates/python-service/`,
`templates/nodejs-service/`, etc. Each subfolder has its own `template.yaml` (Backstage scaffolder manifest) and skeleton source tree. `templateId` is the
subfolder name.

## Summary

| Step | Action | Package |
|---|---|---|
| 1 | Pick `appFlavor` (filters template choices) | metadata only |
| 2 | Pick `templateId` | external (templates catalog) |
| 3 | Create new app repo | [`scm-repository`](../api-reference/scm/repository.md) (skip if importing an existing repo) |
| 4 | Fetch template skeleton (tarball/tree) | external (portal) |
| 5 | Render placeholders | external (portal) |
| 6 | Commit + push initial commit | external (portal) |
| 7 | CI builds image | external (skeleton's CI config) |
| 8 | Application workload, in the app's environment overlay | [`tenant-app`](../api-reference/platform/tenant-app.md); namespace defaults from `tenants/<name>/` (GitOps) |
| 9 | Database + secrets (optional) | [`tenant-database`](../api-reference/platform/tenant-database.md) + platform `ExternalSecret`/`PushSecret` |
