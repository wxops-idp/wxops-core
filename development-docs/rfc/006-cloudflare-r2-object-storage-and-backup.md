# RFC-006: Cloudflare R2 as the first third-party service — provisioned backup and object storage

## Status
<!-- Draft | In review | Accepted | Declined | Withdrawn | Implemented — and the GitHub issue that carries the discussion, e.g. "Draft · #42" -->
Draft

## Summary

Bring **Cloudflare R2** into Core as the first service that lives outside the cluster and outside the platform's own vendors:
Core provisions the bucket and a bucket-scoped credential, publishes that credential to OpenBao, and the platform consumes it.
It lands in stages. First, an R2 bucket for PostgreSQL backups, using the backup fields `XPlatformDatabaseCluster` already has.
Then a general `XObjectBucket` resource so tenants get object storage. Then lifecycle, retention and consumer wiring. The
RFC also defines the pattern any *later* third-party service follows, so R2 is the first instance of a design rather than a
one-off.

## Motivation

1. **Backup has nowhere to go.** `XPlatformDatabaseCluster` can already configure CloudNativePG's Barman backups and takes a
   `destinationPath`, `endpointURL` and a `credentialsSecretRef`, but the bucket, the credentials and the Secret must all exist
   before the XR is applied and are made by hand. A backup target that is hand-provisioned is a target nobody can enumerate,
   rotate or audit.
2. **Tenants have no object storage.** Applications that store files, exports or artifacts have no Core-provided place to put
   them, so each brings its own.
3. **There is no pattern for a third party.** Everything Core drives today is self-hosted or in-cluster. The next external
   service would otherwise invent its own answers to where the admin credential lives, how per-resource credentials are minted,
   who owns them, and what happens on deletion.

R2 is a good first case because it is S3-compatible (so the existing Barman fields work unchanged) and, per Cloudflare's own
pricing model, charges no egress fees — which is what makes a restore or a migration off it affordable rather than a bill.

## Detailed Design

### Scope

| In this RFC | Not in this RFC |
|---|---|
| Provisioning an R2 bucket and a bucket-scoped credential | Backing up anything other than PostgreSQL (Gitea, Velero, etcd) |
| `XObjectBucket`: a neutral object-storage resource, R2 first | A second storage vendor (a validation phase only, below) |
| The third-party service pattern | Cloudflare products other than R2 |
| Optional wiring into `XPlatformDatabaseCluster` and `XTenantApp` | CDN, public buckets and custom domains |

### The third-party pattern

Six rules, so the second service is a copy rather than a redesign:

1. **One account-level credential per environment, platform-only.** Whatever can create buckets and mint tokens is a powerful
   credential. Each environment's lives in that environment's OpenBao at `platform/…`, is read only by the provisioning
   `ProviderConfig`, and is never reachable by a tenant.
2. **Provisioning goes through the existing engine.** An OpenTofu `Workspace` ([RFC-002](002-migrate-terraform-to-opentofu.md))
   running the vendor's provider, as the `gitea-*` packages do. See Alternatives for the native-provider option.
3. **Each resource gets its own scoped credential**, minted at creation and pushed to OpenBao by the same `PushSecret` path as
   [RFC-003](003-scm-connections-and-resources.md) and [RFC-004](004-dex-identity-and-portal-authentication.md).
4. **Ownership is the `wxops.cloud/owner` label** and authorization is [RFC-005](005-git-mapped-authorization.md)'s.
5. **Deletion never destroys data by default.** Removing an XR retains the resource unless the XR says otherwise.
6. **Cost is a first-class attribute.** Every third-party resource can cost money; the design says what bounds it.

### API surface

