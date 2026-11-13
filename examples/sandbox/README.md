# Sandbox kit

One script, `run.sh`, that plays W'xOps against a real cluster and checks every result: logins and personas, bindings, every `XPolicy` template, owner mapping,
the environment gate, and the tenant kinds `XApp` and `XDatabase`. Use it to learn how the packages behave together, and to re-check them after an upgrade.

Each row says who acts, what they try, and what should happen — allowed, refused by a policy, or refused by RBAC first — then prints `PASS` or `FAIL`.

> Run it on a sandbox or test cluster, never on one that serves users. While it runs, the sandbox policies are in `Deny` with `failurePolicy: Fail`.

## Before you start

- **A kubeconfig that may impersonate** (cluster-admin does). The players are impersonated with `--as`/`--as-group`.
- **The packages, from `make install-dev`.** Every XR in the kit tracks the `nightly` composition channel, which `make install-dev` applies; `make install` from the
  registry labels compositions `stable` instead. The `auth` packages are enough for `setup`, `test`, `mapping` and `env-gate`; `tenant` also needs `app` and
  `database`.
- **The providers:** `make providers`, or at least `make providers-rbac` after installing the packages — the persona roles are what the rows test.
- **Kyverno**, installed at bootstrap ([setup step 0](../../docs/user-guide/setup.md#0---install-wxops-ecosystem-prerequisites--bootstrap)).
- **`curl`** for the port-forward rows, and **`pinniped`** only for real logins.

## Quick start

```bash
cd examples/sandbox
./run.sh setup      # namespaces, personas, bindings, then each template in Deny one at a time, then nginx in each namespace
./run.sh test       # 50 rows: every template, and what the persona roles no longer grant
./run.sh mapping    # owner mapping end to end — cleans up after
./run.sh env-gate   # a prod namespace and prod applications — cleans up after
./run.sh tenant     # XApp and XDatabase in a team's namespace — cleans up after
./run.sh compare    # your platform persona vs your own kubeconfig, by `kubectl auth can-i` — writes nothing
./run.sh teardown   # everything the kit created, the Dex users and any open session
```

## Modes

| Mode | What it plays | Needs | Writes |
|---|---|---|---|
| `setup` | The sandbox: namespaces A and B, three personas, three bindings, eight templates in `Deny`, nginx and fixtures in each namespace | the `auth` packages | the sandbox, until `teardown` |
| `test` | Every template: `owner-stamp`, `owner-seal`, `secret-guard`, `exec-guard`, `protected`, `rbac-guard`, `sa-guard`, `namespace-guard`; and what a team's role no longer grants | `setup` | a few objects per row, reset on each run |
| `mapping` | A team mapped to team-a's owner gets its binding and passes `owner-seal`, then loses both ([ADR-006](../../development-docs/adr/006-team-owner-mapping.md)) | `setup` | removed after |
| `env-gate` | B labelled `prod`: only the persona trusted with prod changes it by hand — and an `XApp` or `XDatabase` whose own environment is `prod` | `setup`; `app`, `database` for their rows | removed after |
| `tenant` | The lifecycle of [RFC-010 §3](../../development-docs/rfc/010-namespaced-tenant-kinds.md#3-the-admission-lifecycle--mutating-then-validating-per-operation) on `XApp` and `XDatabase` | `setup`, `app`, `database` | removed after |
| `compare` | Your real platform persona against your own kubeconfig | the persona exists | nothing |
| `users`, `session <user>`, `session-end` | The same `test` rows through a real login — see [Real logins](#real-logins) | Dex, Pinniped | three Dex users, a local session |
| `teardown` | Removes the sandbox and anything an interrupted mode left behind | — | — |

## The cast

| Player | Groups | Plays |
|---|---|---|
| `alice` | `wxops-sbx:team-a` | team-a, owner of A; in `sbx-devs`, so she may exec |
| `bob` | `wxops-sbx:team-b` | team-b, owner of B; may write Namespaces (test-only RBAC), so `namespace-guard` is what stops him |
| `paula` | `wxops-sbx:platform` | the platform team, exempt where a policy names `sbx-platform` |
| `carol` | `wxops-sbx:team-a-ops` | `mapping` only: a second team mapped to team-a |
| `dan` | `wxops-sbx:team-b` | `env-gate` only: team-b, but not trusted with prod |
| *you* | your kubeconfig | a `system:` or admin user, never an SCM user: no policy matches it — the column for Argo CD and every controller |

| Namespace | Owner | Bound |
|---|---|---|
| `wxops-sbx-a` (A) | `team-a` | both teams, and the platform persona |
| `wxops-sbx-b` (B) | `team-b` | both teams, and the platform persona |
| `wxops-sbx-c` (C) | none | nobody — `tenant` only, created and removed by the mode |

**Why both teams are owners in both namespaces.** A policy only runs after RBAC says yes. Giving each team a role in the other's namespace leaves the policy as the
only thing that stops a cross-team write or exec — the cases `owner-seal` and `exec-guard` exist for. C is the opposite: no binding at all, so the refusal there is
RBAC's.

**Why a made-up org.** Every sandbox policy lists only `scmOrgs: [wxops-sbx]`, so it runs in `Deny` without touching a real login, and your real persona is never
matched. `compare` covers the real persona instead, read-only.

## The files

| File | What it is |
|---|---|
| [`sandbox.yaml`](sandbox.yaml) | Namespaces A and B, and the personas `sbx-teams`, `sbx-devs`, `sbx-platform` |
| [`bindings.yaml`](bindings.yaml) | `sbx-teams-owned`, `sbx-teams-both`, `sbx-platform-both` |
| [`policies/`](policies) | One `XPolicy` per template, all `Deny` |
| [`workload.yaml`](workload.yaml) | nginx and its Service in each namespace, for the exec and port-forward rows |
| [`namespace-editor.yaml`](namespace-editor.yaml) | Test-only RBAC: team-b may write Namespaces |
| [`mapping.yaml`](mapping.yaml) | `mapping`'s paused team `team-a-ops`, its personas and bindings |
| [`env-gate.yaml`](env-gate.yaml) | `env-gate`'s persona `sbx-prod` and the gate |
| [`users.yaml`](users.yaml) | Three Dex static users for real logins |
| [`run.sh`](run.sh) | The modes; the rows are readable as a list of who tries what |

## What each scenario shows

- **`test`** walks the templates in order. Besides the policies, it checks what the persona roles no longer grant: impersonating a ServiceAccount, requesting its
  token, creating ServiceAccounts, Pods, RoleBindings or Secrets, reading Secrets. Its last rows check that controllers and Crossplane are never matched.
- **`mapping`**: a team `team-a-ops`, labelled `wxops.cloud/owner: team-a`, played by carol. The sandbox has no Git host, so the team is **paused** from its first
  apply and the script writes the `status.oidcGroup` a real team would publish. Rows: the persona's `status.owners`, the RoleBinding in A and none in B, `owner-seal`
  re-rendered with the map, carol allowed in A; then the label removed and carol refused in A **by `owner-seal`** — she keeps RBAC there through a second binding.
  Each step waits for the re-render: a mapping converges, it does not switch.
- **`env-gate`**: B labelled `wxops.cloud/environment: prod`, a persona `sbx-prod` holding only bob, and the gate on `prod`. dan is refused, bob, paula and *you*
  pass, and bob cannot relabel B to `dev` (`namespace-guard`). Then three edges: with the label removed dan passes at once; with `sbx-prod` narrowed to `staging` bob
  is refused after the re-render; with a persona that does not exist nobody passes, and `syncMessage` says so. With the `app` package, the same mode plays the
  **application gate**: dan is refused an `XApp` with `environment: prod` but not `dev` or none, cannot change a prod one to `dev` or delete it, and bob can; with
  `database`, the same for an `XDatabase`. Those XRs are paused and the requests are dry runs, so nothing is composed.
- **`tenant`**: alice creates an `XApp` in A and it comes back stamped `team-a`; she is refused in B by `owner-seal` (her role there allows it) and in C by RBAC; an
  explicit `team-b` label is kept when she is also in team-b and refused when she is not. The same for `XDatabase`. Updates and deletes follow the owner: alice
  cannot change or delete team-b's `XApp`, bob can; a `wxops.cloud/protected` one changes only by paula. Two `XApp`s are composed for real: one in C renders
  nothing and says why, and an nginx in A whose `labels` claim `team-b` gets a Deployment labelled `team-a`, a pod template with no owner (so a change of owner never
  rolls the pods), and pods stamped `team-a`.
- **`compare`** runs `kubectl auth can-i` as your platform persona (`SCM_USER`, `SCM_GROUP`, default `wxops-idp:owners`) and as yourself, in `wxops-platform`.

## Real logins

Impersonation shows what the API server and Kyverno do with a set of groups. A real login also proves that Dex and Pinniped deliver those groups unchanged.

```bash
./run.sh users                    # Dex static users in the sandbox groups, passwords generated into OpenBao
./run.sh session alice            # a kubeconfig with its own Pinniped caches; log in through the browser as alice@sbx.wxops.local
SESSION=alice ./run.sh test       # alice's rows only, after checking the login carries her group
./run.sh session-end              # forget the login, then the same for bob and paula
```

The session's caches live outside the repository (`$XDG_RUNTIME_DIR`). The login is the authorization-code flow any person uses; the password grant is never
used. `mapping`, `env-gate` and `tenant` run by impersonation only.

## Manual scenarios through a real login

`SESSION=<user> ./run.sh test` replays the `test` rows through a login. The scenarios below go further by hand: the tenant kinds, `protected`, the guards, and
`env-gate`, each typed as the user would type it. They need `./run.sh setup` and `./run.sh users`, and one session at a time:

```bash
./run.sh session alice                                      # log in through the browser
KC=${XDG_RUNTIME_DIR:-/tmp}/wxops-sbx-session/kubeconfig     # the session's kubeconfig
kubectl --kubeconfig=$KC auth whoami                        # the username and groups the API server sees — wxops-sbx:team-a must be there
```

To switch user, `./run.sh session-end` and `./run.sh session bob`; `$KC` keeps the same path.

A refusal by a policy reads `admission webhook … denied the request: auth.wxops.cloud: …`; a refusal by RBAC reads `… is forbidden: User …`. Which one you get is
part of the result: a policy refusal means RBAC let the user in and the guardrail stopped them.

| # | As | Try | Expect |
|---|---|---|---|
| 1 | alice | `kubectl --kubeconfig=$KC -n wxops-sbx-a create configmap manual-a --from-literal=k=v`, then `kubectl -n wxops-sbx-a get cm manual-a --show-labels` as you | allowed, labelled `wxops.cloud/owner=team-a` — `owner-stamp` |
| 2 | alice | `kubectl --kubeconfig=$KC -n wxops-sbx-b label configmap seal-b note=alice --overwrite` | policy — `owner-seal`: B is team-b's |
| 3 | alice | `kubectl --kubeconfig=$KC -n wxops-sbx-a label configmap guarded note=alice --overwrite` | policy — `protected`, though team-a owns it |
| 4 | paula | the same as 3 | allowed — the platform persona is exempt |
| 5 | alice | `kubectl --kubeconfig=$KC -n wxops-sbx-a get secret sbx-secret` | RBAC — no team persona reads Secrets |
| 6 | paula | `kubectl --kubeconfig=$KC -n wxops-sbx-a create secret generic manual-p --from-literal=k=v` | policy — `secret-guard` names no exemption: Secrets come from External Secrets Operator |
| 7 | bob | `kubectl --kubeconfig=$KC label namespace wxops-sbx-a wxops.cloud/owner=team-b --overwrite` | policy — `namespace-guard`: owners are the platform team's |
| 8 | alice | `kubectl --kubeconfig=$KC -n wxops-sbx-a create deployment manual-sa --image=nginx:1.27-alpine --dry-run=client -o yaml \| kubectl set serviceaccount --local -f - b-runner -o yaml \| kubectl --kubeconfig=$KC create -f -` | policy — `sa-guard`: `b-runner` is labelled team-b's |
| 9 | alice | `kubectl --kubeconfig=$KC -n wxops-sbx-a exec deploy/web -- nginx -v`, then the same in `wxops-sbx-b` | allowed in A; policy in B — `exec-guard` |
| 10 | bob | `kubectl --kubeconfig=$KC -n wxops-sbx-b port-forward svc/web 8080:80`, then `curl -s localhost:8080` from another terminal | the forward fails with the policy's message — `exec-guard`: bob is not in `sbx-devs` |

**The tenant kinds.** Save an `XApp` once:

```bash
cat > /tmp/manual-app.yaml <<'EOF'
apiVersion: tenant.wxops.cloud/v1alpha1
kind: XApp
metadata: {name: manual-app, namespace: wxops-sbx-a}
spec:
  crossplane: {compositionRevisionSelector: {matchLabels: {channel: nightly}}, compositionUpdatePolicy: Automatic}
  parameters:
    image: nginx:1.27-alpine
    containerPort: 80
    labels: {wxops.cloud/owner: team-b}          # a forged owner: the composition drops it
    probes: {liveness: {enabled: false}, readiness: {enabled: false}}
EOF
```

| # | As | Try | Expect |
|---|---|---|---|
| 11 | alice | `kubectl --kubeconfig=$KC create -f /tmp/manual-app.yaml` | allowed; the `XApp` is labelled `team-a`, and once ready its Deployment `manual-app` too — never `team-b` |
| 12 | alice | `sed 's/wxops-sbx-a/wxops-sbx-b/' /tmp/manual-app.yaml \| kubectl --kubeconfig=$KC create -f -` | policy — `owner-seal`: her role in B allows it, the owner does not |
| 13 | bob | `kubectl --kubeconfig=$KC -n wxops-sbx-a delete xapp manual-app` | policy — `owner-seal`: team-a's |
| 14 | alice | `kubectl --kubeconfig=$KC -n wxops-sbx-a delete xapp manual-app` | allowed — her own; the Deployment goes with it |

**`env-gate`.** The gate trusts the persona `sbx-prod` by **username**, and a real login's username is whatever Pinniped maps from Dex — not the `bob` the
impersonation mode uses. Put the username `auth whoami` printed for bob into the persona first, as you:

```bash
kubectl apply -f env-gate.yaml && kubectl label namespace wxops-sbx-b wxops.cloud/environment=prod --overwrite
kubectl patch xpersona sbx-prod --type=merge -p '{"spec":{"parameters":{"members":{"teams":false,"users":["<bob-username>"]}}}}'
```

| # | As | Try | Expect |
|---|---|---|---|
| 15 | bob | `kubectl --kubeconfig=$KC -n wxops-sbx-b create configmap manual-prod --from-literal=k=v` | allowed — in `sbx-prod` |
| 16 | alice | the same | policy — `owner-seal` first (B is team-b's); to see the gate itself, it takes a second team-b user, as `dan` in `./run.sh env-gate` |
| 17 | bob | after `kubectl patch xpersona sbx-prod --type=merge -p '{"spec":{"parameters":{"environments":["staging"]}}}'` as you, and a nudge so the gate re-renders now — `kubectl annotate xpolicy sbx-env-gate wxops.test/nudge="$(date +%s)" --overwrite` — the same as 15 with another name | policy — `env-gate`: `sbx-prod` no longer reaches prod |

If 15 is refused, the username in `sbx-prod` is not the one the API server sees — that is the finding, and the reason this one is worth a real login.

**Clean up**, as you, then end the session:

```bash
kubectl -n wxops-sbx-a delete configmap manual-a --ignore-not-found; kubectl -n wxops-sbx-a delete deployment manual-sa --ignore-not-found
kubectl -n wxops-sbx-a delete xapp manual-app --ignore-not-found;    kubectl -n wxops-sbx-b delete configmap manual-prod --ignore-not-found
kubectl delete -f env-gate.yaml --ignore-not-found;                  kubectl label namespace wxops-sbx-b wxops.cloud/environment-
./run.sh session-end
```

## Reading the results

- `PASS` — the row got what it wanted: `allow`, `policy` (an admission denial from an `XPolicy`), or `rbac` (forbidden before admission).
- `FAIL` is a **finding**, not a script error: the row prints the first line of what the API server answered. Start from there.
- `exec-guard`'s exec and port-forward rows are the ones to watch: whether Kyverno sees `CONNECT` for `pods/exec` and `pods/portforward` is still an
  [RFC-009 spike](../../development-docs/rfc/009-scm-personas.md#acceptance-matrix).
- The rows that wait for a re-render (`mapping`, `env-gate`, `tenant`) give Crossplane up to three minutes; a slow cluster can fail them on time alone.

Each policy template is described on the [`XPolicy` API page](../../docs/api-reference/auth/policy.md); the tenant kinds on
[`XApp`](../../docs/api-reference/tenant/app.md) and [`XDatabase`](../../docs/api-reference/tenant/database.md).
