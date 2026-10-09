#!/usr/bin/env python3
"""
Work with the openAPIV3Schema out of package/<pkg>/xrd.yaml.

This is the strict half of the suite: these are *our* schemas, the contract the
portal will bind to, so they are validated exactly rather than best-effort.

Three jobs:

  validate()        — does this XR satisfy our XRD? (types, enums, required,
                      minimum/maximum)
  apply_defaults()  — produce the XR a cluster's API server would actually hand
                      the composition. Without this, tests feed undefaulted
                      input and exercise KCL's `_get` fallbacks instead of the
                      real defaults, so a disagreement between the two is
                      invisible.
  unknown_fields()  — fields absent from the schema. Kubernetes **silently
                      prunes** these rather than erroring, which makes a typo'd
                      field name one of the most confusing failures to debug:
                      the value simply never arrives. We are deliberately
                      stricter than the API server here.
"""
from __future__ import annotations

from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[2]


def load(package: str, version: str | None = None) -> tuple[str, dict]:
    """Return (version_name, openAPIV3Schema) for a package's XRD."""
    import packages  # local to lib/
    doc = yaml.safe_load((packages.path(package) / "xrd.yaml").read_text())
    return load_doc(doc, version, label=package)


def load_doc(doc: dict, version: str | None = None,
             label: str = "XRD") -> tuple[str, dict]:
    """load() for an XRD that is already parsed — e.g. read at a release tag."""
    versions = ((doc or {}).get("spec") or {}).get("versions") or []
    if not versions:
        raise ValueError(f"{label}: XRD has no spec.versions")
    v = versions[0]
    if version:
        v = next((x for x in versions if x.get("name") == version), None)
        if v is None:
            raise ValueError(f"{label}: no version {version}")
    return v["name"], v["schema"]["openAPIV3Schema"]


def spec_schema(package: str, version: str | None = None) -> tuple[str, dict]:
    """The schema for spec only.

    apiVersion/kind/metadata are supplied by the API server machinery, not the
    XRD, so validating the whole document would report them as unknown.
    """
    name, schema = load(package, version)
    return name, ((schema.get("properties") or {}).get("spec") or {})


def _sanitise(node):
    """Strip Kubernetes extensions that jsonschema does not understand.

    Unknown keywords are ignored by jsonschema, but `nullable` (OpenAPI, not
    JSON Schema) would otherwise be silently meaningless — drop it explicitly so
    the behaviour is intentional rather than accidental.
    """
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if k.startswith("x-kubernetes-") or k == "nullable":
                continue
            out[k] = _sanitise(v)
        return out
    if isinstance(node, list):
        return [_sanitise(v) for v in node]
    return node


def validate(schema: dict, instance) -> list[str]:
    """Return human-readable violations, empty when valid."""
    validator = Draft202012Validator(_sanitise(schema))
    out = []
    for err in sorted(validator.iter_errors(instance), key=lambda e: list(e.path)):
        loc = ".".join(str(p) for p in err.path) or "(root)"
        out.append(f"{loc}: {err.message}")
    return out


def apply_defaults(schema: dict, instance):
    """Apply schema defaults the way a Kubernetes API server would.

    Key semantic: a default nested inside an object is only applied when that
    object is itself present, or when the object carries its own `default: {}`.
    Many fields in these XRDs rely on exactly that to make a whole block
    optional while still defaulting its contents.
    """
    if not isinstance(schema, dict):
        return instance

    if schema.get("type") == "object" or "properties" in schema:
        if instance is None:
            instance = {}
        if not isinstance(instance, dict):
            return instance
        out = dict(instance)
        for key, sub in (schema.get("properties") or {}).items():
            if key in out:
                out[key] = apply_defaults(sub, out[key])
            elif isinstance(sub, dict) and "default" in sub:
                out[key] = apply_defaults(sub, sub["default"])
        return out

    if schema.get("type") == "array" and isinstance(instance, list):
        item = schema.get("items") or {}
        return [apply_defaults(item, i) for i in instance]

    return instance


def unknown_fields(schema: dict, instance, path: str = "spec") -> list[str]:
    """Paths in `instance` that the schema does not describe.

    Stops descending at x-kubernetes-preserve-unknown-fields, where arbitrary
    content is legitimate, and at additionalProperties, where free-form keys are
    the point (labels, annotations, extraParameters).
    """
    if not isinstance(schema, dict) or not isinstance(instance, dict):
        return []
    if schema.get("x-kubernetes-preserve-unknown-fields"):
        return []

    props = schema.get("properties") or {}
    addl = schema.get("additionalProperties")
    out = []

    for key, value in instance.items():
        sub = props.get(key)
        if sub is None:
            if addl in (None, False):
                out.append(f"{path}.{key}")
            continue
        here = f"{path}.{key}"
        if isinstance(value, dict):
            out += unknown_fields(sub, value, here)
        elif isinstance(value, list):
            item = sub.get("items") or {}
            for i, entry in enumerate(value):
                if isinstance(entry, dict):
                    out += unknown_fields(item, entry, f"{here}[{i}]")
    return out
