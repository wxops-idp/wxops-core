"""
XDatabase — KCL composition source. The namespaced successor of XTenantDatabase (ADR-005, RFC-010, archived: kcl/_archives/tenant-database/main.k), which it learned from: who owns
the database comes from the XR's namespace and which cluster it lives on from the platform, so a person types neither.

What the namespace and the platform decide (none of it is a parameter):
  owner              the namespace's `wxops.cloud/owner`, read by function-extra-resources. It scopes the role name and the OpenBao path, and is set on every composed
                     resource. A namespace with no owner is not a tenant namespace: a new XR says so in status.syncMessage and renders nothing; one that already composed
                     resources fails the reconcile instead, so what it built is left untouched.
  cluster            tier: shared  — a shared XDatabaseCluster for the database's environment, chosen by a stable hash of owner/dbName and kept in status.clusterRef, so a new
                                     cluster never moves a database.
                     tier: dedicated — the XDatabaseCluster the platform team created for it: named <owner>-<dbName>-cluster, labelled wxops.cloud/owner: <owner>, shared: false.
  namespace of it    read from that cluster, never typed.
  secret store       the platform's tenants ClusterSecretStore (vault-tenant); a person cannot name another.

Inputs (via option("params").oxr.spec.parameters), all optional:
  tier                string    "shared" (default) or "dedicated".
  environment         string    Selects the shared pool: a cluster whose environment matches. Absent means "dev".
  dbName              string    The database's logical name: scopes the role, the Secrets and the OpenBao path. Defaults to the XR's name.
  databaseName        string    The PostgreSQL database's own name. Defaults to <owner>-<dbName>, unique on its cluster. Set it to adopt an existing database.
  extensions          [string]  PostgreSQL extensions to enable. Default: [].
  databaseReclaimPolicy string  CNPG Database.spec.databaseReclaimPolicy: "delete" | "retain". Default: "retain" (protects the database — and its owning role — from XR
                                 deletion; both survive and must be cleaned up manually if the tenant is decommissioned). "delete" drops the database on XR deletion,
                                 which also lets the owning role be dropped. A Usage (tenant-role-db-usage) orders this: the Role's DROP ROLE is blocked until the
                                 Database's DROP DATABASE has completed, then replayed — avoiding the "role ... cannot be dropped because some objects depend on it"
                                 (2BP01) race that parallel deletion would otherwise cause.

Annotation (on the XR, never a parameter):
  wxops.cloud/handover: "true"   Releases the database from this XR: every composed Object is rendered Observe-only (no Delete among its management policies), so deleting
                                 the XR leaves the Role, the Database and the credentials in place. It carried the XTenantDatabase → XDatabase migration.

Design — provider-sql Role for continuous per-tenant role reconciliation:
  - ESO generates the role password once and bundles it into Secret {roleName}-connection-creds in {clusterNamespace}. refreshPolicy: CreatedOnce means ESO only writes
    this Secret if it doesn't already exist.
  - A postgresql.sql.crossplane.io/v1alpha1 Role (tenant-sql-role) is provisioned via the per-cluster provider-sql ProviderConfig named after the cluster (created by
    the cluster's own composition). Role.spec.forProvider.passwordSecretRef points at {roleName}-connection-creds, read only at Create() time — provider-sql never
    re-applies password changes on an existing role. ⚠ If tenant-sql-role and tenant-conn-bundle's Secret are created in the same reconcile (most likely after
    databaseReclaimPolicy: "delete" + XR delete/recreate), provider-sql can read the Secret before ESO has written the generated password, creating the role with no
    usable password — permanently. Prefer databaseReclaimPolicy: "retain"; if this happens under "delete", an operator must fix the role's password manually.
  - The database itself is a native postgresql.cnpg.io/v1 Database CR (spec.cluster.name = the cluster, spec.owner = roleName, spec.extensions), reconciled by CNPG.
  - PushSecret syncs the connection bundle to OpenBao once (refreshInterval: "0"). Consuming that entry in an app namespace is a tenant/GitOps concern.
  - Everything but the XR's own Objects lives in the CNPG cluster's namespace — a CNPG Database must sit beside its Cluster — and the Role is cluster-scoped. Those carry
    the owner label, because owner-stamp cannot reach them.

Password rotation is intentionally NOT implemented here — provider-sql never re-applies password changes to an existing role, so any rotation must also converge
Postgres itself. That is a platform-level concern (e.g. OpenBao's database secrets engine).

Composed resources (namespaced kubernetes.m.crossplane.io Objects in the XR's namespace, wrapping what is named):
  tenant-pwd-gen       generators.external-secrets.io/v1alpha1  Password       — 32-char random password.
  tenant-conn-bundle   external-secrets.io/v1                   ExternalSecret — {roleName}-connection-creds.
  tenant-sql-role      postgresql.sql.crossplane.io/v1alpha1    Role           — per-tenant role + password (provider-sql).
  cnpg-database        postgresql.cnpg.io/v1                    Database       — PostgreSQL database + extensions.
  tenant-push-secret   external-secrets.io/v1alpha1             PushSecret     — pushes bundle to OpenBao (once).
  tenant-role-db-usage, tenant-conn-role-usage   protection.crossplane.io Usage — only with databaseReclaimPolicy: delete.

OpenBao path written: tenants/{owner}/databases/{dbName}/connection-creds
"""