```yaml
apiVersion: platform.wxops.cloud/v1alpha1   # workloads and data stay in `platform`, per ADR-002
kind: XObjectBucket
metadata:
  name: team-alpha-exports
  labels:
    wxops.cloud/owner: team-alpha
spec:
  parameters:
    provider: r2                 # r2 first; the field exists so a second backend is a new value, not a new kind
    bucketName: team-alpha-exports
    locationHint: weur           # R2 placement hint; optional
    jurisdiction: ""             # optional data-residency restriction, e.g. eu
    access: read-write           # read-write | read-only — the scope of the minted credential
    retain: true                 # default. false destroys the bucket with the XR, and only an empty bucket can be destroyed
    lifecycle:
      expireAfterDays: 0         # 0 = never
    rotation:
      generation: 1              # bump to rotate the credential
    accountRef: {name: cloudflare-prod}   # the environment's Cloudflare account; same indirection as RFC-003's `scmRef`, credential platform-only
status:
  created: true
  ready: true
  bucketName: team-alpha-exports
  endpoint: https://<account-id>.r2.cloudflarestorage.com
  vault:
    path: tenants/team-alpha/object-storage/team-alpha-exports/credentials
```

Both `status.created` and `status.ready` follow the [status contract](../../docs/api-reference/status-contract.md). The credential
never appears in status; only its Vault path does.

### Decisions taken

**One shared Cloudflare account per environment.** `dev`, `staging` and `prod` each have their own Cloudflare account, and every
tenant in an environment shares that environment's account. Isolation between tenants is the bucket-scoped token, not the
account. This keeps a development mistake or a leaked development credential away from production data, at the price of one
account-level credential to protect per environment rather than one in total. `accountRef` names the environment's account;
there is one `ProviderConfig` per environment, matching the per-environment OpenBao.

**Backups use CloudNativePG's built-in `barmanObjectStore`**, the configuration `XPlatformDatabaseCluster` already emits. That
avoids the reported R2 restore failure in the Barman Cloud plugin and needs no change to the composed resources. It has a
shelf life, and the RFC does not hide it: the built-in support has been deprecated since CloudNativePG 1.26, and its removal
has been scheduled for 1.30 and, in the most recent release notes found, 1.31 — sources disagree, so the pinned operator
version's notes are the authority. The repo's documentation targets 1.29. Moving to the plugin later changes what the
composition emits (an `ObjectStore` resource and plugin configuration in place of the inline block), so it is its own change
with its own RFC and ADR, triggered by the operator upgrade that would remove the built-in path, and it starts with the
restore test below.

### Credential and Vault layout

Cloudflare documents R2 API tokens that can be scoped to specific buckets with Object Read or Object Read & Write permission,
and the S3-compatible key pair is derived from the token: the access key id is the token id and the secret access key is the
SHA-256 of the token value. The composition mints one such token per bucket and per `access` level, and pushes it to OpenBao
with **the key names `XPlatformDatabaseCluster` already expects** (`ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`) plus `endpoint` and
`bucket`, so the existing backup fields consume it with no schema change.

| `owner` | `remoteKey` | Full logical path |
|---|---|---|
| `platform` | `object-storage/{bucketName}/credentials` | `platform/object-storage/{bucketName}/credentials` |
| a tenant | `{owner}/object-storage/{bucketName}/credentials` | `tenants/{owner}/object-storage/{bucketName}/credentials` |

