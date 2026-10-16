"""
status — shared last step of the patch-and-transform packages.

Writes what the provisioned resources actually report back into the XR's status: a composed
Workspace or Object whose last apply failed keeps Ready=True from the earlier success, so the
package's own `ready` (derived from outputs) would otherwise stay true.

Adds `synced` and `syncMessage`, and clears `ready` while any gating resource is not Synced.
Resources named in `_informational` are reported in `syncMessage` but never gate.
"""

oxr = option("params").oxr
dxr = option("params").dxr or {}
_ocds = option("params").ocds or {}

_get = lambda d: any, k: str, default: any -> any {
    _safe = d or {}
    _safe[k] if k in _safe else default
}

# Composed resources that are informational: a failure is shown, but never gates ready or synced.
_informational = ["inspect"]

_failures = [
    {name = n, message = _get(c, "message", _get(c, "reason", "not synced"))}
    for n, ocd in _ocds
    for c in _get(_get(_get(ocd, "Resource", {}), "status", {}), "conditions", [])
    if _get(c, "type", "") == "Synced" and _get(c, "status", "") == "False"
]
_gating = [f for f in _failures if f.name not in _informational]

_synced = len(_gating) == 0
_first = _failures[0] if _failures else {}
_msg = (_first.name + ": " + _first.message)[:400] if _failures else ""
_more = " (+" + str(len(_failures) - 1) + " more)" if len(_failures) > 1 else ""

_dstatus = _get(dxr, "status", {}) or {}

# Nothing observed yet means nothing to report: `synced` stays absent until the first reconcile, and
# `ready` is only narrowed when the package already set it — absent stays absent, never a bare false.
_dxr = {
    apiVersion = oxr.apiVersion
    kind = oxr.kind
    status = _dstatus | ({synced = _synced} if _ocds else {}) | ({ready = _dstatus.ready and _synced} if _get(_dstatus, "ready", None) != None and _ocds else {}) | ({syncMessage = _msg + _more} if _failures else {})
}

items = [_dxr]