import crypto

oxr = option("params").oxr
params = oxr.spec.parameters
uid = oxr.metadata.uid
short = uid[:8:]

_get = lambda d: any, k: str, default: any -> any {
    _safe = d or {}
    _safe[k] if k in _safe else default
}

_handover = _get(_get(oxr.metadata, "annotations", {}), "wxops.cloud/handover", "") == "true"

# ── ArgoCD resource tracking ─────────────────────────────────────────────────
# When ArgoCD applies the XR from Git, it sets app.kubernetes.io/instance on the XR to the Application name. Propagate this to composed Object CRs so ArgoCD discovers
# the full resource tree in its UI. If the XR wasn't applied by ArgoCD (e.g. kubectl apply), the label is absent and nothing happens.
_oxrLabels = _get(oxr.metadata, "labels", {})
_argoInstance = _get(_oxrLabels, "app.kubernetes.io/instance", "")
_argoLabels = {"app.kubernetes.io/instance": _argoInstance} if _argoInstance else {}

# ── What function-extra-resources fetched ────────────────────────────────────
# (results are in the pipeline context, not option("params").extraResources)
#   namespace       — the XR's own Namespace, whose `wxops.cloud/owner` says who owns the database
#   allClusters     — every XDatabaseCluster the platform labelled for discovery (filtered by shared + environment + owner in KCL)
# Other teams' XDatabases are deliberately not read: a namespaced kind is not reliably listable across namespaces, and nothing here needs them.
_ctxExtras = option("params").ctx["apiextensions.crossplane.io/extra-resources"] or {}
_allClusters = _ctxExtras.allClusters or []
_nsObjs = _ctxExtras.namespace or []

ns = oxr.metadata.namespace
dbName = _get(params, "dbName", oxr.metadata.name)
_nsLabels = _get(_get(_nsObjs[0] if _nsObjs else {}, "metadata", {}), "labels", {})
owner = _get(_nsLabels, "wxops.cloud/owner", "")
tier = _get(params, "tier", "shared")
environment = _get(params, "environment", "")
# An XDatabase with no environment is served by the "dev" pool — the one every XTenantDatabase defaulted to. A team that runs a production database says `environment: prod`.
_poolEnvironment = environment if environment else "dev"

# Every composed Object is a namespaced provider-kubernetes Object applied through the hub's ClusterProviderConfig, which the platform team owns.
_providerConfigRef = {kind = "ClusterProviderConfig", name = "default"}

# ── Cluster lookups over what the platform labelled ──────────────────────────
_clusterStatus = lambda sc: any -> any {
    _get(sc, "status", {})
}

_clusterParams = lambda sc: any -> any {
    _spec = _get(sc, "spec", {})
    _get(_spec, "parameters", {})
}

_clusterShared = lambda sc: any -> bool {
    _val = _get(_clusterStatus(sc), "shared", _get(_clusterParams(sc), "shared", False))
    _val in [True, "true"]
}

_clusterEnv = lambda sc: any -> str {
    str(_get(_clusterStatus(sc), "environment", _get(_clusterParams(sc), "environment", "dev")))
}

_clusterName = lambda sc: any -> str {
    str(_get(_clusterStatus(sc), "clusterName", _get(_clusterParams(sc), "clusterName", "")))
}

_clusterNs = lambda sc: any -> str {
    str(_get(_clusterStatus(sc), "namespace", _get(_clusterParams(sc), "namespace", "")))
}

