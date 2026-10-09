# Application Onboarding — Golden Path

End-to-end flow for taking a developer from "pick a flavor and template" to
a running [`tenant-app`](../api-reference/tenant-app.md), tying together the templates
catalog, [`scm-repository`](../api-reference/scm-repository.md), and `tenant-app`'s
`appFlavor`/`templateId`/`repository.url`/`secretsFrom` fields. The
portal/scaffolder that drives this flow lives outside `wxops-core` — this
doc describes the contract between it and the packages in this repo. Steps
1–2, 4–7 are pure portal-backend logic (the host's API + git operations); only
steps 3 and 8 touch this repo's XRDs.

> `XGiteaRepository` was this step's kind before `scm-repository` shipped. It is archived
> (`docs/api-reference/_archives/gitea-repository.md`), not removed — kept for the record, not
> used by any current flow.

## 1. User picks `appFlavor`

`appFlavor` (`webapp`, `ai`, `ai-webapp`, `geo-webapp`, `search-webapp`) is
the broad category. The portal uses it to **filter/recommend** which
`templateId`s are offered — e.g. `appFlavor: ai-webapp` surfaces templates
with vectordb-ready skeletons. `appFlavor` and `templateId` are separate
`tenant-app` fields because they serve different downstream consumers:
`appFlavor` drives platform automation (e.g. a separate `XTenantDatabase`
claim's `pgvector`/`postgis` extension choices), while `templateId` is a
catalog/source-of-scaffold link. Neither affects any resource `tenant-app`
itself composes.

## 2. User picks `templateId`

The portal resolves `templateId` to a path in the templates catalog repo —
`templates/<templateId>/skeleton/` (see [Templates catalog](#templates-catalog)
below).

## 3. Create the application repository — `XScmRepository`

The portal creates an [`XScmRepository`](../api-reference/scm-repository.md) resource, naming
the platform's [`XScmConnection`](../api-reference/scm-connection.md) — the connection carries
the host and the org, so neither appears here:

```yaml
spec:
  parameters:
    scmRef:
      name: <platform-scm-connection>
    repoName: <appName>
    autoInit: false   # scaffolder provides the first commit (step 6)
    visibility: private
```

Poll/wait for `status.htmlUrl`/`status.cloneUrl` — these become `tenant-app`'s
`repository.url` (step 8) and the git push target (step 6).

> **Import existing repo**: skip steps 3–6 entirely. Set `repository.url`
> directly to the existing repo's URL in the `tenant-app` claim (step 8). No `XScmRepository`
> resource needed — or set `mode: observed` on one to still track it through the API.

## 4. Fetch the template skeleton

The portal fetches the tarball/tree of `templates/<templateId>/skeleton`
at a ref from the catalog repo via the host's API (Gitea's `contents`/`archive` endpoints, or
GitHub's/GitLab's equivalents) and extracts it locally. This is a plain subpath fetch — it
works whether the catalog repo is a single monorepo with one subfolder per
template, or separate per-template repos; the host doesn't need to know
anything about "templates."

## 5. Render placeholders

The portal templates placeholders (`appName`, `namespace`, etc.) into the
extracted files — e.g. Nunjucks/mustache-style substitution, matching
whatever convention the skeleton's `template.yaml` declares.

## 6. Commit + push the initial commit

The portal `git init`s the rendered tree and pushes it to the repo created
in step 3 (`status.cloneUrl`), using the same host credential the `XScmConnection` holds. This
becomes the repo's initial commit on `defaultBranch`.

## 7. CI builds the image

CI defined by the skeleton itself (pushed as part of step 6) builds and
publishes the container image, producing the `image` reference (`repository:tag`)
used in step 8.

## 8. Create the application — `tenant-app`

Once the repo exists and CI has produced an image, the portal creates the
[`XTenantApp`](../api-reference/tenant-app.md) claim:

```yaml
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

## 9. (Optional) Wire database secrets

If the app needs a database, create a [`tenant-database`](../api-reference/tenant-database.md)
claim first (or alongside), then set
`secretsFrom.database.enabled: true` on the `tenant-app` claim — see
[tenant-app's go-live ordering contract](../api-reference/tenant-app.md#vault-secrets--databases)
for why the database/secret claim must exist before (or alongside)
`tenant-app`.

## Templates catalog

A single `software-templates` repo with one subfolder per language/stack —
`templates/golang-service/`, `templates/python-service/`,
`templates/nodejs-service/`, etc. Each subfolder has its own `template.yaml`
(Backstage scaffolder manifest) and skeleton source tree. `templateId` is
the subfolder name.

## Summary

| Step | Action | Package |
|---|---|---|
| 1 | Pick `appFlavor` (filters template choices) | metadata only |
| 2 | Pick `templateId` | external (templates catalog) |
| 3 | Create new app repo | [`scm-repository`](../api-reference/scm-repository.md) (skip if importing an existing repo) |
| 4 | Fetch template skeleton (tarball/tree) | external (portal) |
| 5 | Render placeholders | external (portal) |
| 6 | Commit + push initial commit | external (portal) |
| 7 | CI builds image | external (skeleton's CI config) |
| 8 | Application workload | [`tenant-app`](../api-reference/tenant-app.md) |
| 9 | Database + secrets (optional) | [`tenant-database`](../api-reference/tenant-database.md) + platform `ExternalSecret`/`PushSecret` |