`remoteKey` omits the KV mount prefix, per the [Vault path convention](../../CLAUDE.md#vault-path-convention).

**Rotation can be seamless here**, unlike a Dex client secret ([RFC-004](004-dex-identity-and-portal-authentication.md)): R2
allows more than one token per bucket, so the composition keeps the previous generation's token alive while the new one is
minted, published and picked up, then retires the old one at the *next* rotation. Consumers see a new KV v2 version and
continue on the old token in the meantime. That two-token overlap is a design intent to confirm in the spike.

### Composition

One `function-kcl` composition emitting, as usual, `Object`s and `Workspace`s:

1. a `Workspace` running the `cloudflare/cloudflare` provider: the bucket, its lifecycle rule, and the scoped token;
2. the ESO `PushSecret` and `ExternalSecret` pair, so OpenBao stays the source and consumers read from one place;
3. for `retain: true`, the Workspace is set to orphan on removal so a deleted XR cannot destroy the bucket.

No new Crossplane provider, so no new provider RBAC.

### Staged rollout — "gradually"

| Stage | What ships | Schema change |
|---|---|---|
| **1 — Backup bucket** | A platform-owned R2 bucket, made by `XObjectBucket`, whose credential feeds `XPlatformDatabaseCluster.backup` through `credentialsSecretRef`. A restore is proven. | none to `XPlatformDatabaseCluster` |
| **2 — Tenant buckets** | `XObjectBucket` open to tenants under [RFC-005](005-git-mapped-authorization.md)'s owner rule | none |
| **3 — Lifecycle and retention** | expiry rules; an object-lock or retention setting for backup buckets so a compromised credential cannot delete history | additive fields on `XObjectBucket` |
| **4 — Consumers** | optional `backup.bucketRef` on `XPlatformDatabaseCluster` and a `storage` reference on `XTenantApp` that resolve endpoint, path and credentials | additive optional fields |
| **5 — Second backend** | an in-cluster S3 service or another vendor behind `provider:`, to prove the API is genuinely neutral | additive enum value |

Stage 1 changes no released XRD, so it ships with no compatibility impact and the value is real before anything else is built.

### Restore is the acceptance test

A backup that has not been restored is a hope. Two known risks make this concrete rather than ceremonial:

- Upstream reports that CloudNativePG's Barman Cloud **plugin** created backups on R2 but could not restore
  ([cloudnative-pg/plugin-barman-cloud#411](https://github.com/cloudnative-pg/plugin-barman-cloud/issues/411)). This RFC uses the
  built-in `barmanObjectStore`, which the report does not cover, but that is an absence of evidence, so the drill runs against
  it and its result is recorded rather than assumed.
- Newer S3 client checksum behaviour has caused `x-amz-content-sha256` errors against S3-compatible stores, worked around
  with environment settings on the object store. Whether R2 needs them is to be found out, not assumed.

**No backup bucket is called done until a PostgreSQL cluster has been restored from it into a fresh cluster and the data
checked.** That drill is the exit criterion for Stage 1 and is repeated on any change to the backup path.

### GitOps streaming

`XObjectBucket` follows the path every Core resource takes: a commit, Argo CD, the XR, the Workspace calling Cloudflare, the
credential to OpenBao. Nothing secret is in Git; `status.vault.path` is what a consumer's `ExternalSecret` points at.

### Compatibility and change tier

One new package, `object-bucket`, `current: unreleased` in `VERSIONS.yaml`; adding a package is `safe`. Stage 3 and 4 fields are
additive. Nothing here removes or retypes a released field.

### Testing

- goldens: `retain` true and false, `access` both values, `jurisdiction` set and unset, owner `platform` vs a tenant
- `observed.yaml` readiness cases via `mkobserved.py`
- negative cases: bucket name outside the S3-style naming rules, `retain: false` combined with a non-empty-bucket guard,
  `access` outside the enum
- invariants: `remoteKey` has no KV mount prefix; no credential in any XR field or status; **`retain` defaults to `true`**; no
  RBAC emitted

Offline tests prove the rendered objects only. Whether Cloudflare accepts the HCL, whether the token and its S3 key pair
work, and whether a restore succeeds all need a real account. A free Cloudflare account is enough for a scratch e2e, and that
run belongs in the kind-based e2e tier when it exists.

## Drawbacks

- **A new trust boundary.** Backups and tenant data now sit with a third party, and one account-level credential can create or
  delete every bucket. That credential's protection is the whole security story of this RFC.
- **Single-vendor risk, per environment.** Losing an environment's Cloudflare account or credential loses that environment's data
  and its backups together, and every tenant in the environment shares that fate. The retention lock in Stage 3 mitigates
  deletion by a stolen credential; it does not mitigate account suspension.
- **The built-in backup path is on a clock** (above), so this RFC's backup design has a known migration due.
- **Cost that Core cannot cap.** R2 bills for stored data and operations. This RFC found no per-bucket size limit to rely on,
  so cost control is a count of buckets and monitoring, not a quota. A bucket-count limit is a policy, and RFC-005 capped its
  own rule set at five; that limit either needs a sixth rule and an amendment there or has to be enforced elsewhere.
- **Token creation through Terraform has known friction.** The Cloudflare Terraform provider has open reports around creating R2
  tokens ([#6626](https://github.com/cloudflare/terraform-provider-cloudflare/issues/6626)) and around exposing the S3 key pair
  ([#2713](https://github.com/cloudflare/terraform-provider-cloudflare/issues/2713)); deriving the secret by hashing works but
  is a convention rather than an API output. Behaviour differs across the provider's major versions.
- **Client secrets in OpenTofu state** again, alongside OpenBao.
- **S3-compatible is not S3.** The compatibility surface varies by feature; Barman's needs are the ones that matter and are the
  ones the spike must exercise.

## Alternatives

- **A native Crossplane provider for Cloudflare.** Several exist: `crossplane-contrib/provider-upjet-cloudflare`, an older
  `crossplane-contrib/provider-cloudflare`, and a family of R2-focused sub-providers that includes bucket lifecycle and lock
  resources. They avoid the Workspace layer and the state Secret, but the upjet-based ones are generated from the same
  Terraform provider and inherit its token behaviour, several are individually maintained, and each adds RBAC and a release to
  follow. Worth re-evaluating per candidate at implementation; the default here is the engine already in use.
- **Self-hosted S3 (MinIO or Ceph) only.** No third party and no egress bill, but it costs the operational burden and, for
  backup, puts the copy in the same failure domain as the cluster it protects.
- **A hyperscaler bucket (S3, GCS).** Mature and well supported by Barman, at egress prices that make restore expensive.
- **Hand-provisioned buckets, documented.** What exists today; no enumeration, rotation or ownership.
- **Do nothing for tenants**, provide only backup. A valid smaller cut: Stage 1 alone, with `XObjectBucket` deferred.

## Rollout Plan

- [ ] **Spike, before acceptance.** On a scratch Cloudflare account: mint a bucket-scoped token with the Terraform provider at the
  pinned version and confirm the derived S3 key pair works; confirm two tokens can coexist on one bucket; run a Barman backup
  **and a restore** with the built-in `barmanObjectStore`; check whether R2 needs the checksum workaround; confirm the
  bucket-name rules and how object lock behaves.
- [ ] **Stage 1 — backup bucket** and the restore drill above.
- [ ] **Stage 2 — tenant `XObjectBucket`.**
- [ ] **Stage 3 — lifecycle and retention lock.**
- [ ] **Stage 4 — `bucketRef` and `storage` consumers.**
- [ ] **Stage 5 — a second backend**, to prove the API.
- [ ] Add the `cloudflare/cloudflare` provider to `NOTICE` and the reference stack when Stage 1 lands.

On acceptance, ADRs for: the third-party pattern (the six rules), Workspace over a native provider for Cloudflare, and
retain-by-default deletion.

## Open Questions

1. **What does "at least a third party" cover?** This RFC reads it as *the first third-party service, with a pattern a second can
   follow*. If more than one third party is meant to ship together, the scope and the staging change.
2. **Native provider or Workspace?** The default is the Workspace; a mature provider could change that.
3. **Cost guard.** Bucket-count limit as an RFC-005 rule, a composition-side cap, or monitoring only?
4. **Cost attribution.** R2 bills per account, so tenants in an environment share one bill. Can per-owner storage and operation
   use be read per bucket well enough to attribute it, or is attribution out of scope?
5. **When to leave the built-in backup path.** Track the operator's removal release and schedule the plugin migration (and its
   R2 restore test) ahead of it. Who owns watching for that?
6. **Backup of the backup.** Is one R2 copy sufficient, or should a second, independent destination be a requirement before
   Stage 1 is called complete?
7. **Data residency.** Do any tenants need a jurisdiction-restricted bucket, and does that need to be a Stage 2 field or wait?
8. **Tenant self-service limits.** May any tenant create any number of buckets, or only up to an allowance set by the platform?