_clusterOwner = lambda sc: any -> str {
    str(_get(_get(_get(sc, "metadata", {}), "labels", {}), "wxops.cloud/owner", ""))
}

# ── Stickiness ───────────────────────────────────────────────────────────────
# A shared database keeps the cluster it was first given: adding a cluster must not move it. The first assignment is a stable hash of owner/dbName over the pool.
_oxrStatus = _get(oxr, "status", {})
_stickyCluster = _get(_oxrStatus, "clusterRef", "")
_stickyNs = _get(_oxrStatus, "clusterNamespace", "")
_hasSticky = bool(_stickyCluster) and bool(_stickyNs) and tier == "shared"

_sharedPoolAll = [{
    clusterName = _clusterName(sc)
    namespace = _clusterNs(sc)
} for sc in _allClusters \
    if _clusterShared(sc) and _clusterEnv(sc) == _poolEnvironment and _clusterName(sc)]
# Sorted by name, so the hash picks the same cluster every reconcile.
_sharedNames = sorted([p.clusterName for p in _sharedPoolAll])
# The first eight hex digits of sha256(owner/dbName) as a number: the same database always hashes to the same place.
_hexDigit = lambda c: str -> int {
    "0123456789abcdef".find(c)
}
_hashIdx = sum([_hexDigit(c) * (16 ** i) for i, c in crypto.sha256(owner + "/" + dbName)[:8:]])
_hashedName = _sharedNames[_hashIdx % len(_sharedNames)] if _sharedNames else ""
_hashed = [p for p in _sharedPoolAll if p.clusterName == _hashedName][0] if _hashedName else None
_sharedPick = _hashed

# tier: dedicated — the cluster the platform team created for this database. 1 cluster = 1 database, named after both, owned by this owner and not shared.
_dedClusterName = owner + "-" + dbName + "-cluster"
_dedMatches = [sc for sc in _allClusters if _clusterName(sc) == _dedClusterName and not _clusterShared(sc) and _clusterOwner(sc) == owner]
_dedPick = {clusterName = _clusterName(_dedMatches[0]), namespace = _clusterNs(_dedMatches[0])} if _dedMatches else None

_noCluster = {clusterName = "", namespace = ""}
_resolved = (_dedPick or _noCluster) if tier == "dedicated" \
    else {clusterName = _stickyCluster, namespace = _stickyNs} if _hasSticky \
    else (_sharedPick or _noCluster)
clusterRef = _resolved.clusterName
clusterNs = _resolved.namespace

# ── What stops this XR from rendering ────────────────────────────────────────
# Said in status.syncMessage for a new XR. An XR that already composed resources fails the reconcile instead: rendering nothing would delete a database's objects, and
# nothing here is worth that — what it built stays exactly as it was until the cause is fixed.
_blockedReason = "namespace '" + ns + "' has no wxops.cloud/owner label, so it is not a tenant namespace — nothing is rendered until the platform team labels it" if not owner \
    else "tier: dedicated needs an XDatabaseCluster named '" + _dedClusterName + "' with the label wxops.cloud/owner: " + owner + " and shared: false — the platform team creates it" if tier == "dedicated" and not _dedPick \
    else "tier: shared needs a shared XDatabaseCluster for environment '" + _poolEnvironment + "' — the platform team provides one" if tier == "shared" and not _hasSticky and not _sharedPick \
    else ""
_isBlocked = _blockedReason != ""
assert not (_isBlocked and len(option("params").ocds or {}) > 0), "refusing to change what this database already composed: " + _blockedReason

extensions = _get(params, "extensions", [])
databaseReclaimPolicy = _get(params, "databaseReclaimPolicy", "retain")
# The tenants ClusterSecretStore, scoped to the tenants/ mount. A platform choice: a tenant cannot name another store, which could write credentials into a mount teams
# may not use.
vaultStore = "vault-tenant"

_manifestLabels = _argoLabels | {"wxops.cloud/owner" = owner}

# Resource names — all derived from owner + dbName for human readability and
# uniqueness within a shared clusterNamespace.
roleName = owner + "-" + dbName
# The PostgreSQL database's own name is unique on its cluster by construction: owner-prefixed, like the role. Set `databaseName` to adopt a database an XTenantDatabase
# created under its bare dbName — CNPG's Database.spec.name cannot change.
pgName = _get(params, "databaseName", roleName)
pwdGenName = roleName + "-pwd-gen"
connSecretName = roleName + "-connection-creds"
vaultPath = owner + "/databases/" + dbName + "/connection-creds"
endpoint = clusterRef + "-rw." + clusterNs + ".svc.cluster.local"
connStr = "postgresql://" + roleName + ":{{ .password }}@" + endpoint + ":5432/" + pgName

