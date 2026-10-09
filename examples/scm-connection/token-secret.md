# Seeding a connection's token

The host token is the one secret Core cannot create: it is what Core authenticates *with*. An
operator writes it to the secret store, and the `XScmConnection` renders it into the Secret that
every consumer's `Workspace` reads.

Write the token at `platform/scm/<connection-name>/credentials`, property `token`. With OpenBao's
`bao` CLI, for a connection named `github-wxops`:

```bash
export BAO_ADDR=https://openbao.example.com     # or a port-forward to the in-cluster service
bao login                                       # however your operators authenticate
bao kv put platform/scm/github-wxops/credentials token="$GITHUB_TOKEN"
```

Read it back to confirm the property name is `token`, which is what the connection's `tokenKey`
defaults to:

```bash
bao kv get platform/scm/github-wxops/credentials
```

(`vault` is interchangeable here — OpenBao forked the CLI and the KV v2 API is the same. This repo
targets OpenBao, so its own command is the one documented.)

The `ClusterSecretStore` (`vault-platform` by default) is already scoped to the `platform/` mount,
which is why the composition's `remoteKey` is `scm/github-wxops/credentials` and not the full path —
see the [Vault path convention](../../CLAUDE.md#vault-path-convention).

## What the token needs to be able to do

| Vendor | Token | Scope |
|---|---|---|
| GitHub | a personal access token, or a GitHub App installation token | **`Administration: Read and write`** (fine-grained) or `repo` + `delete_repo` (classic) for `mode: managed` — creating *or* deleting a repository is an `Administration` action on GitHub, not a `Contents` one, whether the owner is an org or your own personal account. `read:org` is enough for `access: read`/observation only. |
| Gitea | an admin API token (Settings → Applications → Generate Token) | `repo:read and write`, plus `org:read and write` to create in an org |

`Contents: Read and write` only covers files *inside* a repository that already exists — it does nothing for `github_repository`'s
create/update/delete, which is why `Administration` is the one that's actually required. Verified against a real connection: a token
with `Contents` but not `Administration` fails at GitHub's own permission check before the apply ever gets to create anything.

**This is a broad grant, and it is supposed to look that way** — not a W'xOps design choice. Two things about GitHub itself make it
unavoidably broad for `mode: managed`:

- **Scope is "all or nothing" for repos that don't exist yet.** A fine-grained PAT's "only select repositories" option can only list
  repositories you already have — there is nothing to select for one `XScmRepository` is about to create. Granting `Administration` to
  *new* repos means granting it to **all repositories** the account owns.
- **`Administration` covers delete, not just create.** Terraform's own resource model expects to be able to reconcile or destroy what
  it manages, so the provider checks for delete capability up front, even though an ordinary `apply` never calls it.

Give a `read`-only token to a connection declared `access: read` — that one only needs `Contents: Read` or `read:org`, no
`Administration` at all, so most tenant-observation connections never need this broad a grant in the first place. For a `managed`
connection, the usual mitigations apply here the same as anywhere else a token holds broad access: a dedicated bot/service account
rather than a human's own PAT, and the token only ever lives in OpenBao — never in Git, never in an XR, never in this repo.
