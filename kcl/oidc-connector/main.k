"""
XOIDCConnector — KCL composition source.

An upstream Git vendor connector: this is what lets a Git host's users sign in through the broker.
Its per-org team allow-list is generated from `XScmTeam`s, not hand-maintained, replacing the
manual "edit orgs[].teams, restart the broker" workflow this package is named for automating.

Inputs (via option("params").oxr.spec.parameters):
  connectionRef.name   string   The XOIDCConnection this connector belongs to.
  connectorId          string   Immutable — part of every `sub` the broker issues. Also this
                                 resource's own identifier — the remote key is
                                 <vendor>/connectors/{connectorId}.
  displayName          string   The record's "name" field. Default "".
  scmRef.name          string   The XScmConnection to authenticate against — its vendor becomes the
                                 broker connector `type` ("gitea"/"github"), its baseUrl the
                                 connector's own base URL (field name differs: Gitea's connector
                                 config key is baseURL; GitHub's is hostName, omitted entirely for
                                 github.com).
  oauthAppRef.name     string   The XScmOAuthApp whose client id/secret this connector uses.
  orgs                 [object] {name, teams}. Teams is hand-listed and additive — see below.

`teamNameField`, `loadAllGroups` and `useLoginAsID` are not XR fields — hard-coded in the pushed
record (`slug`, `false`, `false`), the same way `teamNameField` already was. None of this platform's
integrations need a per-connector override, and a config knob with no way to set it consistently
(it either lives in the schema or it doesn't) is worse than one that's just always right.

Design — how a team gets into the `groups` claim:
  Per org, every `XScmTeam` labelled `scm.wxops.cloud/oidc-login: "true"`, bound to the SAME
  XScmConnection (matched by baseUrl — an org name is only unique per host, and this package has no
  other way to tell two hosts' same-named orgs apart) and in that org (status.org), contributes its
  `status.dexTeam` — unioned with whatever `orgs[].teams` lists by hand, so a team the SCM family
  doesn't model can still be added. An org's `teams` ending up empty (no XScmTeam, nothing hand-
  listed) is not an error: both Dex connectors treat an empty teams list as "admit the whole org",
  which is their own documented behaviour, not something this package invents.

Composed resources:
  oidc-connector-es     external-secrets.io/v1                   ExternalSecret  — renders the record.
  oidc-push-record      external-secrets.io/v1alpha1              PushSecret     — <vendor>/connectors/{connectorId}.
"""

oxr = option("params").oxr
params = oxr.spec.parameters
uid = oxr.metadata.uid
short = uid[:8:]

_get = lambda d: any, k: str, default: any -> any {
    _safe = d or {}
    _safe[k] if k in _safe else default
}

_ctxExtras = option("params").ctx["apiextensions.crossplane.io/extra-resources"] or {}

_connList = _ctxExtras.connections or []
_conn = _connList[0] if _connList else {}
_connParams = _get(_get(_conn, "spec", {}), "parameters", {})
_connStatus = _get(_conn, "status", {})
vendor = _get(_connParams, "vendor", "dex")
storeName = _get(_get(_connParams, "secretStoreRef", {}), "name", "vault-platform")
callbackUrl = _get(_connStatus, "callbackUrl", "")

_scmConnList = _ctxExtras.scmConnections or []
_scmConn = _scmConnList[0] if _scmConnList else {}
_scmConnParams = _get(_get(_scmConn, "spec", {}), "parameters", {})
scmType = _get(_scmConnParams, "vendor", "gitea")  # "gitea" | "github" — also the Dex connector type
scmBaseUrl = _get(_scmConnParams, "baseUrl", "")

_oauthAppList = _ctxExtras.oauthApps or []
_oauthApp = _oauthAppList[0] if _oauthAppList else {}
_oauthAppStatus = _get(_oauthApp, "status", {})
clientId = _get(_oauthAppStatus, "clientId", "")
oauthVaultKey = _get(_oauthAppStatus, "vaultKey", "")

_teams = _ctxExtras.teams or []

connectorId = params.connectorId
displayName = _get(params, "displayName", "")
orgsParam = params.orgs

assert len(orgsParam) > 0, "orgs must list at least one org — an empty list would admit every host user"

# ── Per-org team generation ──────────────────────────────────────────────────
_matchTeams = lambda orgName: str -> [str] {
    _teamOk = lambda t: any -> bool {
        _ts = _get(t, "status", {})
        _get(_ts, "baseUrl", "") == scmBaseUrl and _get(_ts, "org", "") == orgName and _get(_ts, "dexTeam", "") != ""
    }
    [t.status.dexTeam for t in _teams if _teamOk(t)]
}

_orgEntries = [
    {name = o.name, teams = _get(o, "teams", []) + _matchTeams(o.name)}
    for o in orgsParam
]

_teamsStatus = {e.name: e.teams for e in _orgEntries}

_orgJsonOne = lambda o: any -> str {
    '{"name":"' + o.name + '","teams":[' + ", ".join(['"' + t + '"' for t in o.teams]) + "]}"
}
_orgsJson = "[" + ", ".join([_orgJsonOne(o) for o in _orgEntries]) + "]"

# ── Connector config — field names differ per vendor, see docstring ─────────
_hostNamePart = (',"hostName":"' + scmBaseUrl + '"') if (scmType == "github" and scmBaseUrl) else ""
_baseUrlPart = (',"baseURL":"' + scmBaseUrl + '"') if scmType == "gitea" else ""
_teamFieldPart = ',"teamNameField":"slug"' if scmType == "github" else ""