# refreshInterval: "0" = stable, ESO never regenerates the password on its
# own schedule (only at initial creation — see refreshPolicy below).
esoRefreshInterval = "0"

# refreshPolicy: "CreatedOnce" tells ESO to write {connSecretName} only if it
# does not already exist yet — it will not re-invoke the Password generator or
# overwrite an existing Secret. This only holds across XR delete+recreate if
# the ExternalSecret CR itself (which tracks "have I created it before") also
# survives — see _objManagementPolicies below. Paired with target.deletionPolicy
# and _objManagementPolicies, this makes delete+recreate of the XR behave
# correctly for both reclaim policies:
#   - "retain": the Secret survives XR deletion (target.deletionPolicy:
#     Retain), and so does the ExternalSecret/Password-generator CRs
#     (_objManagementPolicies without Delete); on recreate, ESO's CreatedOnce state is
#     intact, finds the Secret already exists, and leaves it alone — the
#     password keeps matching the adopted Postgres role's actual password (no
#     manual ALTER ROLE ... PASSWORD needed).
#   - "delete": the Secret and the ExternalSecret/Password-generator CRs are
#     all deleted (target.deletionPolicy: Delete, _objManagementPolicies: all);
#     on recreate nothing exists, so ESO generates a fresh password as normal
#     — a true clean Create().
esoRefreshPolicy = "CreatedOnce"

# target.deletionPolicy for {connSecretName}: mirrors databaseReclaimPolicy so
# "delete" really does remove everything (Secret included), while "retain"
# keeps the Secret around for the CreatedOnce check above. ESO's CRD default
# is "Retain" — set explicitly here for both branches for auditability.
_connSecretDeletionPolicy = "Delete" if databaseReclaimPolicy == "delete" else "Retain"

# spec.managementPolicies for the tenant-pwd-gen / tenant-conn-bundle Object
# wrappers below. A namespaced Object (kubernetes.m.crossplane.io) has no
# spec.deletionPolicy — that field is gone from Crossplane v2's namespaced managed
# resources, so "Orphan" is spelled by leaving Delete out of the management
# policies. On XR deletion Crossplane deletes these Object CRs, and by
# default (every policy, "*") provider-kubernetes also deletes the underlying
# Password-generator / ExternalSecret CRs they wrap (named {pwdGenName} /
# {roleName}-conn-es — both stable, NOT derived from the XR's UID). Deleting
# the ExternalSecret CR destroys its CreatedOnce "already created" state, so
# on recreate a brand-new ExternalSecret CR finds the retained
# {connSecretName} Secret "orphaned" and — per ESO's
# ownership-deletion-policy semantics — adopts AND overwrites it with a
# freshly-generated password, regardless of CreatedOnce/target.deletionPolicy.
#   - "retain" -> no Delete: the underlying Password generator and
#     ExternalSecret CRs survive XR deletion, so on recreate the new wrapper
#     finds them already present with intact CreatedOnce state — the admin
#     keeps full control of when/whether {connSecretName} ever changes.
#   - "delete" -> all policies: everything is torn down together for a true clean
#     Create() on recreate.
_objManagementPolicies = ["Observe", "Create", "Update", "LateInitialize"] if databaseReclaimPolicy == "retain" else ["*"]

# ── Observed state (keyed by Object name, Crossplane v2 / function-kcl v0.12.x) ──
# Used for krm.kcl.dev/ready annotations on desired resources so function-kcl emits
# READY_TRUE — fixing the native type:Ready condition. String "True" is required;
# function-kcl v0.12.1 tightened type checks (boolean True no longer accepted).
_ocds = option("params").ocds or {}
# A composed resource whose last apply failed keeps Ready=True from the earlier success, so Ready
# alone cannot say the apply worked: Synced is the condition the provider sets False.
_syncConds = lambda name: str -> [any] {
    _res = _get(_get(_ocds, name, {}), "Resource", {})
    [c for c in _get(_get(_res, "status", {}), "conditions", []) if _get(c, "type", "") == "Synced" and _get(c, "status", "") == "False"]
}
_syncFailed = lambda name: str -> bool {
    len(_syncConds(name)) > 0
}
_isReady = lambda name: str -> bool {
    _ocd = _ocds[name] if name in _ocds else {}
    _res = _get(_ocd, "Resource", {})
    _conds = _get(_get(_res, "status", {}), "conditions", [])
    len([c for c in _conds if _get(c, "type", "") == "Ready" and _get(c, "status", "") == "True"]) > 0 and not _syncFailed(name)
}

