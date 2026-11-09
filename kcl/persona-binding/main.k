"""
XPersonaBinding — KCL composition source.

Binds an XPersona's subjects to one ClusterRole. This is the ONLY composition in the repository allowed to emit RBAC, and only bindings — never a Role or
ClusterRole, never `cluster-admin`; provider-kubernetes holds `bind` on exactly the roles in the XRD's enum (RFC-009, tests/invariants.py). The roles themselves
are static manifests under providers/rbac/aggregate-*.yaml.

Inputs (via option("params").oxr.spec.parameters):
  personaRef.name  string    The XPersona whose status.subjects are bound.
  role             string    A ClusterRole: wxops:persona-* | wxops:platform-*. Never the built-in view, edit or admin.
  scope            string    owned (default) | namespaces | platform.
  namespaces       [string]  For scope "namespaces".

Design:
  scope owned      Every Namespace labelled `auth.wxops.cloud/tenant-namespace: "true"` gets a RoleBinding for the persona's GROUPS whose team is the
                   namespace's `wxops.cloud/owner` — group "<org>:<team>" belongs to owner "<team>", matched exactly (no case folding), and to the
                   second owner the persona maps it to in `status.owners` (a team labelled `wxops.cloud/owner`, ADR-006). Users and
                   ServiceAccounts have no team, so they are bound by scope "namespaces", never here. A namespace with no matching group renders nothing.
  scope namespaces A RoleBinding in each listed namespace, for every subject.
  scope platform   One ClusterRoleBinding, for every subject. Only with a wxops:platform-* role.
  A RoleBinding's roleRef is immutable, so the role is part of every name: changing `role` replaces the binding instead of failing to update it.
  The XRD rejects an invalid combination; this file refuses it too, rendering nothing, so a bypassed rule never reaches the API server.

Composed resources:
  <short>-<namespace>-<role>   kubernetes.crossplane.io/v1alpha2 Object  — a RoleBinding (owned, namespaces)
  <short>-<role>               kubernetes.crossplane.io/v1alpha2 Object  — a ClusterRoleBinding (platform)
"""

oxr = option("params").oxr
params = oxr.spec.parameters
uid = oxr.metadata.uid
short = uid[:8:]
xrName = oxr.metadata.name

_get = lambda d: any, k: str, default: any -> any {
    _safe = d or {}
    _safe[k] if k in _safe else default
}

_ctxExtras = option("params").ctx["apiextensions.crossplane.io/extra-resources"] or {}

personaName = _get(_get(params, "personaRef", {}), "name", "")
role = params.role
scope = _get(params, "scope", "owned")
listedNamespaces = _get(params, "namespaces", [])

_personas = _ctxExtras.personas or []
_persona = _personas[0] if _personas else {}
_subjects = _get(_get(_persona, "status", {}), "subjects", [])
_mappedOwners = _get(_get(_persona, "status", {}), "owners", [])
_namespaces = _ctxExtras.namespaces or []

_rbacGroup = "rbac.authorization.k8s.io"
_roleSlug = role.replace("wxops:", "").replace(":", "-")
_isPlatformRole = role.startswith("wxops:platform-")

# ── Problems that stop rendering ────────────────────────────────────────────
# Reported through synced/syncMessage; nothing is rendered while any is open.
_problems = [p for p in [
    "persona '" + personaName + "' not found" if not _personas else "",
    "scope 'platform' binds only a wxops:platform-* role" if scope == "platform" and not _isPlatformRole else "",
    "a wxops:platform-* role is bound with scope 'platform' only" if scope != "platform" and _isPlatformRole else "",
    "scope 'namespaces' needs at least one namespace" if scope == "namespaces" and len(listedNamespaces) == 0 else "",
] if p != ""]

# ── What to bind, where ─────────────────────────────────────────────────────
_teamOf = lambda group: str -> str {
    group[group.find(":") + 1:]
}
_ownerOf = lambda ns: any -> str {
    _get(_get(_get(ns, "metadata", {}), "labels", {}), "wxops.cloud/owner", "")
}
# Every owner a group stands for: its own team, plus the one the persona maps it to.
_ownersOfGroup = lambda group: str -> [str] {
    [_teamOf(group)] + [_get(m, "owner", "") for m in _mappedOwners if _get(m, "group", "") == group]
}

