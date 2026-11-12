# Migrating to the new kinds

[ADR-005](../../development-docs/adr/005-kind-ownership-scope-and-naming.md) renamed four kinds and moved two of them to a new API group. Each new kind is built **beside**
the old one, and a live XR moves across by a handover: the old XR stops writing, the new one takes over the same resources, and the old one is deleted with nothing behind it.
`release-2026-11-12` ships the new kinds and archives the old ones together. This page is the runbook, run on each cluster **before** that cluster takes the archive.

| Old kind (archived) | New kind | API group | Scope | Runbook |
|---|---|---|---|---|
| `XPlatformPolicy` | `XPolicy` | `auth.wxops.cloud` | Cluster | [Move](#xplatformpolicy--xpolicy) |
| `XPlatformDatabaseCluster` | `XDatabaseCluster` | `platform.wxops.cloud` | Cluster | [Move](#xplatformdatabasecluster--xdatabasecluster) |
| `XTenantApp` | `XApp` | `tenant.wxops.cloud` (new) | **Namespaced** | [Move](#xtenantapp--xapp) |
| `XTenantDatabase` | `XDatabase` | `tenant.wxops.cloud` (new) | **Namespaced** | [Move](#xtenantdatabase--xdatabase) |

## Where the handover runs

The handover is the `wxops.cloud/handover: "true"` annotation, and only the old packages as this release's source has them honour it — `release-2026-11-09`'s do not.

| How the cluster is installed | How it hands over |
|---|---|
| From source, `make install-dev` | `make install-dev` for the new kinds, plus `kubectl apply -k package/dev/archived/` for the old ones with the handover. Run the runbook, then stop applying `package/dev/archived/`. |
| From the registry, `make install` | Not with this release alone: no registry image carries the old packages with the handover. Such a cluster needs a release that still ships them beside the new kinds before it takes the archive. |

## Order, and what must be true before the archive release

Move in this order, in the sandbox first and then on each real cluster: **policies**, then **database clusters**, then **apps**, then **databases** — a dedicated database last,
because its cluster moves with it. A database reads its cluster from the platform's `XDatabaseCluster`s, so those go before it.

**The archive release removes the four old kinds' definitions, and deleting an XRD deletes its XRs.** Upgrade a cluster to it only when this prints nothing:

```bash
kubectl get xplatformpolicies,xplatformdatabaseclusters,xtenantapps,xtenantdatabases -A --no-headers 2>/dev/null   # must be empty
```

Also check that no Git manifest, `ApplicationSet` or dashboard still names the old kinds — `git grep -E 'XPlatformPolicy|XPlatformDatabaseCluster|XTenantApp|XTenantDatabase'` in
your GitOps repository — or Argo CD recreates an XR whose kind no longer exists and reports it as unknown.

**Upgrading.** `make install` (`kubectl apply -k`) adds and updates Configurations but never deletes one, so the four old `Configuration`s stay installed until you remove them,
and only then do their XRDs go. When the check above is empty:

```bash
kubectl delete configuration.pkg.crossplane.io wxops-core-platform-policy wxops-core-platform-database-clusters wxops-core-tenant-app wxops-core-tenant-database
kubectl delete clusterrole wxops:piece:platform-tenant-write --ignore-not-found     # the RBAC piece for the old kinds; `make providers-rbac` no longer applies it
```

An Argo CD `Application` with pruning does the first step by itself when its `package/install` no longer lists them — which is why the check comes first.
`make providers-rbac` and `make providers-config` apply the persona pieces and the hub's `ClusterProviderConfig` the new kinds need.

## The handover

A new XR renders the same objects as the old one, so the real resource — a Kyverno policy, a Deployment, a database cluster — is never rebuilt. The only
question is who writes it while you move. The annotation `wxops.cloud/handover: "true"` answers that, on the old XR:

- its composed objects become **observe-only**: they keep watching the resource and stop writing it;
- they are set to **orphan** on delete, so deleting the XR leaves the resource where it is.

The new kind is honoured the same way, so a handover can be undone from either side. Without the annotation, an XR renders exactly as it did before.

On the old, cluster-scoped kinds that is `managementPolicies: [Observe]` and `deletionPolicy: Orphan`, which the checks below read. A **namespaced** `Object` (what `XApp` and
`XDatabase` compose) has no `deletionPolicy` at all: observe-only means no `Delete` among its management policies, which orphans just the same, so the new kinds show only
`MANAGEMENT`.

The steps, for one XR. Run them in the sandbox first, then on each real cluster — and in GitOps, as commits, in the same order:

1. **Record** the real resource, so you can prove it was not recreated.
2. **Annotate** the old XR with `wxops.cloud/handover: "true"`, and check its objects are observe-only.
3. **Create** the new kind with the same name and the same parameters, and wait until it is `READY`.
4. **Check** the real resource is the same one, and is now written by the new XR.
5. **Delete** the old XR, and check the real resource is still there.

**Undo before step 5:** annotate the *new* XR with `wxops.cloud/handover: "true"`, delete it, then remove the annotation from the old XR. The old XR writes
the resource again. Do not delete the new XR first: it is the one writing the resource, and deleting it deletes the resource.

## `XPlatformPolicy` → `XPolicy`

`XPolicy` takes exactly the parameters of `XPlatformPolicy`, so the new manifest is the old one with a new `kind:`. The Kyverno policy is named after the XR
(`wxops-<name>`), so a new XR with the same name writes the policy the old one wrote — enforcement does not lapse. A policy has no data, so this is the
lowest-risk move of the four, and it goes first.

```bash
NAME=<policy name>

# 1. Record the Kyverno policy. The kind is validatingpolicy, or mutatingpolicy for owner-stamp.
kubectl get validatingpolicy wxops-$NAME -o jsonpath='{.metadata.uid}{"\n"}'

# 2. Hand it over, then check the objects are observe-only (a few seconds):
kubectl annotate xplatformpolicy $NAME wxops.cloud/handover=true
kubectl get objects.kubernetes.crossplane.io -l crossplane.io/composite=$NAME \
  -o custom-columns=NAME:.metadata.name,MANAGEMENT:.spec.managementPolicies,ON-DELETE:.spec.deletionPolicy
```

Expect `[Observe]` and `Orphan`. If you see `[*]`, wait for a reconcile; if it stays, stop — the policy is still being written by the old XR, which is safe but
means the handover has not taken hold.

```bash
# 3. Create the new XR: the same manifest with `kind: XPolicy`.
kubectl get xpolicy $NAME
```

`READY` must be `True`. A `syncMessage` names whatever it could not render, as it does on the old kind.

```bash
# 4. The same policy, not a new one: the uid matches step 1.
kubectl get validatingpolicy wxops-$NAME -o jsonpath='{.metadata.uid}{"\n"}'

# 5. Delete the old XR, then check the policy survived and the new XR still owns it.
kubectl delete xplatformpolicy $NAME
kubectl get validatingpolicy wxops-$NAME
kubectl get xpolicy $NAME -o jsonpath='{.status.ready}{"\n"}'
```

In GitOps, step 2 is a commit adding the annotation, step 3 a commit adding the `XPolicy`, and step 5 a commit removing the `XPlatformPolicy`. Argo CD pruning
the old XR is safe once the annotation is in place, because its objects orphan.

**Prove enforcement is continuous.** On the sandbox, keep a refused request running through steps 2 to 5 — for example `./run.sh` in
[`examples/auth/policy/scenarios/`](../../examples/auth/policy/scenarios) — and confirm no row flips to allowed. The scenario kit now applies `XPolicy`.

**What to change besides the manifest.** Commands and dashboards that name the old kind: `kubectl get xplatformpolicy` becomes `kubectl get xpolicy`, and the
`wxops:piece:platform-admin-write` role needs nothing, because it already covers the whole `auth.wxops.cloud` group.

## `XPlatformDatabaseCluster` → `XDatabaseCluster`

An `XDatabaseCluster` takes exactly the parameters of `XPlatformDatabaseCluster`, so the new manifest is the old one with a new `kind:`. Keep the
`wxops.cloud/managed-by: platform-database-clusters` label as it is: it is how `XTenantDatabase` finds shared pools, and `tenant-database` now reads the pool
under **both** kinds, counting a cluster that exists under both once. A cluster **holds data**, so this move is checked harder than a policy's.

**Before you start**

- Install the `database-cluster` package **before** `tenant-database` takes the release that reads it (`make install` does both). A pool lookup for a kind whose
  XRD is not installed is an error, which would stop every `XTenantDatabase` from rendering.
- Have a recent backup. If the cluster has `backup` on, check the last `ScheduledBackup` ran; if not, take a CNPG `Backup` now.
- A cluster composed as a **dedicated** database's child (`tier: dedicated`) is not moved here: it belongs to its `XTenantDatabase` and moves with it.

```bash
NAME=<XR name>              # the XPlatformDatabaseCluster
CLUSTER=<spec.parameters.clusterName>
NS=<spec.parameters.namespace>

# 1. Record what must survive: the CNPG cluster, both credential Secrets, and the provider-sql ProviderConfig every tenant database connects through.
kubectl -n $NS get cluster.postgresql.cnpg.io $CLUSTER -o jsonpath='{.metadata.uid}{"\n"}'
kubectl -n $NS get secret $CLUSTER-superuser $CLUSTER-app -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.uid} {.data.password}{"\n"}{end}' | sha256sum   # hashed: never print a password
kubectl get providerconfigs.postgresql.sql.crossplane.io $CLUSTER -o jsonpath='{.metadata.uid}{"\n"}'

# 2. Hand it over, then check EVERY composed object is observe-only and orphans on delete (a few seconds):
kubectl annotate xplatformdatabasecluster $NAME wxops.cloud/handover=true
kubectl get objects.kubernetes.crossplane.io -l crossplane.io/composite=$NAME \
  -o custom-columns=NAME:.metadata.name,MANAGEMENT:.spec.managementPolicies,ON-DELETE:.spec.deletionPolicy
```

**Stop here unless every row shows `[Observe]` and `Orphan`.** Deleting the old XR in step 5 deletes any object that is not orphaned, and one of them is the CNPG
`Cluster`. If a row still shows `[*]` or `Delete`, wait a reconcile and look again; if it stays, do not go on.

```bash
# 3. Create the new XR: the same manifest with `kind: XDatabaseCluster`. Wait until it is ready.
kubectl get xdatabasecluster $NAME

# 4. The same cluster, the same credentials: re-run the three commands from step 1 and compare — the uids and the hash must match (no rotation, nothing recreated).

# 5. Delete the old XR. Then check the cluster, both Secrets and the ProviderConfig are still there, and the pool is intact:
kubectl delete xplatformdatabasecluster $NAME
kubectl -n $NS get cluster.postgresql.cnpg.io $CLUSTER
kubectl -n $NS get pushsecret $CLUSTER-superuser-push $CLUSTER-app-push
kubectl get xdatabasecluster $NAME -o jsonpath='{.status.ready}{" "}{.status.shared}{"\n"}'
```

In GitOps the order is the same, as three commits: the annotation, the `XDatabaseCluster`, then the removal of the `XPlatformDatabaseCluster`. Argo CD pruning the old
XR is safe only after step 2's check.

**Then prove the pool still works:** create or update an `XTenantDatabase` with `tier: shared` on the sandbox and check it is assigned to the cluster you moved.
Two pushes to OpenBao use `deletionPolicy: Delete` — the superuser and app entries under `database-clusters/<cluster>/` — so check they are still in OpenBao too.

**Undo before step 5:** annotate the *new* XR with `wxops.cloud/handover: "true"`, delete it, then remove the annotation from the old XR.

## `XTenantApp` → `XApp`

This is the one move that changes where an XR lives. `XTenantApp` is cluster-scoped and typed its own `namespace`; an `XApp` is created **in the team's namespace**,
which decides where it runs and who owns it. Everything else is the same scaffold, so the running Deployment, Service and IngressRoute are adopted, not rebuilt.

**Before you start**

- The `app` package is installed, the hub's `ClusterProviderConfig` is applied (`make providers-config`), and the persona pieces are applied (`make providers-rbac`).
  The team's persona then needs a `scope: owned` binding in the namespace — see [RFC-010](../../development-docs/rfc/010-namespaced-tenant-kinds.md).
- **The namespace has an owner.** An `XApp` in a namespace with no `wxops.cloud/owner` renders nothing and says why. Check it first:
  `kubectl get namespace <ns> -L wxops.cloud/owner`.
- An `XTenantApp` with `spec.parameters.cluster` set to anything but the hub **stays where it is**: `XApp` has no `cluster`, and the platform will map an
  environment to a cluster once multi-cluster exists.

**The new manifest** is the old one with these changes — `kubectl get xtenantapp <name> -o yaml` is the starting point:

| In the `XTenantApp` | In the `XApp` |
|---|---|
| `metadata.name: <anything>` | `metadata.name: <the old appName>` — or keep the name and set `appName: <the old appName>` |
| _(cluster-scoped)_ | `metadata.namespace: <the old spec.parameters.namespace>` |
| `parameters.namespace`, `parameters.cluster` | removed |
| `parameters.environment` left out (it defaulted to `dev`) | **`environment: dev`, written out** |
| `parameters.labels` with keys under `wxops.cloud/` | those keys removed — the platform sets them |

The `environment` line matters: `XTenantApp` labelled the pods `wxops.cloud/environment: dev` by default and `XApp` has no default, so leaving it out changes the pod
template and **restarts the application**. If the old XR set `environment`, copy it as it is.

```bash
NS=<namespace>
APP=<appName>               # the application's name: its Deployment's name
OLD=<XTenantApp name>

# 1. Record what must not change: the Deployment, and the generation that counts spec changes (a rollout would raise it), and the pods.
kubectl -n $NS get deployment $APP -o jsonpath='{.metadata.uid} {.metadata.generation}{"\n"}'
kubectl -n $NS get pods -l app.kubernetes.io/instance=$APP -o name

# 2. Hand it over, then check EVERY composed object is observe-only and orphans on delete (a few seconds):
kubectl annotate xtenantapp $OLD wxops.cloud/handover=true
kubectl get objects.kubernetes.crossplane.io -l crossplane.io/composite=$OLD \
  -o custom-columns=NAME:.metadata.name,MANAGEMENT:.spec.managementPolicies,ON-DELETE:.spec.deletionPolicy
```

**Stop here unless every row shows `[Observe]` and `Orphan`** — deleting the old XR deletes any object that is not orphaned, and one of them is your Deployment.

```bash
# 3. Create the XApp in the namespace: the new manifest above. Wait until it is ready.
kubectl -n $NS get xapp $APP

# 4. The same application: the uid and the generation match step 1, and the pods are the same ones (nothing restarted).
kubectl -n $NS get deployment $APP -o jsonpath='{.metadata.uid} {.metadata.generation}{"\n"}'
kubectl -n $NS get pods -l app.kubernetes.io/instance=$APP -o name

# 5. Delete the old XR. Then check the application is still running and the XApp still owns it.
kubectl delete xtenantapp $OLD
kubectl -n $NS get deployment,service $APP
kubectl -n $NS get xapp $APP -o jsonpath='{.status.ready} {.status.owner}{"\n"}'
```

If the generation moved in step 4, a pod-template field changed: compare `kubectl -n $NS get deployment $APP -o yaml` against your notes before the old XR goes.
`status.owner` shows the owner the namespace gave it; if it is empty, the namespace has no owner and nothing was rendered.

In GitOps it is the same order in three commits: the annotation, the `XApp`, then the removal of the `XTenantApp`. An overlay per environment becomes one `XApp`
each, named so they sit side by side in a namespace (`checkout-dev`, `checkout-prod`) with `appName` keeping the resource names you already have.

**Undo before step 5:** annotate the *new* `XApp` with `wxops.cloud/handover: "true"`, delete it, then remove the annotation from the old XR. Do not delete the new
XR first — it is the one writing the Deployment, and deleting it deletes the Deployment.

## `XTenantDatabase` → `XDatabase`

A database **holds data**, so this is the move to do last and slowly. Like `XApp`, an `XDatabase` is created in the team's namespace and takes its owner from it, and it
adopts what the `XTenantDatabase` built — the Role, the CNPG `Database`, the generated password, the OpenBao entry — instead of rebuilding it.

**Before you start**

- The `database` package is installed beside `database-cluster`, and the hub's `ClusterProviderConfig` is applied (`make providers-config`).
- **The namespace's owner is the old XR's `owner`.** Names are built from it: the role `<owner>-<dbName>`, the Secret, the OpenBao path. A namespace owned by anyone else
  would build a different database. `kubectl get namespace <ns> -L wxops.cloud/owner` must show the old `spec.parameters.owner`.
- **The secret store is the platform's.** `XDatabase` writes through the `ClusterSecretStore` `vault-tenant`. If the old XR set a different `vaultSecretStoreName`, stop: the `PushSecret`
  would change store, and the platform team has to decide that first.
- Have a recent backup. A `Database` with `databaseReclaimPolicy: retain` (the default) keeps its data if something goes wrong; one with `delete` does not.

**The new manifest** is the old one with these changes:

| In the `XTenantDatabase` | In the `XDatabase` |
|---|---|
| `metadata.name: <anything>`, cluster-scoped, and the label `wxops.cloud/tenant-database` | in the team's namespace; `dbName: <the old dbName>` — or name the XR after it. The label is not needed |
| `parameters.owner` | removed — the namespace's owner |
| `parameters.cluster`, `clusterRef`, `clusterNamespace`, `vaultSecretStoreName` | removed |
| _(the database was called `dbName`)_ | **`databaseName: <the old dbName>`** — the PostgreSQL name of an existing database cannot change |
| `parameters.environment` left out (it defaulted to `dev`) | `environment: dev`, written out |
| `extensions`, `databaseReclaimPolicy` | copied exactly — a different reclaim policy changes how deletion behaves |
| `tier: dedicated` with `dedicatedCluster` | `tier: dedicated`, and the platform team creates the cluster first — see below |

An `XDatabase` with the same owner and `dbName` as a live `XTenantDatabase` is placed **on that database's cluster** automatically, which adoption needs.

```bash
NS=<namespace>
DB=<dbName>                  # the logical name
OWNER=<owner>                # the namespace's owner = the old XR's owner
OLD=<XTenantDatabase name>
CLUSTER=<status.clusterRef>
CNS=<status.clusterNamespace>
ROLE=$OWNER-$DB

# 1. Record what must not change: the CNPG Database, the role, the connection Secret (hashed — never print a password), and the OpenBao entry's version.
kubectl -n $CNS get database.postgresql.cnpg.io $ROLE -o jsonpath='{.metadata.uid} {.status.applied}{"\n"}'
kubectl get roles.postgresql.sql.crossplane.io $ROLE -o jsonpath='{.metadata.uid}{"\n"}'
kubectl -n $CNS get secret $ROLE-connection-creds -o jsonpath='{.metadata.uid} {.data.password}{"\n"}' | sha256sum
kubectl -n $CNS get pushsecret $ROLE-push -o jsonpath='{.spec.secretStoreRefs[0].name}{"\n"}'
vault kv metadata get tenants/$OWNER/databases/$DB/connection-creds | grep -E 'current_version|updated_time'   # or: bao kv metadata get

# 2. Hand it over, then check EVERY composed object is observe-only and orphans on delete (a few seconds):
kubectl annotate xtenantdatabase $OLD wxops.cloud/handover=true
kubectl get objects.kubernetes.crossplane.io -l crossplane.io/composite=$OLD \
  -o custom-columns=NAME:.metadata.name,MANAGEMENT:.spec.managementPolicies,ON-DELETE:.spec.deletionPolicy
```

**Stop here unless every row shows `[Observe]` and `Orphan`.** One of them is the CNPG `Database`, and another is the role.

```bash
# 3. Create the XDatabase in the namespace: the new manifest above. Wait until it is ready.
kubectl -n $NS get xdatabase $DB

# 4. The same database: re-run the commands from step 1 and compare. The uids and the password hash must match, the PushSecret's store must be the same (or you have
#    decided its change), and the OpenBao entry's version must not have moved — a new version means something was pushed again.
#    The cluster is the old one, and the PostgreSQL name is the real one:
kubectl -n $NS get xdatabase $DB -o jsonpath='{.status.clusterRef} {.status.databaseName} {.status.owner}{"\n"}'

# 5. Delete the old XR. Then check the database, the role, the Secret and the PushSecret are all still there.
kubectl delete xtenantdatabase $OLD
kubectl -n $CNS get database.postgresql.cnpg.io $ROLE
kubectl get roles.postgresql.sql.crossplane.io $ROLE
kubectl -n $CNS get secret $ROLE-connection-creds
kubectl -n $CNS get pushsecret $ROLE-push
```

If `status.clusterRef` is not the old XR's cluster, or `status.databaseName` is not the real PostgreSQL database, stop **before step 5**: either the owner or the name does
not match, and the `XDatabase` is building a different database beside the old one.

**A dedicated database** has one more thing to move: the cluster. The old XR composed a child `XPlatformDatabaseCluster`, which holds the data. Do this before step 3:

1. Annotate the old XR (step 2). It passes the annotation to its child, so the child stops writing and orphans too — check it:
   `kubectl get xplatformdatabaseclusters -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].name=="'$OLD'")]}{.metadata.name}{"\n"}{end}'`, then run the same
   objects check against that child with `-l crossplane.io/composite=<child name>`.
2. The platform team creates the `XDatabaseCluster` named `<owner>-<dbName>-cluster`: the child's `spec.parameters` as they are, plus `shared: false`, the label
   `wxops.cloud/managed-by: platform-database-clusters` and the label `wxops.cloud/owner: <owner>`. Follow [the cluster handover](#xplatformdatabasecluster--xdatabasecluster)
   from its step 3: the CNPG `Cluster` and both credential Secrets keep their uids and password hashes. Without the owner label the `XDatabase` does not find it.
3. Then create the `XDatabase` (step 3 above, `tier: dedicated`) and carry on.

Deleting the old XR deletes the child with it, and the orphaned objects leave the cluster running.

**Undo before step 5:** annotate the *new* `XDatabase` with `wxops.cloud/handover: "true"`, delete it, then remove the annotation from the old XR. For a dedicated
database, do the same to the new `XDatabaseCluster` and to the child. Do not delete a new XR first: it is the one writing, and deleting it deletes what it wrote.

## The other kinds

`XApp` and `XDatabase` are **namespaced**: you create them in the team's own namespace, they take their owner from it, and they no longer carry `namespace`, `owner` or
`cluster`. See [RFC-010](../../development-docs/rfc/010-namespaced-tenant-kinds.md) for what changes and why.