# ── ESO Password Generator ─────────────────────────────────────────
# Lives in {clusterNamespace} so the ExternalSecret below (same namespace)
# can reference it via generatorRef.
_pwd_gen = {
    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
    kind = "Object"
    metadata = {
        name = short + "-pwd-gen"
        annotations = {
            "crossplane.io/composition-resource-name" = "tenant-pwd-gen"
        } | ({"krm.kcl.dev/ready" = "True"} if _isReady(short + "-pwd-gen") else {})
    }
    spec = {
        managementPolicies = _objManagementPolicies
        providerConfigRef = _providerConfigRef
        forProvider = {
            manifest = {
                apiVersion = "generators.external-secrets.io/v1alpha1"
                kind = "Password"
                metadata = {name = pwdGenName, namespace = clusterNs, labels = _manifestLabels}
                spec = {
                    length = 32
                    digits = 8
                    symbols = 0
                    symbolCharacters = ""
                    noUpper = False
                    allowRepeat = False
                }
            }
        }
    }
}

# ── ESO ExternalSecret: connection bundle ──────────────────────────
# Creates Secret {roleName}-connection-creds in {clusterNamespace}.
# tenant-managed-role points CNPG's managed.roles[].passwordSecret at this
# Secret so CNPG creates/alters the role and keeps its password in sync.
# PushSecret syncs the whole bundle to Vault.
_conn_bundle = {
    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
    kind = "Object"
    metadata = {
        name = short + "-conn-bundle"
        annotations = {
            "crossplane.io/composition-resource-name" = "tenant-conn-bundle"
        } | ({"krm.kcl.dev/ready" = "True"} if _isReady(short + "-conn-bundle") else {})
    }
    spec = {
        managementPolicies = _objManagementPolicies
        providerConfigRef = _providerConfigRef
        forProvider = {
            manifest = {
                apiVersion = "external-secrets.io/v1"
                kind = "ExternalSecret"
                metadata = {name = roleName + "-conn-es", namespace = clusterNs, labels = _manifestLabels}
                spec = {
                    refreshInterval = esoRefreshInterval
                    refreshPolicy = esoRefreshPolicy
                    dataFrom = [{
                        sourceRef = {
                            generatorRef = {
                                apiVersion = "generators.external-secrets.io/v1alpha1"
                                kind = "Password"
                                name = pwdGenName
                            }
                        }
                    }]
                    target = {
                        name = connSecretName
                        creationPolicy = "Owner"
                        deletionPolicy = _connSecretDeletionPolicy
                        template = {
                            engineVersion = "v2"
                            data = {
                                username = roleName
                                password = "{{ .password }}"
                                endpoint = endpoint
                                port = "5432"
                                database = pgName
                                connectionString = connStr
                            }
                        }
                    }
                }
            }
        }
    }
}