# [{namespace, subjects}] — one RoleBinding each
_roleBindings = [{namespace = _get(_get(ns, "metadata", {}), "name", ""), subjects = [s for s in _subjects if s.kind == "Group" and _ownerOf(ns) in _ownersOfGroup(s.name)]} for ns in _namespaces if _ownerOf(ns) != ""] if scope == "owned" else [{namespace = n, subjects = _subjects} for n in listedNamespaces] if scope == "namespaces" else []
_roleBindings = [b for b in _roleBindings if len(b.subjects) > 0] if not _problems else []
_clusterBindings = [{subjects = _subjects}] if scope == "platform" and len(_subjects) > 0 and not _problems else []

_labels = {
    "wxops.cloud/managed-by" = "persona-binding"
    "auth.wxops.cloud/persona" = personaName
    "auth.wxops.cloud/binding" = xrName
}

_roleRef = {apiGroup = _rbacGroup, kind = "ClusterRole", name = role}

# ── Readiness ───────────────────────────────────────────────────────────────
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

# ── Composed Objects ────────────────────────────────────────────────────────
_object = lambda name: str, manifest: any -> any {
    {
        apiVersion = "kubernetes.crossplane.io/v1alpha2"
        kind = "Object"
        metadata = {
            name = name
            annotations = {
                "crossplane.io/composition-resource-name" = name
            } | ({"krm.kcl.dev/ready" = "True"} if _isReady(name) else {})
        }
        spec = {
            providerConfigRef = {name = "default"}
            forProvider = {manifest = manifest}
        }
    }
}

_roleBindingName = "wxops-" + xrName + "-" + _roleSlug

_roleBindingObjects = [_object(short + "-" + b.namespace + "-" + _roleSlug, {
    apiVersion = _rbacGroup + "/v1"
    kind = "RoleBinding"
    metadata = {name = _roleBindingName, namespace = b.namespace, labels = _labels}
    subjects = b.subjects
    roleRef = _roleRef
}) for b in _roleBindings]

_clusterBindingObjects = [_object(short + "-" + _roleSlug, {
    apiVersion = _rbacGroup + "/v1"
    kind = "ClusterRoleBinding"
    metadata = {name = _roleBindingName, labels = _labels}
    subjects = b.subjects
    roleRef = _roleRef
}) for b in _clusterBindings]

_composed = _roleBindingObjects + _clusterBindingObjects
_composedNames = [o.metadata.name for o in _composed]

# ── dxr update — status write-back ──────────────────────────────────────────
_created = len(_problems) == 0 and len([n for n in _composedNames if n not in _ocds]) == 0
_ready = len(_problems) == 0 and len([n for n in _composedNames if not _isReady(n)]) == 0

_syncFailures = _problems + [n + ": " + _get(_syncConds(n)[0], "message", _get(_syncConds(n)[0], "reason", "not synced")) for n in _ocds if _syncFailed(n)]
_synced = len(_syncFailures) == 0
_syncMessage = (_syncFailures[0] + (" (+" + str(len(_syncFailures) - 1) + " more)" if len(_syncFailures) > 1 else ""))[:400] if _syncFailures else ""

_bindingsStatus = [{kind = "RoleBinding", name = _roleBindingName, namespace = b.namespace, subjects = len(b.subjects)} for b in _roleBindings] + [{kind = "ClusterRoleBinding", name = _roleBindingName, subjects = len(b.subjects)} for b in _clusterBindings]

_dxr = {
    apiVersion = "auth.wxops.cloud/v1alpha1"
    kind = "XPersonaBinding"
    status = {
        created = _created
        ready = _ready
        bindings = _bindingsStatus
    } | ({"synced" = _synced} if _ocds or _problems else {}) | ({"syncMessage" = _syncMessage} if _syncFailures else {})
}

items = [_dxr] + _composed
