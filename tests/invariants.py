#!/usr/bin/env python3
"""
Cross-cutting invariants over rendered composition output.

Golden files catch *changes*. These catch *wrongness* — rules that must hold for
every package and every case, including cases nobody has written yet. Each rule
here exists because violating it fails silently in a real cluster: no error, no
event, just a resource that never reconciles or a series that never appears.

Usage:
    python3 tests/invariants.py            # all cases
    python3 tests/invariants.py tenant-app # one package
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import render as R  # noqa: E402

# ── Rule registry ───────────────────────────────────────────────────────────
# A rule is a function (docs, ctx) -> list[str] of violation messages.
RULES = []


def rule(name: str, why: str):
    def deco(fn):
        fn.rule_name = name
        fn.rule_why = why
        RULES.append(fn)
        return fn
    return deco


def _composed(docs):
    """Composed resources — those carrying the composition-resource-name annotation."""
    out = []
    for d in docs:
        ann = ((d.get("metadata") or {}).get("annotations") or {})
        if "crossplane.io/composition-resource-name" in ann:
            out.append(d)
    return out


def _xr(docs):
    """The composite resource itself: the one document that is not composed."""
    for d in docs:
        ann = ((d.get("metadata") or {}).get("annotations") or {})
        if "crossplane.io/composition-resource-name" not in ann:
            return d
    return {}


def _wrapped(doc):
    """The manifest inside a provider-kubernetes Object, or None."""
    if doc.get("kind") != "Object":
        return None
    return ((doc.get("spec") or {}).get("forProvider") or {}).get("manifest")


def _name(doc) -> str:
    return str((doc.get("metadata") or {}).get("name", "?"))


# ── Security / architecture boundaries ──────────────────────────────────────

RBAC_KINDS = {"Role", "ClusterRole", "RoleBinding", "ClusterRoleBinding"}
RBAC_GROUP = "rbac.authorization.k8s.io"


def _is_k8s_rbac(doc) -> bool:
    """True only for Kubernetes RBAC.

    The kind alone is not enough: provider-sql's PostgreSQL role is also
    `kind: Role`, under postgresql.sql.crossplane.io. Matching on kind flags it
    as an RBAC violation, which it is not.
    """
    return (doc.get("kind") in RBAC_KINDS
            and str(doc.get("apiVersion", "")).split("/")[0] == RBAC_GROUP)


@rule("no-rbac-emitted",
      "Compositions must never emit Kubernetes RBAC. provider-kubernetes is "
      "deliberately not granted rbac.authorization.k8s.io, so these would fail "
      "`forbidden` — and granting it would make the provider a "
      "privilege-escalation vector. RBAC belongs in the GitOps repo. "
      "See development-docs/ROADMAP.md 'Decided and rejected'.")
def no_rbac(docs, ctx):
    bad = []
    for d in _composed(docs):
        m = _wrapped(d)
        if m and _is_k8s_rbac(m):
            bad.append(f"{_name(d)} wraps a {m['apiVersion']} {m['kind']}")
        if _is_k8s_rbac(d):
            bad.append(f"{_name(d)} is a {d['apiVersion']} {d['kind']}")
    return bad


# Packages still on provider-terraform. RFC-003 retires them (Phase 4); delete this set, and
# providers/archive/provider-terraform.yaml, together with them. Nothing else may be added to it.
LEGACY_TERRAFORM_PACKAGES = {"gitea-user", "gitea-org", "gitea-team", "gitea-repository"}


@rule("workspace-uses-opentofu",
      "New compositions run inline HCL through provider-opentofu (opentofu.upbound.io), not "
      "provider-terraform (tf.upbound.io): the terraform binary is BSL-licensed, and this "
      "project's runtime stack is meant to stay open source. Only the gitea-* packages, which "
      "RFC-003 retires, may still emit a tf.upbound.io Workspace. See "
      "development-docs/rfc/002-migrate-terraform-to-opentofu.md.")
def workspace_uses_opentofu(docs, ctx):
    if ctx.get("package") in LEGACY_TERRAFORM_PACKAGES:
        return []
    return [
        f"{_name(d)} is a {d['apiVersion']} {d['kind']}"
        for d in _composed(docs)
        if str(d.get("apiVersion", "")).startswith("tf.upbound.io/")
    ]


SENSITIVE_HINTS = ("password", "secret", "token", "credential", "privatekey")


@rule("no-secrets-in-status",
      "Sensitive values must never reach XR status — status is world-readable to "
      "anyone with get on the XR. Terraform marks such outputs sensitive so they "
      "go to the connection secret instead; a ToCompositeFieldPath patch would "
      "defeat that.")
def no_secrets_in_status(docs, ctx):
    bad = []
    status = _xr(docs).get("status") or {}
    for key in status:
        low = key.lower()
        if any(h in low for h in SENSITIVE_HINTS):
            bad.append(f"XR status.{key} looks sensitive")
    return bad


# ── Provider wiring ─────────────────────────────────────────────────────────

@rule("object-has-providerconfig",
      "An Object with no providerConfigRef falls back to a ProviderConfig named "
      "'default' implicitly; if that does not exist the resource never "
      "reconciles. Naming it explicitly is also what makes targetCluster work.")
def object_has_providerconfig(docs, ctx):
    bad = []
    for d in _composed(docs):
        if d.get("kind") != "Object":
            continue
        ref = (d.get("spec") or {}).get("providerConfigRef") or {}
        if not ref.get("name"):
            bad.append(f"{_name(d)} has no spec.providerConfigRef.name")
    return bad


@rule("providerconfig-follows-cluster",
      "When spec.parameters.cluster is set, every composed Object must be applied "
      "through that ProviderConfig. An Object left on 'default' would silently "
      "land on the hub while the rest of the XR goes to the spoke.")
def providerconfig_follows_cluster(docs, ctx):
    want = ((ctx.get("xr_params") or {}).get("cluster"))
    if not want:
        return []
    bad = []
    for d in _composed(docs):
        if d.get("kind") != "Object":
            continue
        got = ((d.get("spec") or {}).get("providerConfigRef") or {}).get("name")
        if got != want:
            bad.append(f"{_name(d)} targets '{got}', expected '{want}'")
    return bad


@rule("composed-has-resource-name",
      "crossplane.io/composition-resource-name is the composed resource's stable "
      "identity. Without it Crossplane cannot correlate desired with observed, so "
      "it deletes and recreates the resource on every reconcile.")
def composed_has_resource_name(docs, ctx):
    bad = []
    for d in docs:
        if d.get("kind") != "Object":
            continue
        ann = ((d.get("metadata") or {}).get("annotations") or {})
        if not ann.get("crossplane.io/composition-resource-name"):
            bad.append(f"{_name(d)} has no composition-resource-name annotation")
    return bad


# ── Observability ───────────────────────────────────────────────────────────

MONITOR_KINDS = {"ServiceMonitor", "PodMonitor"}
PROM_RELEASE = "kube-prometheus-stack"


@rule("monitor-has-release-label",
      "Prometheus runs with serviceMonitorSelectorNilUsesHelmValues: true, so the "
      "Operator only picks up monitors labelled with its Helm release name. "
      "Without it the monitor is created successfully and simply never scrapes — "
      "no error anywhere.")
def monitor_has_release_label(docs, ctx):
    bad = []
    for d in _composed(docs):
        m = _wrapped(d)
        if not m or m.get("kind") not in MONITOR_KINDS:
            continue
        labels = (m.get("metadata") or {}).get("labels") or {}
        if labels.get("release") != PROM_RELEASE:
            bad.append(f"{_name(d)}: release={labels.get('release')!r}, expected {PROM_RELEASE!r}")
    return bad


@rule("monitor-excludes-darlane",
      "The Darlane twin shares app.kubernetes.io/name and /instance with the main "
      "app and differs only by /component. A monitor selecting without component "
      "scrapes the debug twin into the service's own series.")
def monitor_excludes_darlane(docs, ctx):
    bad = []
    for d in _composed(docs):
        m = _wrapped(d)
        if not m or m.get("kind") not in MONITOR_KINDS:
            continue
        sel = ((m.get("spec") or {}).get("selector") or {}).get("matchLabels") or {}
        if "app.kubernetes.io/component" not in sel:
            bad.append(f"{_name(d)}: selector lacks app.kubernetes.io/component")
    return bad


@rule("monitor-has-sample-limit",
      "Prometheus runs with sampleLimit, targetLimit and labelLimit all 0 — no "
      "global guardrail. One tenant emitting raw URLs as a label degrades "
      "Prometheus for every tenant, so the limit must come from the composition.")
def monitor_has_sample_limit(docs, ctx):
    bad = []
    for d in _composed(docs):
        m = _wrapped(d)
        if not m or m.get("kind") not in MONITOR_KINDS:
            continue
        if not ((m.get("spec") or {}).get("sampleLimit")):
            bad.append(f"{_name(d)}: no spec.sampleLimit")
    return bad


@rule("no-inert-prometheus-annotations",
      "prometheus.io/* pod annotations are a convention read only by a "
      "kubernetes_sd_config job with matching relabel rules. "
      "kube-prometheus-stack's additionalScrapeConfigs is empty here, so these "
      "annotations scrape nothing and give a false impression of coverage.")
def no_inert_prometheus_annotations(docs, ctx):
    bad = []
    for d in _composed(docs):
        m = _wrapped(d)
        if not m or m.get("kind") != "Deployment":
            continue
        tmpl = (((m.get("spec") or {}).get("template") or {}).get("metadata") or {})
        for k in (tmpl.get("annotations") or {}):
            if k.startswith("prometheus.io/"):
                bad.append(f"{_name(d)}: pod annotation {k} is inert — use spec.parameters.monitoring")
    return bad


# ── Status contract ─────────────────────────────────────────────────────────

@rule("status-exposes-readiness",
      "The portal polls status.ready on every package. Crossplane v2.3 + "
      "function-kcl v0.12.1 leave the native type:Ready condition unreliable, so "
      "an XR without status.ready gives consumers nothing trustworthy to read.")
def status_exposes_readiness(docs, ctx):
    status = _xr(docs).get("status") or {}
    # patch-and-transform packages omit the field entirely until the first
    # successful apply (Optional policy skips the patch), so absence is only a
    # violation when the case supplies observed state.
    if not ctx.get("has_observed"):
        return []
    missing = [f for f in ("created", "ready") if f not in status]
    return [f"XR status lacks {', '.join(missing)}"] if missing else []


@rule("ready-implies-created",
      "ready without created is incoherent: a resource cannot be healthy before "
      "it has been observed to exist. It means the two are derived from "
      "unrelated signals.")
def ready_implies_created(docs, ctx):
    status = _xr(docs).get("status") or {}
    if status.get("ready") is True and status.get("created") is False:
        return ["XR reports ready: true with created: false"]
    return []


# ── Third-party field contracts ─────────────────────────────────────────────
# We do not own these schemas and deliberately do not try to validate them
# exhaustively — that is what the pinned structural check is for, best-effort.
# What we DO own is the set of fields we template into them, and the decisions
# those fields encode. These assertions are version-independent: they keep
# holding across a CNPG or Traefik upgrade, which is exactly what a public
# schema catalogue cannot promise.

def _of_kind(docs, kind, api_prefix=None):
    for d in _composed(docs):
        m = _wrapped(d)
        if not m or m.get("kind") != kind:
            continue
        if api_prefix and not str(m.get("apiVersion", "")).startswith(api_prefix):
            continue
        yield _name(d), m


@rule("vault-remotekey-omits-mount",
      "The ClusterSecretStore is already scoped to its KV mount, so a remoteKey "
      "repeating that prefix writes to platform/platform/... or tenants/tenants/... "
      "No schema catches this — the write succeeds, at the wrong path.")
def vault_remotekey_omits_mount(docs, ctx):
    bad = []
    for name, m in _of_kind(docs, "PushSecret"):
        for entry in (m.get("spec") or {}).get("data") or []:
            key = (((entry.get("match") or {}).get("remoteRef") or {}).get("remoteKey") or "")
            for prefix in ("platform/", "tenants/"):
                if key.startswith(prefix):
                    bad.append(f"{name}: remoteKey '{key}' repeats the '{prefix}' mount prefix")
    return bad


@rule("pushsecret-store-is-cluster-scoped",
      "These compositions reference ClusterSecretStore, not a namespaced "
      "SecretStore — a namespaced store would have to exist in every tenant "
      "namespace. A wrong kind here fails at reconcile, not at render.")
def pushsecret_store_kind(docs, ctx):
    bad = []
    for name, m in _of_kind(docs, "PushSecret"):
        for ref in (m.get("spec") or {}).get("secretStoreRefs") or []:
            if ref.get("kind") != "ClusterSecretStore":
                bad.append(f"{name}: secretStoreRef kind is {ref.get('kind')!r}")
        if not ((m.get("spec") or {}).get("selector") or {}).get("secret", {}).get("name"):
            bad.append(f"{name}: no spec.selector.secret.name — nothing to push")
    return bad


@rule("pushsecret-deletion-policy-known",
      "deletionPolicy drives whether the Vault entry is torn down with the XR. "
      "An unrecognised value is treated as the ESO default, silently changing "
      "retain/delete semantics for tenant credentials.")
def pushsecret_deletion_policy(docs, ctx):
    bad = []
    for name, m in _of_kind(docs, "PushSecret"):
        pol = (m.get("spec") or {}).get("deletionPolicy")
        if pol not in ("Delete", "None"):
            bad.append(f"{name}: deletionPolicy {pol!r} is not Delete or None")
    return bad


@rule("externalsecret-has-target-name",
      "Without spec.target.name ESO derives the Secret name from the "
      "ExternalSecret, which is uid-prefixed here — the workload would look for a "
      "Secret that does not exist under the name it expects.")
def externalsecret_target(docs, ctx):
    bad = []
    for name, m in _of_kind(docs, "ExternalSecret"):
        if not ((m.get("spec") or {}).get("target") or {}).get("name"):
            bad.append(f"{name}: no spec.target.name")
    return bad


@rule("cnpg-cluster-sizing-well-formed",
      "instances must be an int (a quoted number is accepted by YAML but rejected "
      "by CNPG) and storage.size must carry a unit — '8' provisions unpredictably "
      "where '8Gi' is meant.")
def cnpg_sizing(docs, ctx):
    import re as _re
    bad = []
    for name, m in _of_kind(docs, "Cluster", "postgresql.cnpg.io"):
        spec = m.get("spec") or {}
        inst = spec.get("instances")
        if not isinstance(inst, int) or isinstance(inst, bool):
            bad.append(f"{name}: spec.instances is {inst!r}, expected an int")
        size = (spec.get("storage") or {}).get("size")
        if not (isinstance(size, str) and _re.fullmatch(r"\d+(\.\d+)?[KMGTP]i?", size)):
            bad.append(f"{name}: spec.storage.size {size!r} has no valid unit suffix")
    return bad


@rule("ingressroute-routable",
      "A route with no match matches nothing and an IngressRoute with no "
      "entryPoints is never attached to a listener. Both reconcile cleanly and "
      "serve no traffic.")
def ingressroute_routable(docs, ctx):
    bad = []
    for name, m in _of_kind(docs, "IngressRoute", "traefik.io"):
        spec = m.get("spec") or {}
        if not spec.get("entryPoints"):
            bad.append(f"{name}: no spec.entryPoints")
        routes = spec.get("routes") or []
        if not routes:
            bad.append(f"{name}: no spec.routes")
        for i, r in enumerate(routes):
            if not r.get("match"):
                bad.append(f"{name}: routes[{i}] has no match")
            for svc in r.get("services") or []:
                if not svc.get("name"):
                    bad.append(f"{name}: routes[{i}] service has no name")
    return bad


@rule("certificate-has-issuer-and-secret",
      "cert-manager needs both an issuerRef and a secretName; the Traefik "
      "IngressRoute's tls.secretName must match or TLS silently serves the "
      "default certificate.")
def certificate_wiring(docs, ctx):
    bad = []
    certs = list(_of_kind(docs, "Certificate", "cert-manager.io"))
    for name, m in certs:
        spec = m.get("spec") or {}
        if not (spec.get("issuerRef") or {}).get("name"):
            bad.append(f"{name}: no spec.issuerRef.name")
        if not spec.get("secretName"):
            bad.append(f"{name}: no spec.secretName")
    cert_secrets = {(m.get("spec") or {}).get("secretName") for _, m in certs}
    if cert_secrets:
        for name, m in _of_kind(docs, "IngressRoute", "traefik.io"):
            tls_secret = ((m.get("spec") or {}).get("tls") or {}).get("secretName")
            if tls_secret and tls_secret not in cert_secrets:
                bad.append(f"{name}: tls.secretName {tls_secret!r} matches no composed Certificate")
    return bad


# ── Runner ──────────────────────────────────────────────────────────────────

def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    cases = R.discover()
    if args:
        cases = [c for c in cases if c[0] in args]
    if not cases:
        print(f"{R.RED}no test cases found{R.RESET}")
        return 1

    print(f"invariants — {len(RULES)} rule(s) × {len(cases)} case(s)\n")
    violations: dict[str, list[str]] = {}
    checked = 0

    for package, case, case_dir in cases:
        label = f"{package}/{case}"
        golden = case_dir / "expected.yaml"
        # Prefer the committed golden so invariants run without Docker; fall
        # back to a live render when no golden exists yet.
        if golden.exists():
            docs = R.load_docs(golden.read_text())
        else:
            ok, out, err = R.render(case_dir, package)
            if not ok:
                print(f"  {R.RED}RENDER FAIL{R.RESET}  {label}: {err.splitlines()[0] if err else ''}")
                violations.setdefault("render", []).append(label)
                continue
            docs = R.load_docs(out)

        import yaml as _y
        xr_doc = _y.safe_load((case_dir / "xr.yaml").read_text())
        ctx = {
            "package": package,
            "case": case,
            "xr_params": ((xr_doc.get("spec") or {}).get("parameters") or {}),
            "has_observed": (case_dir / "observed.yaml").exists(),
        }

        case_bad = []
        for fn in RULES:
            for msg in fn(docs, ctx):
                case_bad.append(f"{fn.rule_name}: {msg}")
                violations.setdefault(fn.rule_name, []).append(f"{label} — {msg}")
        checked += 1

        if case_bad:
            print(f"  {R.RED}FAIL{R.RESET}         {label}")
            for m in case_bad:
                print(f"      {R.RED}{m}{R.RESET}")
        else:
            print(f"  {R.GREEN}ok{R.RESET}           {label}")

    print()
    if violations:
        print(f"{R.RED}{sum(len(v) for v in violations.values())} violation(s) "
              f"across {len(violations)} rule(s){R.RESET}\n")
        by_name = {fn.rule_name: fn for fn in RULES}
        for name in violations:
            fn = by_name.get(name)
            if fn:
                print(f"  {R.YELLOW}{name}{R.RESET}\n      {R.DIM}{fn.rule_why}{R.RESET}\n")
        return 1
    print(f"{R.GREEN}all {len(RULES)} rule(s) hold across {checked} case(s){R.RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