# ── tenant-sql-role: provider-sql Role for this tenant's database ──────────
# postgresql.sql.crossplane.io/v1alpha1 Role, reconciled via the per-cluster
# ProviderConfig named clusterRef (created by the XDatabaseCluster from its
# superuser creds Secret). passwordSecretRef points at {connSecretName} and is
# applied only at Create() time — provider-sql does not re-apply password
# changes on an existing role (see "Password rotation" note in the docstring).
#
# ⚠ Known provider-sql race: Create() reads
# {connSecretName} for the initial password. If this Role CR and
# tenant-conn-bundle's Secret are created in the same reconcile, provider-sql
# can read the Secret before ESO has written the generated password
# (informer-cache lag), creating the role with NO usable password — and since
# Update() never re-applies passwords, it stays broken until an operator runs
# ALTER ROLE manually. This is most likely after databaseReclaimPolicy:
# "delete" + XR delete/recreate, where tenant-sql-role is destroyed and
# rebuilt from scratch. Mitigation: prefer databaseReclaimPolicy: "retain" so
# the Role (and its working password) survives XR recreation; if "delete" is
# used and login fails after a recreate, check the role's password manually
# (ALTER ROLE ... PASSWORD) against {connSecretName}.
#
# deletionPolicy follows databaseReclaimPolicy, same reasoning as
# _pushDeletionPolicy below: "retain" keeps the Database CR (and its
# underlying Postgres database) alive, so this Role must NOT run DROP ROLE on
# XR deletion — it would hit 2BP01 against the retained database and get
# stuck Deleting. "Orphan" removes the Crossplane Role resource without
# touching the Postgres role, matching the retained database it owns.
# "delete" -> "Delete" (drop the role along with the dropped database).
_roleDeletionPolicy = "Orphan" if databaseReclaimPolicy == "retain" else "Delete"
_sql_role = {
    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
    kind = "Object"
    metadata = {
        name = short + "-sql-role"
        annotations = {
            "crossplane.io/composition-resource-name" = "tenant-sql-role"
        } | ({"krm.kcl.dev/ready" = "True"} if _isReady(short + "-sql-role") else {})
    }
    spec = {
        providerConfigRef = _providerConfigRef
        forProvider = {
            manifest = {
                apiVersion = "postgresql.sql.crossplane.io/v1alpha1"
                kind = "Role"
                metadata = {name = roleName, labels = _manifestLabels}
                spec = {
                    deletionPolicy = _roleDeletionPolicy
                    providerConfigRef = {name = clusterRef}
                    forProvider = {
                        privileges = {login = True}
                        passwordSecretRef = {
                            namespace = clusterNs
                            name = connSecretName
                            key = "password"
                        }
                    }
                }
            }
        }
    }
}

# ── CNPG Database CR ────────────────────────────────────────────────
# Native postgresql.cnpg.io/v1 Database — must live in {clusterNamespace}
# (spec.cluster.name is a same-namespace reference). CNPG creates the
# database (and extensions) once spec.owner exists as a role.
# databaseReclaimPolicy (default "retain") — the database (and its owning
# role, tenant-sql-role below) survive XR deletion and must be cleaned up
# manually if the tenant is decommissioned. Set params.databaseReclaimPolicy
# to "delete" to have CNPG drop the database on XR deletion instead; the
# Usage below (_cluster_usage) orders the Role's DROP ROLE to run only
# after this Database's DROP DATABASE has completed, avoiding the 2BP01
# parallel-deletion race.
_dbSpec = {
    cluster = {name = clusterRef}
    name = pgName
    owner = roleName
    databaseReclaimPolicy = databaseReclaimPolicy
} | ({"extensions": [{"name": ext, "ensure": "present"} for ext in extensions]} if extensions else {})

_cnpg_database = {
    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
    kind = "Object"
    metadata = {
        name = short + "-cnpg-database"
        annotations = {
            "crossplane.io/composition-resource-name" = "cnpg-database"
        } | ({"krm.kcl.dev/ready" = "True"} if _isReady(short + "-cnpg-database") else {})
    }
    spec = {
        providerConfigRef = _providerConfigRef
        forProvider = {
            manifest = {
                apiVersion = "postgresql.cnpg.io/v1"
                kind = "Database"
                metadata = {name = roleName, namespace = clusterNs, labels = _manifestLabels}
                spec = _dbSpec
            }
        }
    }
}

# ── Usage: order Role deletion after Database deletion ─────
# Only composed when databaseReclaimPolicy == "delete" (when "retain",
# tenant-sql-role's deletionPolicy is "Orphan" — it never runs DROP ROLE, so
# there is nothing to order).
#
# protection.crossplane.io/v1beta1 Usage (namespaced, in the XR's own namespace): "of" (tenant-sql-role's
# Object) cannot be deleted while "by" (cnpg-database's Object) still exists.
# On XR deletion Crossplane deletes all composed resources in parallel; this
# blocks the Role Object's deletion (and therefore its DROP ROLE) with a
# finalizer until the Database Object has actually been deleted (DROP
# DATABASE done). replayDeletion: true re-triggers the blocked Role deletion
# once that finalizer is lifted, so DROP ROLE then runs against a database
# that's already gone — fixing the "role ... cannot be dropped because some
# objects depend on it" (2BP01) parallel-deletion race documented above.
_cluster_usage = {
    apiVersion = "protection.crossplane.io/v1beta1"
    kind = "Usage"
    metadata = {
        name = short + "-role-db-usage"
        annotations = {
            "crossplane.io/composition-resource-name" = "tenant-role-db-usage"
        } | ({"krm.kcl.dev/ready" = "True"} if _isReady(short + "-role-db-usage") else {})
    }
    spec = {
        of = {
            apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
            kind = "Object"
            resourceRef = {name = short + "-sql-role"}
        }
        by = {
            apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
            kind = "Object"
            resourceRef = {name = short + "-cnpg-database"}
        }
        reason = "Block DROP ROLE until DROP DATABASE has completed, avoiding the 2BP01 parallel-deletion race."
        replayDeletion = True
    }
}

