"""
XPersona — KCL composition source.

A persona is a title that collects who it applies to: SCM teams, hand-listed groups and users, and in-cluster agents. It
grants nothing and composes no resource — it resolves its members into `status.subjects`, in the exact shape an RBAC
subject takes, for XPersonaBinding and XPlatformPolicy to read.

Inputs (via option("params").oxr.spec.parameters):
  description        string    What the persona may do, in one line.
  environments       [string]  Echoed to status; the environment gate arrives with the multi-cluster feature.
  members.teams      bool      Generate members from labelled XScmTeams. Default true.
  members.groups     [string]  Groups by hand, "<org>:<team>".
  members.users      [string]  Dex usernames by hand.
  members.serviceAccounts [{namespace, name}]  In-cluster identities.

Design — how a team joins a persona:
  Every `XScmTeam` labelled `scm.wxops.cloud/oidc-login: "true"` is fetched (the same set XOIDCConnector draws on — a team that
  cannot sign in has no use for a persona). A team is a member when it also carries `auth.wxops.cloud/persona-<name>: "true"`,
  `<name>` being this XR's own name, and has published `status.oidcGroup`. A team may carry the label for several personas. The
  label key holds the persona's name, so it cannot be a fixed selector in the pipeline: the filter is here.

Composed resources: none. Only the XR's own status is written.
"""

oxr = option("params").oxr
params = oxr.spec.parameters
name = oxr.metadata.name

_get = lambda d: any, k: str, default: any -> any {
    _safe = d or {}
    _safe[k] if k in _safe else default
}

_ctxExtras = option("params").ctx["apiextensions.crossplane.io/extra-resources"] or {}
_teams = _ctxExtras.teams or []

_members = _get(params, "members", {})
_useTeams = _get(_members, "teams", True)
_label = "auth.wxops.cloud/persona-" + name
_rbacGroup = "rbac.authorization.k8s.io"

_isMember = lambda t: any -> bool {
    _get(_get(_get(t, "metadata", {}), "labels", {}), _label, "") == "true"
}
_teamGroup = lambda t: any -> str {
    _get(_get(t, "status", {}), "oidcGroup", "")
}

# ── Members ─────────────────────────────────────────────────────────────────
_memberTeams = [t for t in _teams if _useTeams and _isMember(t) and _teamGroup(t) != ""]
_teamNames = sorted([t.metadata.name for t in _memberTeams])

# Sorted and de-duplicated: the order must not depend on which API call listed the teams first.
_groups = sorted({g: True for g in [_teamGroup(t) for t in _memberTeams] + _get(_members, "groups", [])})
_users = sorted({u: True for u in _get(_members, "users", [])})
_serviceAccounts = _get(_members, "serviceAccounts", [])

_subjects = [{kind = "Group", name = g, apiGroup = _rbacGroup} for g in _groups] + [{kind = "User", name = u, apiGroup = _rbacGroup} for u in _users] + [{kind = "ServiceAccount", name = sa.name, namespace = sa.namespace} for sa in _serviceAccounts]

# ── dxr update — status write-back ──────────────────────────────────────────
# A persona composes nothing, so there is no apply that could fail: created, ready and synced are true once the members resolve.
_dxr = {
    apiVersion = "auth.wxops.cloud/v1alpha1"
    kind = "XPersona"
    status = {
        created = True
        ready = True
        synced = True
        environments = _get(params, "environments", [])
        groups = _groups
        teams = _teamNames
        subjects = _subjects
    }
}

items = [_dxr]
