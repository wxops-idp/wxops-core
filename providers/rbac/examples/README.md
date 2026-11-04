# RBAC aggregation — examples

Not applied: no kustomization lists these files. They show how to extend the persona and Platform API roles.

Persona and Platform API roles are **aggregated** `ClusterRole`s (`providers/rbac/aggregate-*.yaml`). Adding a permission is one small `ClusterRole` carrying one label;
every persona bound to that role gains it, in every cluster. Pieces are static manifests applied through GitOps — **compositions write bindings, never roles**.

| File | What it adds |
|---|---|
| [`persona-piece.yaml`](persona-piece.yaml) | `developers` and `viewers` can read Kyverno PolicyReports — to see why a request was refused |
| [`platform-piece.yaml`](platform-piece.yaml) | A new tenant kind joins `wxops:platform-edit` (and so `platform-admin`) |
| [`tenant-namespace.yaml`](tenant-namespace.yaml) | A namespace as onboarding creates it: owned by a team, discoverable by `XPersonaBinding` |

Check the result:

```bash
kubectl get clusterrole wxops:persona-developers -o yaml            # the merged rules
kubectl auth can-i --list --as=alice --as-group=wxops-idp:payment -n payment-api
```
