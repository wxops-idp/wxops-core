"""
XOIDCClient — KCL composition source.

A downstream OAuth client: an application that logs in through the broker (Pinniped, the Portal,
oauth2-proxy). See kcl/oidc-static-password/main.k for the sibling kind this mirrors closely.

Inputs (via option("params").oxr.spec.parameters):
  connectionRef.name    string   The XOIDCConnection this client belongs to.
  clientId              string   The OAuth client id; also this resource's own identifier — the
                                  remote key is <vendor>/clients/{clientId}.
  displayName           string   The record's "name" field. Default "".
  redirectUris          [string] Accepted redirect URIs.
  public                bool     True: no secret, no generator, record carries "public": true.
  trustedPeers          [string] Other client ids allowed to exchange tokens. Default [].
  owner                 string   "platform" only in this release.
  secret.source         string   "generate" or "static" (confidential only).
  secret.generator      object   generate only.
  rotation.generation   int      Bump to regenerate (generate) or re-read (static).

  "static" reads <vendor>/clients-def/{clientId} (property "secret") — the operator writes it
  there first, the same <vendor>/{kind}-def/{id} convention XOIDCStaticPassword uses, derived
  purely from clientId. No separate "where" field to get wrong.

Design: the same two-ExternalSecret split as XOIDCStaticPassword (see its header for the full
reasoning), minus the hash — the client secret is pushed as-is, never bcrypt'd.

  ESO1 (oidc-secret-es, generate only) owns the SECRET: Password generator -> {secret, generation}
  -> its own PushSecret -> <vendor>/clients-def/{clientId}. Periodic / 99999h, refreshed only by a
  change to its top-level `force-sync` annotation, which carries rotation.generation.
  ESO2 (oidc-client-es) owns the RECORD, OnChange: reads `secret` from clients-def (written there
  by ESO1 in generate mode, by the operator in static mode), so a field edit never touches the
  generator. generate only: it fails its own render until clients-def carries the generation this XR
  asks for.
  "public" skips all of it: the record renders from literal XR fields alone, no ESO1, no source.

Composed resources:
  oidc-secret-gen     generators.external-secrets.io/v1alpha1  Password        — generate + confidential only.
  oidc-secret-es      external-secrets.io/v1                   ExternalSecret  — ESO1, generate + confidential only.
  oidc-push-secret    external-secrets.io/v1alpha1              PushSecret     — ESO1 -> <vendor>/clients-def/{clientId}.
  oidc-client-es      external-secrets.io/v1                   ExternalSecret  — ESO2, renders the record.
  oidc-push-record    external-secrets.io/v1alpha1              PushSecret     — <vendor>/clients/{clientId}.
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
vendor = _get(_connParams, "vendor", "dex")
storeName = _get(_get(_connParams, "secretStoreRef", {}), "name", "vault-platform")

clientId = params.clientId
displayName = _get(params, "displayName", "")
redirectUris = params.redirectUris
public = _get(params, "public", False)
trustedPeers = _get(params, "trustedPeers", [])
generation = _get(_get(params, "rotation", {}), "generation", 1)

secretCfg = _get(params, "secret", {})
source = _get(secretCfg, "source", "generate")
isGenerate = (not public) and source == "generate"
isStatic = (not public) and source == "static"
gen = _get(secretCfg, "generator", {})

genName = short + "-secret-gen"
secretEsName = short + "-secret-es"
secretDefSecretName = "oidc-" + short + "-secret-def"
esName = short + "-client-es"
esSecretName = "oidc-" + short + "-client-creds"
recordKey = vendor + "/clients/" + clientId
# Same <vendor>/{kind}-def/{id} convention as XOIDCStaticPassword's pwdDefKey — derived purely
# from clientId, no operator-specified "where" field.
staticSecretKey = vendor + "/clients-def/" + clientId

# generate only: fail ESO2's render until clients-def carries the generation this XR asks for —
# a bump re-triggers ESO1 and ESO2 together, so ESO2 could otherwise read the previous secret and
# settle on it. See kcl/oidc-static-password/main.k for the full reasoning.
_genGate = ('{{ if ne .generation "' + str(generation) + '" }}{{ fail "waiting for ' + staticSecretKey + ' generation ' + str(generation) + '" }}{{ end }}') if isGenerate else ""

_urisJson = "[" + ", ".join(['"' + u + '"' for u in redirectUris]) + "]"
_peersJson = "[" + ", ".join(['"' + p + '"' for p in trustedPeers]) + "]"
_peersField = (',"trustedPeers":"' + _peersJson.replace('"', '\\"') + '"') if trustedPeers else ""
_secretField = '"public":true' if public else '"secret":"{{ .password }}"'

# redirectURIs (always) and trustedPeers (if set) are arrays — ESO's Vault provider panics
# comparing an existing array top-level value with property empty (maps.Equal — see
# providers/v1/vault/client_push.go) on every push after the first. Embedded below as escaped
# STRINGs, not native arrays, so every top-level field of the pushed record is a plain string —
# safe to push in one call, one KV version, instead of extra PushSecret entries (which also mean
# extra, separate versions). The dexidp chart already un-stringifies both if they arrive this way.
_recordJson = '{"id":"' + clientId + '","name":"' + displayName + '","redirectURIs":"' + _urisJson.replace('"', '\\"') + '"' + _peersField + ',' + _secretField + '}'

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

# ── ESO Password generator (confidential + generate only) ───────────────────
_secret_gen = {
    apiVersion = "kubernetes.crossplane.io/v1alpha2"
    kind = "Object"
    metadata = {
        name = short + "-secret-gen"
        annotations = {
            "crossplane.io/composition-resource-name" = "oidc-secret-gen"
        } | ({"krm.kcl.dev/ready" = "True"} if _isReady(short + "-secret-gen") else {})
    }
    spec = {
        providerConfigRef = {name = "default"}
        forProvider = {
            manifest = {
                apiVersion = "generators.external-secrets.io/v1alpha1"
                kind = "Password"
                metadata = {name = genName, namespace = "crossplane-system"}
                spec = {
                    length = _get(gen, "length", 32)
                    digits = _get(gen, "digits", 8)
                    symbols = _get(gen, "symbols", 0)
                    symbolCharacters = ""
                    noUpper = False
                    allowRepeat = False
                }
            }
        }
    }
}

# ── ESO1: the secret — generator -> {secret, generation}, generate + confidential only ──────────────
# Periodic with a 99999h interval: with an interval > 0 shouldRefreshPeriodic() compares
# SyncedResourceVersion with GetResourceVersion() (= "<generation>-<hash(annotations, labels)>"),
# so a changed top-level annotation refreshes it at once; 99999h is only the backstop. `force-sync`
# is just an arbitrary annotation key — ESO has no special handling for it — carrying
# rotation.generation: it changes when, and only when, a human bumps the generation (a timestamp
# would change on every reconcile and regenerate constantly). `def` is a JSON document of two
# scalars, pushed in one call with property empty (one KV version); toJson only quotes/escapes the
# value for that transport — OpenBao stores the raw string.
_secret_es = {
    apiVersion = "kubernetes.crossplane.io/v1alpha2"
    kind = "Object"
    metadata = {
        name = short + "-secret-es"
        annotations = {
            "crossplane.io/composition-resource-name" = "oidc-secret-es"
        } | ({"krm.kcl.dev/ready" = "True"} if _isReady(short + "-secret-es") else {})
    }
    spec = {
        providerConfigRef = {name = "default"}
        forProvider = {
            manifest = {
                apiVersion = "external-secrets.io/v1"
                kind = "ExternalSecret"
                metadata = {
                    name = secretEsName
                    namespace = "crossplane-system"
                    annotations = {"force-sync" = str(generation)}
                }
                spec = {
                    refreshPolicy = "Periodic"
                    refreshInterval = "99999h"
                    dataFrom = [{
                        sourceRef = {
                            generatorRef = {
                                apiVersion = "generators.external-secrets.io/v1alpha1"
                                kind = "Password"
                                name = genName
                            }
                        }
                    }]
                    target = {
                        name = secretDefSecretName
                        creationPolicy = "Owner"
                        template = {
                            engineVersion = "v2"
                            data = {def = '{"secret":{{ .password | toJson }},"generation":"' + str(generation) + '"}'}
                        }
                    }
                }
            }
        }
    }
}

# ── PushSecret: ESO1's {secret, generation} -> clients-def, generate only ───────────────────────────
# Property empty is correct: `def` is a JSON document of scalars, so ESO writes both as top-level
# keys in one call, one KV version, and nothing here can trip maps.Equal.
_push_secret = {
    apiVersion = "kubernetes.crossplane.io/v1alpha2"
    kind = "Object"
    metadata = {
        name = short + "-push-secret"
        annotations = {
            "crossplane.io/composition-resource-name" = "oidc-push-secret"
        } | ({"krm.kcl.dev/ready" = "True"} if _isReady(short + "-push-secret") else {})
    }
    spec = {
        providerConfigRef = {name = "default"}
        forProvider = {
            manifest = {
                apiVersion = "external-secrets.io/v1alpha1"
                kind = "PushSecret"
                metadata = {name = secretEsName + "-push", namespace = "crossplane-system"}
                spec = {
                    # PushSecret has no watch on its source Secret — refreshInterval is its only
                    # timing lever; 1m matches the dexidp chart's own scan interval.
                    refreshInterval = "1m"
                    deletionPolicy = "Delete"
                    secretStoreRefs = [{name = storeName, kind = "ClusterSecretStore"}]
                    selector = {secret = {name = secretDefSecretName}}
                    data = [{
                        match = {
                            secretKey = "def"
                            remoteRef = {remoteKey = staticSecretKey}
                        }
                    }]
                }
            }
        }
    }
}

# ── ESO2: the record. Reads the secret from clients-def (a generator wrote it there in generate
# mode, the operator in static mode) — never the generator itself. public: no source at all, the
# template is literal and every value is already on the XR. ─────────────────────────────────────
_source_block = {} if public else {
    secretStoreRef = {name = storeName, kind = "ClusterSecretStore"}
    data = [{
        secretKey = "password"
        remoteRef = {key = staticSecretKey, property = "secret"}
    }] + ([{
        secretKey = "generation"
        remoteRef = {key = staticSecretKey, property = "generation"}
    }] if isGenerate else [])
}

_client_es = {
    apiVersion = "kubernetes.crossplane.io/v1alpha2"
    kind = "Object"
    metadata = {
        name = short + "-client-es"
        annotations = {
            "crossplane.io/composition-resource-name" = "oidc-client-es"
        } | ({"krm.kcl.dev/ready" = "True"} if _isReady(short + "-client-es") else {})
    }
    spec = {
        providerConfigRef = {name = "default"}
        forProvider = {
            manifest = {
                apiVersion = "external-secrets.io/v1"
                kind = "ExternalSecret"
                metadata = {name = esName, namespace = "crossplane-system"}
                spec = {
                    # OnChange reacts to this resource's own spec changing (any field edit, a
                    # generation bump) and ignores refreshInterval — the default policy at interval
                    # "0" never re-syncs once synced (confirmed live). Safe now: this resource has
                    # no generator, so a refresh only re-reads clients-def.
                    refreshPolicy = "OnChange"
                    refreshInterval = "0"
                } | _source_block | {
                    target = {
                        name = esSecretName
                        creationPolicy = "Owner"
                        template = {
                            engineVersion = "v2"
                            metadata = {annotations = {"auth.wxops.cloud/generation" = str(generation)}}
                            data = {record = _genGate + _recordJson}
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
                    # lever (confirmed: it watches only the PushSecret CR itself, never the source
                    # Secret). Matched to the dexidp chart's own aggregator scan interval (1m) so a
                    # push lands before the chart's next scan, not up to an hour later.
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
_composedNames = [short + "-client-es", short + "-push-record"] + ([short + "-secret-gen", short + "-secret-es", short + "-push-secret"] if isGenerate else [])
_created = len([n for n in _composedNames if n not in _ocds]) == 0
_ready = _isReady(short + "-client-es") and _isReady(short + "-push-record") and ((_isReady(short + "-secret-es") and _isReady(short + "-push-secret")) if isGenerate else True)

# ── Sync state ──────────────────────────────────────────────────────────────
# `synced` follows the same resources `ready` does; a failure on any other composed resource is still
# shown in `syncMessage` without gating anything.
_gatingNames = [short + "-client-es", short + "-push-record"] + ([short + "-secret-es", short + "-push-secret"] if isGenerate else [])
_syncFailures = [n + ": " + _get(_syncConds(n)[0], "message", _get(_syncConds(n)[0], "reason", "not synced")) for n in _ocds if _syncFailed(n)]
_synced = len([n for n in _gatingNames if _syncFailed(n)]) == 0
_syncMessage = (_syncFailures[0] + (" (+" + str(len(_syncFailures) - 1) + " more)" if len(_syncFailures) > 1 else ""))[:400] if _syncFailures else ""
_syncStatus = ({"synced" = _synced} if _ocds else {}) | ({"syncMessage" = _syncMessage} if _syncFailures else {})

_dxr = {
    apiVersion = "auth.wxops.cloud/v1alpha1"
    kind = "XOIDCClient"
    status = {
        created = _created
        ready = _ready
        clientId = clientId
        vaultKey = recordKey
    } | _syncStatus
}

items = [_dxr] + ([_secret_gen, _secret_es, _push_secret] if isGenerate else []) + [_client_es, _push_record]