_configJson = '{"clientID":"' + clientId + '","clientSecret":"{{ .client_secret }}","redirectURI":"' + callbackUrl + '","orgs":' + _orgsJson + ',"loadAllGroups":false,"useLoginAsID":false' + _baseUrlPart + _hostNamePart + _teamFieldPart + "}"

# config is an object containing orgs (an array) — ESO's Vault provider panics comparing an
# existing array/object top-level value with property empty (maps.Equal on
# []interface{}/map[string]interface{} — confirmed against providers/v1/vault/client_push.go) on
# every push after the first. Embedded below as an escaped STRING, not a native object, so every
# top-level field of the pushed record is a plain string — safe to push in one call, one KV
# version, instead of a second PushSecret entry (which also means a second, separate version). The
# dexidp chart already un-stringifies config if it arrives this way.
_recordJson = '{"type":"' + scmType + '","id":"' + connectorId + '","name":"' + displayName + '","config":"' + _configJson.replace('"', '\\"') + '"}'

esName = short + "-connector-es"
esSecretName = "oidc-" + short + "-connector-creds"
recordKey = vendor + "/connectors/" + connectorId

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

# ── ExternalSecret: reads the oauth app's client_secret, renders the record ──
_connector_es = {
    apiVersion = "kubernetes.crossplane.io/v1alpha2"
    kind = "Object"
    metadata = {
        name = short + "-connector-es"
        annotations = {
            "crossplane.io/composition-resource-name" = "oidc-connector-es"
        } | ({"krm.kcl.dev/ready" = "True"} if _isReady(short + "-connector-es") else {})
    }
    spec = {
        providerConfigRef = {name = "default"}
        forProvider = {
            manifest = {
                apiVersion = "external-secrets.io/v1"
                kind = "ExternalSecret"
                metadata = {name = esName, namespace = "crossplane-system"}
                spec = {
                    refreshInterval = "1h"
                    # OnChange reacts to this resource's own spec changing (e.g. a connector/org/team
                    # update) immediately, instead of waiting up to refreshInterval — confirmed live:
                    # the default policy's shouldRefreshPeriodic() never even looks at generation once
                    # already synced. refreshInterval stays as a periodic backstop.
                    refreshPolicy = "OnChange"
                    secretStoreRef = {name = storeName, kind = "ClusterSecretStore"}
                    data = [{
                        secretKey = "client_secret"
                        remoteRef = {key = oauthVaultKey, property = "client_secret"}
                    }]
                    target = {
                        name = esSecretName
                        creationPolicy = "Owner"
                        template = {
                            engineVersion = "v2"
                            data = {record = _recordJson}
                        }
                    }
                }
            }
        }
    }
}

# ── PushSecret: the record ───────────────────────────────────────────────────
_push_record = {
    apiVersion = "kubernetes.crossplane.io/v1alpha2"
    kind = "Object"
    metadata = {
        name = short + "-push-record"
        annotations = {
            "crossplane.io/composition-resource-name" = "oidc-push-record"
        } | ({"krm.kcl.dev/ready" = "True"} if _isReady(short + "-push-record") else {})
    }
    spec = {
        providerConfigRef = {name = "default"}
        forProvider = {
            manifest = {
                apiVersion = "external-secrets.io/v1alpha1"
                kind = "PushSecret"
                metadata = {name = esName + "-push-record", namespace = "crossplane-system"}
                spec = {
                    # PushSecret has no OnChange/watch equivalent — refreshInterval is its only timing
                    # lever (confirmed: SetupWithManager watches only the PushSecret CR itself, never
                    # the source Secret). Matched to the dexidp chart's own aggregator scan interval
                    # (1m) so a push lands before the chart's next scan, not up to an hour later.
                    refreshInterval = "1m"
                    deletionPolicy = "Delete"
                    secretStoreRefs = [{name = storeName, kind = "ClusterSecretStore"}]
                    selector = {secret = {name = esSecretName}}
                    data = [{
                        match = {
                            secretKey = "record"
                            remoteRef = {remoteKey = recordKey}
                        }
                    }]
                }
            }
        }
    }
}

# ── dxr update — status write-back ──────────────────────────────────────────
_composedNames = [short + "-connector-es", short + "-push-record"]
_created = len([n for n in _composedNames if n not in _ocds]) == 0
_ready = _isReady(short + "-connector-es") and _isReady(short + "-push-record")

# ── Sync state ──────────────────────────────────────────────────────────────
# `synced` follows the same resources `ready` does; a failure on any other composed resource is still
# shown in `syncMessage` without gating anything.
_gatingNames = [short + "-connector-es", short + "-push-record"]
_syncFailures = [n + ": " + _get(_syncConds(n)[0], "message", _get(_syncConds(n)[0], "reason", "not synced")) for n in _ocds if _syncFailed(n)]
_synced = len([n for n in _gatingNames if _syncFailed(n)]) == 0
_syncMessage = (_syncFailures[0] + (" (+" + str(len(_syncFailures) - 1) + " more)" if len(_syncFailures) > 1 else ""))[:400] if _syncFailures else ""
_syncStatus = ({"synced" = _synced} if _ocds else {}) | ({"syncMessage" = _syncMessage} if _syncFailures else {})

_dxr = {
    apiVersion = "auth.wxops.cloud/v1alpha1"
    kind = "XOIDCConnector"
    status = {
        created = _created
        ready = _ready
        vaultKey = recordKey
        teams = _teamsStatus
    } | _syncStatus
}

items = [_dxr, _connector_es, _push_record]