# ── Usage: order connection-secret deletion after Role deletion ────
# Only composed when databaseReclaimPolicy == "delete" (when "retain",
# tenant-conn-bundle's management policies leave out Delete — nothing to order).
#
# provider-sql's reconciler calls Observe() before Delete() on every pass,
# and Observe() unconditionally reads Role.spec.forProvider.passwordSecretRef
# ({connSecretName}). If tenant-conn-bundle (and the {connSecretName} Secret
# it owns) is deleted before tenant-sql-role finishes deleting, Observe()
# permanently fails with "cannot get password secret: ... not found" —
# Delete() (DROP ROLE) never runs, and the Role's finalizer never clears,
# deadlocking the Object/Role CR in Terminating forever (confirmed live).
#
# Fix: block tenant-conn-bundle's deletion with a finalizer until
# tenant-sql-role's Object has actually been deleted (DROP ROLE done), then
# replayDeletion re-triggers it — so {connSecretName} only disappears after
# provider-sql no longer needs it.
_cluster_usage_conn = {
    apiVersion = "protection.crossplane.io/v1beta1"
    kind = "Usage"
    metadata = {
        name = short + "-conn-role-usage"
        annotations = {
            "crossplane.io/composition-resource-name" = "tenant-conn-role-usage"
        } | ({"krm.kcl.dev/ready" = "True"} if _isReady(short + "-conn-role-usage") else {})
    }
    spec = {
        of = {
            apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
            kind = "Object"
            resourceRef = {name = short + "-conn-bundle"}
        }
        by = {
            apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
            kind = "Object"
            resourceRef = {name = short + "-sql-role"}
        }
        reason = "Block deletion of the connection-creds Secret until DROP ROLE has completed — provider-sql's Observe() reads passwordSecretRef even during Role deletion and deadlocks if the Secret is already gone."
        replayDeletion = True
    }
}

# ── ESO PushSecret: push connection bundle to Vault ────────────────
# Vault path: tenants/{owner}/databases/{dbName}/connection-creds
# Pushes the WHOLE {connSecretName} secret (username, password, endpoint,
# port, database, connectionString — all built via _conn_bundle's template
# above) as a single write per reconcile (data[] entry has no
# secretKey/property) — listing each key individually would make ESO's Vault
# provider do one read-merge-write PER key, creating one KV2 version per key
# on every refresh instead of one per actual change.
#
# refreshInterval: "0" — under CreatedOnce (esoRefreshPolicy above),
# {connSecretName}'s password never changes after creation, so there's
# nothing to re-push periodically; ESO still pushes once on creation and
# again on any spec change.
#
# deletionPolicy follows databaseReclaimPolicy: Crossplane deletes all
# composed resources in parallel on XR deletion, so a PushSecret with
# deletionPolicy: Delete removes the Vault entry immediately — even if
# databaseReclaimPolicy: retain keeps the Database/Role alive (stuck on
# DROP ROLE's 2BP01 against the retained database). That would orphan a
# live database+role with no recorded credentials in Vault. So: "delete"
# -> Delete (Vault entry torn down alongside the dropped database/role),
# "retain" -> None (Vault keeps the creds for the retained database/role).
_pushDeletionPolicy = "Delete" if databaseReclaimPolicy == "delete" else "None"
_push_secret = {
    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
    kind = "Object"
    metadata = {
        name = short + "-push-secret"
        annotations = {
            "crossplane.io/composition-resource-name" = "tenant-push-secret"
        } | ({"krm.kcl.dev/ready" = "True"} if _isReady(short + "-push-secret") else {})
    }
    spec = {
        providerConfigRef = _providerConfigRef
        forProvider = {
            manifest = {
                apiVersion = "external-secrets.io/v1alpha1"
                kind = "PushSecret"
                metadata = {name = roleName + "-push", namespace = clusterNs, labels = _manifestLabels}
                spec = {
                    refreshInterval = "0"
                    deletionPolicy = _pushDeletionPolicy
                    secretStoreRefs = [{name = vaultStore, kind = "ClusterSecretStore"}]
                    selector = {
                        secret = {name = connSecretName}
                    }
                    data = [{
                        match = {
                            remoteRef = {remoteKey = vaultPath}
                        }
                    }]
                }
            }
        }
    }
}

# ── dxr update — status ──────────────────────────────────────────────────────
# Emitting an item with the XR's own apiVersion/kind updates the XR itself. status.clusterRef is what keeps a shared database on its cluster.
#
# created/ready mirror the XApp contract so the portal has one field to poll across every package. Crossplane's native type:Ready is unreliable on v2.3 + function-kcl
# v0.12.1, so both are derived from ocds instead.
#
# created: every composed resource has been observed at least once.
# ready:   the database is actually usable — it exists, its owning role exists, and the connection Secret has materialised. On tier: dedicated its cluster must be up
#          too, since the database lives on it.
#
# -pwd-gen and -push-secret are deliberately excluded from `ready`:
#   - pwd-gen is a precondition of conn-bundle, so it is already implied.
#   - push-secret writes the credentials to OpenBao. That is a platform concern; if it lags, the application can still connect.
_composedNames = [
    short + "-pwd-gen"
    short + "-conn-bundle"
    short + "-sql-role"
    short + "-cnpg-database"
    short + "-push-secret"
]

_dbCreated = len([n for n in _composedNames if n not in _ocds]) == 0
_dedReady = _get(_get(_dedMatches[0] if _dedMatches else {}, "status", {}), "ready", False)
_dbReady = _isReady(short + "-cnpg-database") \
    and _isReady(short + "-sql-role") \
    and _isReady(short + "-conn-bundle") \
    and (_dedReady if tier == "dedicated" else True)

# ── Sync state ──────────────────────────────────────────────────────────────
# `synced` follows the same resources `ready` does; a failure on any other composed resource is still shown in `syncMessage` without gating anything.
_gatingNames = [short + "-cnpg-database", short + "-sql-role", short + "-conn-bundle"]
_syncFailures = [n + ": " + _get(_syncConds(n)[0], "message", _get(_syncConds(n)[0], "reason", "not synced")) for n in _ocds if _syncFailed(n)]
_synced = len([n for n in _gatingNames if _syncFailed(n)]) == 0
_syncMessage = (_syncFailures[0] + (" (+" + str(len(_syncFailures) - 1) + " more)" if len(_syncFailures) > 1 else ""))[:400] if _syncFailures else ""
_syncStatus = ({"synced" = _synced} if _ocds else {}) | ({"syncMessage" = _syncMessage} if _syncFailures else {})

_dxr = {
    apiVersion = oxr.apiVersion
    kind = oxr.kind
    status = {
        clusterRef = clusterRef
        clusterNamespace = clusterNs
        tier = tier
        dbName = dbName
        databaseName = pgName
        owner = owner
        created = _dbCreated
        ready = _dbReady
    } | _syncStatus
}

# Nothing is composed, and the XR says why. Only ever returned for an XR that composed nothing yet — see _blockedReason.
_dxrBlocked = {
    apiVersion = oxr.apiVersion
    kind = oxr.kind
    status = {
        tier = tier
        dbName = dbName
        created = False
        ready = False
        synced = False
        syncMessage = _blockedReason
    }
}

# ── Final resource list ────────────────────────────────────────────
_composedItems = [
    _pwd_gen
    _conn_bundle
    _sql_role
    _cnpg_database
    _push_secret
] + ([_cluster_usage, _cluster_usage_conn] if databaseReclaimPolicy == "delete" else [])

# A handed-over Object only observes — no Create, Update or Delete among its management policies — so deleting this XR must not delete what it composed.
# (A namespaced Object has no deletionPolicy to set.) Without the annotation nothing changes.
_handedOver = lambda o: any -> any {
    {**o, "spec" = {**o.spec, "managementPolicies" = ["Observe"]}} if o.kind == "Object" else o
}

items = [_dxrBlocked] if _isBlocked else ([_dxr] + ([_handedOver(o) for o in _composedItems] if _handover else _composedItems))
