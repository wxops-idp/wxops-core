#!/usr/bin/env bash
# The sandbox kit: plays W'xOps against a sandbox (sandbox.yaml, bindings.yaml, policies/) as SCM users — every XPolicy template, owner mapping, env-gate, the tenant kinds —
# and compares each row with what it expects.
# Usage: ./run.sh setup | test | mapping | env-gate | tenant | compare | users | session <user> | session-end | teardown; SESSION=<user> ./run.sh test for one real login —
# see README.md beside it.
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
A=wxops-sbx-a
B=wxops-sbx-b
SESSION=${SESSION:-}                                         # empty: impersonate everyone; alice | bob | paula: that user's own login only
SESSION_DIR=${XDG_RUNTIME_DIR:-/tmp}/wxops-sbx-session       # one login at a time, outside the repository
declare -A GROUP=([alice]=wxops-sbx:team-a [bob]=wxops-sbx:team-b [paula]=wxops-sbx:platform)
ALICE=(--as=alice --as-group=wxops-sbx:team-a)  # team-a: wxops:persona-owners in A and B, in sbx-devs
BOB=(--as=bob --as-group=wxops-sbx:team-b)      # team-b: wxops:persona-owners in A and B, and Namespaces cluster-wide (namespace-editor.yaml)
PAULA=(--as=paula --as-group=wxops-sbx:platform) # sbx-platform: wxops:persona-platform (admin) in A and B, exempt where a policy names it
CAROL=(--as=carol --as-group=wxops-sbx:team-a-ops) # mapping only: team-a-ops, mapped to owner team-a (mapping.yaml)
DAN=(--as=dan --as-group=wxops-sbx:team-b)         # env-gate only: team-b like bob, but not in the persona trusted with prod (env-gate.yaml)
if [ -n "$SESSION" ]; then
  # The session user plays through the kubeconfig `./run.sh session <user>` logged in; everyone else's rows are skipped.
  declare -n PLAYER=${SESSION^^}
  PLAYER=(--kubeconfig="$SESSION_DIR/kubeconfig")
fi
USERS=(sbx-alice sbx-bob sbx-paula)
YOU=()                                           # your own kubeconfig, unchanged
PERSONA=(--as="${SCM_USER:-you}" --as-group="${SCM_GROUP:-wxops-idp:owners}") # compare: you as a member of your real platform persona

POLICIES=(sbx-owner-stamp sbx-owner-seal sbx-secret-guard sbx-exec-guard sbx-protected sbx-rbac-guard sbx-sa-guard sbx-namespace-guard)
BINDINGS=(sbx-teams-owned sbx-teams-both sbx-platform-both)
PERSONAS=(sbx-teams sbx-devs sbx-platform)

pass=0
fail=0
skipped=0
last_skipped=false

# row <want> <who> <what> -- <command…>   want: allow | policy (refused by an XPolicy) | rbac (refused by RBAC first)
# In a session only the session user's rows run, and a "-" check runs only if the row it checks did.
row() {
  local want=$1 who=$2 what=$3 out got
  shift 4
  if [ -n "$SESSION" ]; then
    if { [ "$who" = - ] && $last_skipped; } || { [ "$who" != - ] && [ "$who" != "$SESSION" ]; }; then
      skipped=$((skipped + 1)); last_skipped=true; return
    fi
    last_skipped=false
  fi
  out=$("$@" 2>&1)
  if [ $? -eq 0 ]; then got=allow
  # A policy refusal is an admission denial carrying the "auth.wxops.cloud: " message prefix; an RBAC refusal names the API group too
  # ("xpersonas.auth.wxops.cloud is forbidden"), so the prefix alone is not enough.
  elif grep -q "denied the request" <<<"$out" && grep -q "auth.wxops.cloud: " <<<"$out"; then got=policy
  elif grep -qi "is forbidden" <<<"$out"; then got=rbac
  else got=error
  fi
  if [ "$want" = "$got" ]; then
    pass=$((pass + 1)); printf "  PASS  %-6s %-6s %s\n" "$who" "$got" "$what"
  else
    fail=$((fail + 1)); printf "  FAIL  %-6s %-6s %s (want %s)\n        %s\n" "$who" "$got" "$what" "$want" "$(head -1 <<<"$out")"
  fi
}

# cannot <can-i args…> — succeeds when RBAC says no; what the persona roles must not grant
cannot() {
  ! kubectl auth can-i "$@" >/dev/null 2>&1
}

# deploy_as <namespace> <name> <serviceaccount> [identity…] — creates an nginx Deployment that runs as that ServiceAccount
deploy_as() {
  local ns=$1 name=$2 sa=$3
  shift 3
  kubectl -n "$ns" create deployment "$name" --image=nginx:1.27-alpine --dry-run=client -o yaml |
    kubectl set serviceaccount --local -f - "$sa" -o yaml | kubectl -n "$ns" create -f - "$@"
}

# owner_is <namespace> <configmap> <team>
owner_is() {
  [ "$(kubectl -n "$1" get configmap "$2" -o jsonpath='{.metadata.labels.wxops\.cloud/owner}')" = "$3" ]
}

# forward <namespace> [identity…] — port-forwards svc/web and fetches nginx's page through it; on failure prints what kubectl answered, for row()
forward() {
  local ns=$1 port log pid ok=1
  shift
  port=$((20000 + RANDOM % 10000))
  log=$(mktemp)
  kubectl -n "$ns" port-forward svc/web "$port:80" "$@" >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 20); do
    if curl -fsS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ok=0; break; fi
    kill -0 $pid 2>/dev/null || break
    sleep 0.5
  done
  kill $pid 2>/dev/null
  wait $pid 2>/dev/null
  [ $ok -eq 0 ] || cat "$log"
  rm -f "$log"
  return $ok
}

# within <seconds> <command…> — retries until the command succeeds; Crossplane re-renders on its poll, not on the change
within() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@" >/dev/null 2>&1; do
    [ $SECONDS -ge $deadline ] && return 1
    sleep 3
  done
}

# owner-seal's `teams` variable mentions the mapped group — i.e. the policy has re-rendered with the mapping
seal_maps() {
  kubectl get validatingpolicy wxops-sbx-owner-seal -o jsonpath='{.spec.variables[?(@.name=="teams")].expression}' | grep -q "wxops-sbx:team-a-ops"
}

# nudge <policy> — Crossplane re-renders an XR on its poll; an annotation change makes it now
nudge() {
  kubectl annotate xpolicy "sbx-$1" wxops.test/nudge="$(date +%s)" --overwrite >/dev/null
}

ready() {
  kubectl wait --for=jsonpath='{.status.ready}'=true --timeout=300s "$@" >/dev/null
}

setup() {
  # In stages, each waiting for the last, so every XR renders once with what it reads already there — applied together, bindings and policies
  # render first against missing personas and re-render as they resolve.
  local p kind
  echo "namespaces and personas…"
  kubectl apply -f "$DIR/sandbox.yaml" >/dev/null && ready "${PERSONAS[@]/#/xpersona/}" || { echo "check: kubectl get xpersona"; exit 1; }
  echo "bindings…"
  kubectl apply -f "$DIR/bindings.yaml" >/dev/null && ready "${BINDINGS[@]/#/xpersonabinding/}" || { echo "check: kubectl get xpersonabinding"; exit 1; }
  # Policies one at a time. Each waits for Kyverno to report its policy ready, not for the XR — provider-kubernetes v1.2.1 can leave a policy's
  # Object at Ready=False (Creating) while the policy is applied and enforced.
  for p in "${POLICIES[@]}"; do
    echo "policy ${p#sbx-}…"
    kind=validatingpolicy
    [ "$p" = sbx-owner-stamp ] && kind=mutatingpolicy
    kubectl apply -f "$DIR/policies/${p#sbx-}.yaml" >/dev/null &&
      kubectl wait --for=jsonpath='{.status.created}'=true --timeout=300s "xpolicy/$p" >/dev/null &&
      kubectl wait --for=jsonpath='{.status.conditionStatus.ready}'=true --timeout=120s "$kind/wxops-$p" >/dev/null ||
      { echo "check: kubectl get xpolicy $p; kubectl get $kind wxops-$p"; exit 1; }
  done
  # Fixtures, created as you — owner-stamp labels each with its namespace's owner.
  for ns in $A $B; do
    kubectl -n $ns apply -f "$DIR/workload.yaml" >/dev/null
  done
  kubectl -n $B create configmap seal-b --from-literal=k=v --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n $A create configmap guarded --from-literal=k=v --dry-run=client -o yaml |
    kubectl label --local -f - wxops.cloud/protected=true -o yaml | kubectl apply -f - >/dev/null
  kubectl -n $A create secret generic sbx-secret --from-literal=k=v --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # ServiceAccounts for sa-guard: one team-a owns (stamped from the namespace), one labelled as another team's.
  kubectl -n $A create serviceaccount a-runner --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n $A create serviceaccount b-runner --dry-run=client -o yaml |
    kubectl label --local -f - wxops.cloud/owner=team-b -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f "$DIR/namespace-editor.yaml" >/dev/null
  kubectl -n $A rollout status deployment/web --timeout=180s >/dev/null
  kubectl -n $B rollout status deployment/web --timeout=180s >/dev/null
  echo "sandbox ready — ./run.sh test"
}

users() {
  kubectl apply -f "$DIR/users.yaml"
  ready "${USERS[@]/#/xoidcstaticpassword/}" || { echo "not ready — check: kubectl get xoidcstaticpassword"; exit 1; }
  echo "records pushed to OpenBao — Dex serves them once its config re-renders; then ./run.sh session alice"
}

# session <user> — a kubeconfig with its own Pinniped caches, logged in through the browser (no password grant). One user at a time.
session() {
  local u=${1:-}
  [ -n "$u" ] && [ -n "${GROUP[$u]:-}" ] || { echo "usage: $0 session alice | bob | paula"; exit 2; }
  session_end >/dev/null
  mkdir -p "$SESSION_DIR" && chmod 700 "$SESSION_DIR"
  pinniped get kubeconfig --oidc-session-cache="$SESSION_DIR/sessions.yaml" --credential-cache="$SESSION_DIR/credentials.yaml" \
    >"$SESSION_DIR/kubeconfig" || exit 1
  echo "log in as $u@sbx.wxops.local — password: bao kv get -mount=platform -field=password dex/users-def/sbx-$u"
  kubectl --kubeconfig="$SESSION_DIR/kubeconfig" auth whoami || exit 1
  echo "then: SESSION=$u ./run.sh test — and ./run.sh session-end before the next user"
}

session_end() {
  rm -rf "$SESSION_DIR"
  echo "session ended — its tokens are gone"
}

# The session kubeconfig must carry the session user's group, or every row would test someone else.
check_session() {
  [ -z "$SESSION" ] && return
  [ -n "${GROUP[$SESSION]:-}" ] || { echo "SESSION must be alice, bob or paula"; exit 2; }
  kubectl --kubeconfig="$SESSION_DIR/kubeconfig" auth whoami -o jsonpath='{.status.userInfo.groups}' 2>/dev/null | grep -q "\"${GROUP[$SESSION]}\"" ||
    { echo "the session is not logged in as $SESSION (${GROUP[$SESSION]}) — ./run.sh session $SESSION"; exit 1; }
}

reset() {
  # Objects the rows create, removed as you so a re-run starts clean.
  kubectl -n $A delete configmap stamp-a stamp-you seal-a --ignore-not-found >/dev/null
  kubectl -n $A delete secret sbx-alice sbx-paula sbx-you --ignore-not-found >/dev/null
  kubectl -n $A delete rolebinding sbx-rb-alice sbx-rb-paula sbx-rb-you --ignore-not-found >/dev/null
  kubectl -n $A delete deployment sbx-web sa-a sa-b-alice sa-b-paula sa-b-you --ignore-not-found >/dev/null
  kubectl delete namespace wxops-sbx-bob --ignore-not-found --wait=false >/dev/null
  kubectl label namespace $A wxops.cloud/owner=team-a auth.wxops.cloud/tenant-namespace=true --overwrite >/dev/null 2>&1
  kubectl label namespace $B wxops.cloud/owner=team-b auth.wxops.cloud/tenant-namespace=true note- --overwrite >/dev/null 2>&1
  kubectl -n $B label configmap seal-b wxops.cloud/owner=team-b --overwrite >/dev/null 2>&1
  kubectl -n $A label configmap guarded wxops.cloud/protected=true --overwrite >/dev/null 2>&1
}

test_rows() {
  check_session
  reset

  echo "owner-stamp — an object created without an owner takes its namespace's"
  row allow alice "creates a ConfigMap without an owner in A" -- kubectl -n $A create configmap stamp-a --from-literal=k=v "${ALICE[@]}"
  row allow -     "… and it is stamped wxops.cloud/owner=team-a" -- owner_is $A stamp-a team-a
  row allow you   "creates one too — the stamp applies to every caller" -- kubectl -n $A create configmap stamp-you --from-literal=k=v
  row allow -     "… and it is stamped team-a as well" -- owner_is $A stamp-you team-a

  echo "owner-seal — write only what your team owns"
  row allow  alice "creates in A, which team-a owns" -- kubectl -n $A create configmap seal-a --from-literal=k=v "${ALICE[@]}"
  row policy alice "updates team-b's object in B (its role there allows it)" -- kubectl -n $B label configmap seal-b note=alice --overwrite "${ALICE[@]}"
  row policy alice "relabels its own object to team-b" -- kubectl -n $A label configmap seal-a wxops.cloud/owner=team-b --overwrite "${ALICE[@]}"
  row policy alice "relabels team-b's object to team-a" -- kubectl -n $B label configmap seal-b wxops.cloud/owner=team-a --overwrite "${ALICE[@]}"
  row policy alice "deletes team-b's object" -- kubectl -n $B delete configmap seal-b "${ALICE[@]}"
  row allow  bob   "updates its own object in B" -- kubectl -n $B label configmap seal-b note=bob --overwrite "${BOB[@]}"
  row allow  paula "updates team-b's object — exempt persona" -- kubectl -n $B label configmap seal-b note=paula --overwrite "${PAULA[@]}"
  row allow  you   "updates team-b's object — not an SCM user" -- kubectl -n $B label configmap seal-b note=you --overwrite

  echo "persona roles — what a team's RBAC no longer grants (view + W'xOps write pieces, not edit/admin)"
  row allow  alice "cannot impersonate a ServiceAccount in A" -- cannot impersonate serviceaccounts -n $A "${ALICE[@]}"
  row allow  alice "cannot request a ServiceAccount token in A" -- cannot create serviceaccounts/token -n $A "${ALICE[@]}"
  row allow  alice "cannot create a ServiceAccount, a Pod or a RoleBinding in A" -- \
    sh -c "! kubectl auth can-i create serviceaccounts -n $A ${ALICE[*]} >/dev/null && ! kubectl auth can-i create pods -n $A ${ALICE[*]} >/dev/null && ! kubectl auth can-i create rolebindings -n $A ${ALICE[*]} >/dev/null"
  row allow  paula "can still impersonate a ServiceAccount — platform keeps admin" -- kubectl auth can-i impersonate serviceaccounts -n $A "${PAULA[@]}"

  echo "secret-guard — Secrets come from External Secrets Operator, never by hand"
  row rbac   alice "reads a Secret in A — view has none, so RBAC refuses" -- kubectl -n $A get secret sbx-secret "${ALICE[@]}"
  row rbac   alice "creates a Secret in A — no team role writes Secrets" -- kubectl -n $A create secret generic sbx-alice --from-literal=k=v "${ALICE[@]}"
  row policy paula "creates a Secret — admin may, this policy names no exemption" -- kubectl -n $A create secret generic sbx-paula --from-literal=k=v "${PAULA[@]}"
  row allow  you   "creates a Secret — not an SCM user" -- kubectl -n $A create secret generic sbx-you --from-literal=k=v

  echo "exec-guard — exec and port-forward only as a member of sbx-devs, only where your team owns"
  row allow  alice "execs into nginx in A" -- kubectl -n $A exec deploy/web "${ALICE[@]}" -- nginx -v
  row policy alice "execs into nginx in B, which team-b owns" -- kubectl -n $B exec deploy/web "${ALICE[@]}" -- nginx -v
  row policy bob   "execs into nginx in B — not in sbx-devs" -- kubectl -n $B exec deploy/web "${BOB[@]}" -- nginx -v
  row allow  paula "execs into nginx in B — exempt persona" -- kubectl -n $B exec deploy/web "${PAULA[@]}" -- nginx -v
  row allow  you   "execs into nginx in B — not an SCM user" -- kubectl -n $B exec deploy/web -- nginx -v
  row allow  alice "port-forwards to svc/web in A and fetches the page" -- forward $A "${ALICE[@]}"
  row policy alice "port-forwards to svc/web in B, which team-b owns" -- forward $B "${ALICE[@]}"
  row policy bob   "port-forwards to svc/web in B — not in sbx-devs" -- forward $B "${BOB[@]}"
  row allow  paula "port-forwards to svc/web in B — exempt persona" -- forward $B "${PAULA[@]}"
  row allow  you   "port-forwards to svc/web in B — not an SCM user" -- forward $B

  echo "protected — wxops.cloud/protected=true objects change only by the platform team"
  row policy alice "updates a protected object its own team owns" -- kubectl -n $A label configmap guarded note=alice --overwrite "${ALICE[@]}"
  row policy alice "deletes it" -- kubectl -n $A delete configmap guarded "${ALICE[@]}"
  row allow  paula "updates it — exempt persona" -- kubectl -n $A label configmap guarded note=paula --overwrite "${PAULA[@]}"
  row allow  you   "updates it — not an SCM user" -- kubectl -n $A label configmap guarded note=you --overwrite

  echo "rbac-guard — bindings come from XPersonaBinding, not by hand"
  row rbac   alice "creates a RoleBinding in A — no team role writes bindings" -- kubectl -n $A create rolebinding sbx-rb-alice --clusterrole=view --group=wxops-sbx:team-a "${ALICE[@]}"
  row allow  paula "creates a RoleBinding in A — exempt persona" -- kubectl -n $A create rolebinding sbx-rb-paula --clusterrole=view --group=wxops-sbx:team-a "${PAULA[@]}"
  row allow  you   "creates a RoleBinding in A — not an SCM user" -- kubectl -n $A create rolebinding sbx-rb-you --clusterrole=view --group=wxops-sbx:team-a
  row rbac   alice "creates an XPersona — RBAC refuses before any policy runs" -- kubectl create --dry-run=server -f - "${ALICE[@]}" <<<'{"apiVersion":"auth.wxops.cloud/v1alpha1","kind":"XPersona","metadata":{"name":"sbx-sneaky"},"spec":{"parameters":{"description":"x"}}}'

  echo "sa-guard — a workload runs only as default or a ServiceAccount its creator's team owns"
  row allow  alice "creates a Deployment in A as a-runner, team-a's" -- deploy_as $A sa-a a-runner "${ALICE[@]}"
  row policy alice "creates a Deployment in A as b-runner, team-b's" -- deploy_as $A sa-b-alice b-runner "${ALICE[@]}"
  row allow  paula "creates one as b-runner — exempt persona" -- deploy_as $A sa-b-paula b-runner "${PAULA[@]}"
  row allow  you   "creates one as b-runner — not an SCM user" -- deploy_as $A sa-b-you b-runner

  echo "namespace-guard — Namespaces and their owner and tenant labels are the platform team's"
  row policy bob   "relabels A's owner to team-b (RBAC lets team-b write Namespaces)" -- kubectl label namespace $A wxops.cloud/owner=team-b --overwrite "${BOB[@]}"
  row policy bob   "removes B's tenant-namespace label" -- kubectl label namespace $B auth.wxops.cloud/tenant-namespace- "${BOB[@]}"
  row allow  bob   "adds an unrelated label to B" -- kubectl label namespace $B note=bob --overwrite "${BOB[@]}"
  row policy bob   "creates a Namespace" -- kubectl create namespace wxops-sbx-bob "${BOB[@]}"
  row rbac   alice "creates a Namespace — no Namespace RBAC at all" -- kubectl create namespace wxops-sbx-alice "${ALICE[@]}"

  echo "not caught — controllers and Crossplane are never matched"
  row allow alice "creates a Deployment in A" -- kubectl -n $A create deployment sbx-web --image=nginx:1.27-alpine "${ALICE[@]}"
  row allow -     "… and the ReplicaSet controller creates its pod" -- kubectl -n $A rollout status deployment/sbx-web --timeout=120s
  row allow -     "provider-kubernetes keeps the bindings in sync" -- test "$(kubectl get xpersonabinding sbx-teams-owned -o jsonpath='{.status.synced}')" = true

  echo
  echo "$pass passed, $fail failed"
  [ -n "$SESSION" ] && echo "$skipped skipped — other users' rows and yours (impersonation mode runs them all)"
  [ $fail -eq 0 ]
}

# Owner mapping (ADR-006): a second team, team-a-ops, labelled wxops.cloud/owner: team-a, owns what team-a owns — in the persona, the binding and
# owner-seal alike. Impersonation only; needs `./run.sh setup` first. Removes what it creates.
mapping() {
  [ -n "$SESSION" ] && { echo "mapping runs in impersonation mode only — unset SESSION"; exit 2; }
  kubectl get xpolicy sbx-owner-seal >/dev/null 2>&1 || { echo "run ./run.sh setup first"; exit 1; }
  echo "a paused team, its persona and bindings…"
  kubectl apply -f "$DIR/mapping.yaml" >/dev/null || exit 1
  kubectl patch xscmteam sbx-team-a-ops --subresource=status --type=merge \
    -p '{"status":{"org":"wxops-sbx","dexTeam":"team-a-ops","oidcGroup":"wxops-sbx:team-a-ops"}}' >/dev/null || exit 1
  ready xpersona/sbx-mapped xpersona/sbx-carol xpersonabinding/sbx-mapped-owned xpersonabinding/sbx-carol-a || { echo "check: kubectl get xpersona,xpersonabinding"; exit 1; }
  nudge owner-seal

  echo "owner mapping — team-a-ops, labelled wxops.cloud/owner: team-a, owns what team-a owns"
  row allow - "the persona publishes it: status.owners maps wxops-sbx:team-a-ops to team-a" -- \
    within 120 sh -c "kubectl get xpersona sbx-mapped -o jsonpath='{.status.owners}' | grep -q '\"owner\":\"team-a\"'"
  row allow - "scope owned binds the group in A, which team-a owns" -- \
    within 120 sh -c "kubectl -n $A get rolebinding -l auth.wxops.cloud/binding=sbx-mapped-owned -o jsonpath='{.items[*].subjects[*].name}' | grep -q wxops-sbx:team-a-ops"
  row allow - "… and nowhere in B, which team-b owns" -- \
    test -z "$(kubectl -n $B get rolebinding -l auth.wxops.cloud/binding=sbx-mapped-owned -o name)"
  row allow - "owner-seal re-renders with the mapping in its teams variable" -- within 180 seal_maps
  row allow carol "creates a ConfigMap in A — owner team-a is one of her teams, through the mapping" -- \
    kubectl -n $A create configmap carol-a --from-literal=k=v "${CAROL[@]}"
  row rbac  carol "creates one in B — no binding there" -- kubectl -n $B create configmap carol-b --from-literal=k=v "${CAROL[@]}"

  echo "… and without it"
  kubectl label xscmteam sbx-team-a-ops wxops.cloud/owner- >/dev/null
  nudge owner-seal
  row allow - "owner-seal re-renders without the mapping" -- within 180 sh -c '! kubectl get validatingpolicy wxops-sbx-owner-seal -o jsonpath="{.spec.variables[?(@.name==\"teams\")].expression}" | grep -q wxops-sbx:team-a-ops'
  row policy carol "creates a ConfigMap in A — RBAC still allows it (sbx-carol-a); owner-seal refuses: team-a is not her team" -- \
    kubectl -n $A create configmap carol-c --from-literal=k=v "${CAROL[@]}"

  mapping_teardown
  echo
  echo "$pass passed, $fail failed"
  [ $fail -eq 0 ]
}

# env-gate: wxops-sbx-b labelled prod; of team-b, only bob (sbx-prod, environments [prod]) may change it by hand — and an XApp whose own environment is prod, in B or anywhere.
# Impersonation only; needs `./run.sh setup` first, and the `app` package with `make providers-rbac` for the XApp rows (skipped without them). Removes what it creates,
# and the label. The XApps are paused and every request but one is a server-side dry run, so nothing is ever composed.
env_gate() {
  [ -n "$SESSION" ] && { echo "env-gate runs in impersonation mode only — unset SESSION"; exit 2; }
  kubectl get xpersona sbx-platform >/dev/null 2>&1 || { echo "run ./run.sh setup first"; exit 1; }
  echo "B labelled prod, a persona trusted with it, and the gate…"
  kubectl label namespace $B wxops.cloud/environment=prod --overwrite >/dev/null || exit 1
  kubectl apply -f "$DIR/env-gate.yaml" >/dev/null || exit 1
  ready xpersona/sbx-prod || { echo "check: kubectl get xpersona sbx-prod"; exit 1; }
  kubectl wait --for=jsonpath='{.status.created}'=true --timeout=300s xpolicy/sbx-env-gate >/dev/null &&
    kubectl wait --for=jsonpath='{.status.conditionStatus.ready}'=true --timeout=120s validatingpolicy/wxops-sbx-env-gate >/dev/null ||
    { echo "check: kubectl get xpolicy sbx-env-gate; kubectl get validatingpolicy wxops-sbx-env-gate"; exit 1; }
  kubectl wait --for=jsonpath='{.status.conditionStatus.ready}'=true --timeout=120s validatingpolicy/wxops-sbx-env-gate-apps >/dev/null ||
    { echo "check: kubectl get xpolicy sbx-env-gate -o jsonpath='{.status.appPolicyName}'; kubectl get validatingpolicy wxops-sbx-env-gate-apps"; exit 1; }
  APPS=$(env_gate_apps_ready)

  echo "env-gate — in a prod namespace, only the persona trusted with prod changes it by hand"
  row policy dan   "creates a ConfigMap in B (prod) — team-b, but not in sbx-prod" -- kubectl -n $B create configmap dan-1 --from-literal=k=v "${DAN[@]}"
  row allow  bob   "creates one — in sbx-prod, whose environments include prod" -- kubectl -n $B create configmap bob-1 --from-literal=k=v "${BOB[@]}"
  row allow  paula "creates one — the platform persona is exempt" -- kubectl -n $B create configmap paula-1 --from-literal=k=v "${PAULA[@]}"
  row allow  you   "creates one — not an SCM user, like Argo CD and every controller" -- kubectl -n $B create configmap you-1 --from-literal=k=v
  row policy bob   "relabels B's environment to dev — namespace-guard keeps the label the platform team's" -- \
    kubectl label namespace $B wxops.cloud/environment=dev --overwrite "${BOB[@]}"

  echo "… out of scope, and a persona that no longer reaches prod"
  kubectl label namespace $B wxops.cloud/environment- >/dev/null
  row allow  dan   "creates one in B once it is no longer prod — the namespace's labels are read on every request" -- \
    within 30 kubectl -n $B create configmap dan-2 --from-literal=k=v "${DAN[@]}"
  if [ "$APPS" = yes ]; then
    echo "… an application's own environment — B is not labelled prod now, so only the XApp's own field can say it is guarded"
    env_gate_apps_files
    row policy dan   "creates an XApp with environment: prod in B — the application's own field is what is guarded" -- \
      kubectl -n $B create --dry-run=server -f "$APPFILES/prod.yaml" "${DAN[@]}"
    row allow  dan   "creates one with environment: dev" -- kubectl -n $B create --dry-run=server -f "$APPFILES/dev.yaml" "${DAN[@]}"
    row allow  dan   "creates one with no environment — nothing to guard" -- kubectl -n $B create --dry-run=server -f "$APPFILES/none.yaml" "${DAN[@]}"
    row allow  bob   "creates one with environment: prod — in sbx-prod, whose environments include prod" -- \
      kubectl -n $B create --dry-run=server -f "$APPFILES/prod.yaml" "${BOB[@]}"
    row allow  you   "creates the real one, paused — not an SCM user, like Argo CD and every controller" -- kubectl -n $B create -f "$APPFILES/prod.yaml"
    row policy dan   "changes it from prod to dev — the object before the change is checked too, so prod cannot be renamed to slip past" -- \
      kubectl -n $B patch xapp sbx-gate-app --dry-run=server --type=merge -p '{"spec":{"parameters":{"environment":"dev"}}}' "${DAN[@]}"
    row policy dan   "deletes it" -- kubectl -n $B delete xapp sbx-gate-app --dry-run=server "${DAN[@]}"
    row allow  bob   "changes it from prod to dev — he reaches prod" -- \
      kubectl -n $B patch xapp sbx-gate-app --dry-run=server --type=merge -p '{"spec":{"parameters":{"environment":"dev"}}}' "${BOB[@]}"
    if [ "$(kubectl auth can-i create xdatabases.tenant.wxops.cloud -n $B "${BOB[@]}" 2>/dev/null)" = yes ]; then
      row policy dan   "creates an XDatabase with environment: prod — the same gate guards databases" -- \
        kubectl create --dry-run=server -f - "${DAN[@]}" <<<"$(tenant_xr XDatabase sbx-gate-db $B paused '' '"environment":"prod"')"
      row allow  bob   "creates one — he reaches prod" -- \
        kubectl create --dry-run=server -f - "${BOB[@]}" <<<"$(tenant_xr XDatabase sbx-gate-db $B paused '' '"environment":"prod"')"
    else
      echo "note: the database package is not installed, or bob cannot write XDatabases — the XDatabase rows are skipped" >&2
    fi
  fi
  kubectl label namespace $B wxops.cloud/environment=prod --overwrite >/dev/null
  kubectl patch xpersona sbx-prod --type=merge -p '{"spec":{"parameters":{"environments":["staging"]}}}' >/dev/null
  nudge env-gate
  row allow  -     "env-gate re-renders: sbx-prod now reaches staging only" -- \
    within 180 sh -c "kubectl get validatingpolicy wxops-sbx-env-gate -o jsonpath='{.spec.validations[0].expression}' | grep -qF \"nsEnv in ['staging']\""
  row policy bob   "creates one in B — still in sbx-prod, but its environments no longer include prod" -- \
    kubectl -n $B create configmap bob-2 --from-literal=k=v "${BOB[@]}"
  if [ "$APPS" = yes ]; then
    row allow  -     "the application gate re-renders too: sbx-prod now reaches staging only" -- \
      within 180 sh -c "kubectl get validatingpolicy wxops-sbx-env-gate-apps -o jsonpath='{.spec.validations[0].expression}' | grep -qF \"e in ['staging']\""
    row policy bob   "creates an XApp with environment: prod — still in sbx-prod, but its environments no longer include prod" -- \
      kubectl -n $B create --dry-run=server -f "$APPFILES/prod.yaml" "${BOB[@]}"
  fi

  echo "… and a persona that does not exist"
  kubectl patch xpolicy sbx-env-gate --type=merge -p '{"spec":{"parameters":{"personaRef":{"name":"ghost"}}}}' >/dev/null
  row allow  -     "syncMessage says the gate allows nobody" -- \
    within 180 sh -c "kubectl get xpolicy sbx-env-gate -o jsonpath='{.status.syncMessage}' | grep -qF \"persona 'ghost' not found\""
  row allow  -     "… and the rendered gate names no member" -- \
    within 180 sh -c "kubectl get validatingpolicy wxops-sbx-env-gate -o jsonpath='{.spec.validations[0].expression}' | grep -qF 'g in []'"
  row policy bob   "creates one in B — a missing persona makes the gate stricter, never looser" -- \
    kubectl -n $B create configmap bob-3 --from-literal=k=v "${BOB[@]}"

  env_gate_teardown
  echo
  echo "$pass passed, $fail failed"
  [ $fail -eq 0 ]
}

# yes only if the XApp API is served and bob may write it in B (the persona pieces applied) — otherwise the XApp rows are skipped, with a note.
env_gate_apps_ready() {
  if ! kubectl get crd xapps.tenant.wxops.cloud >/dev/null 2>&1; then
    echo "note: the app package is not installed — the XApp rows are skipped" >&2; echo no; return
  fi
  if [ "$(kubectl auth can-i create xapps.tenant.wxops.cloud -n $B "${BOB[@]}" 2>/dev/null)" != yes ]; then
    echo "note: bob cannot write XApps in B — run make providers-rbac; the XApp rows are skipped" >&2; echo no; return
  fi
  echo yes
}

# Three paused XApps — prod, dev and no environment. Paused, so Crossplane never composes them: nothing is built in the sandbox.
env_gate_apps_files() {
  APPFILES=$(mktemp -d)
  local env
  for env in prod dev none; do
    {
      echo "apiVersion: tenant.wxops.cloud/v1alpha1"
      echo "kind: XApp"
      echo "metadata:"
      echo "  name: sbx-gate-app"
      echo "  namespace: $B"
      echo "  annotations: {crossplane.io/paused: \"true\"}"
      echo "spec:"
      echo "  parameters:"
      echo "    image: ghcr.io/example/sbx-gate-app:1"
      [ "$env" = none ] || echo "    environment: $env"
    } > "$APPFILES/$env.yaml"
  done
}

env_gate_teardown() {
  kubectl -n $B delete xapp sbx-gate-app --ignore-not-found >/dev/null 2>&1
  [ -n "${APPFILES:-}" ] && rm -rf "$APPFILES"
  kubectl delete xpolicy sbx-env-gate --ignore-not-found >/dev/null
  kubectl delete xpersona sbx-prod --ignore-not-found >/dev/null
  kubectl label namespace $B wxops.cloud/environment- >/dev/null 2>&1
  kubectl -n $B delete configmap bob-1 bob-2 bob-3 paula-1 you-1 dan-1 dan-2 --ignore-not-found >/dev/null 2>&1
}

# The tenant kinds (RFC-010 §3): XApp and XDatabase live in a team's namespace, and the namespace decides who owns them — RBAC keeps a team out of other
# namespaces, owner-stamp and owner-seal keep the owner label honest inside its own. Impersonation only; needs `./run.sh setup` first, and the `app` and
# `database` packages with `make providers-rbac`. Most rows are server-side dry runs against paused XRs; two XApps are composed for real — one in a namespace with
# no owner (it renders nothing) and one nginx in A (its Deployment shows what the composition writes). Removes what it creates.
C=wxops-sbx-c
ALICE_BOTH=(--as=alice --as-group=wxops-sbx:team-a --as-group=wxops-sbx:team-b) # tenant only: alice as a member of team-b too
tenant() {
  [ -n "$SESSION" ] && { echo "tenant runs in impersonation mode only — unset SESSION"; exit 2; }
  kubectl get xpolicy sbx-owner-seal sbx-owner-stamp >/dev/null 2>&1 || { echo "run ./run.sh setup first"; exit 1; }
  local k
  for k in xapps xdatabases; do
    kubectl get crd $k.tenant.wxops.cloud >/dev/null 2>&1 || { echo "$k.tenant.wxops.cloud is not served — make install-dev"; exit 1; }
    [ "$(kubectl auth can-i create $k.tenant.wxops.cloud -n $A "${ALICE[@]}" 2>/dev/null)" = yes ] ||
      { echo "alice cannot write $k in A — make providers-rbac"; exit 1; }
  done
  tenant_teardown
  echo "a namespace with no owner, and two XApps as you: team-b's in B, a protected one in A…"
  kubectl create namespace $C >/dev/null || exit 1
  kubectl create -f - >/dev/null <<<"$(tenant_xr XApp sbx-b-app $B paused)" || exit 1
  kubectl create -f - >/dev/null <<<"$(tenant_xr XApp sbx-guarded $A paused '{"wxops.cloud/protected":"true"}')" || exit 1

  echo "create — RBAC decides where, owner-stamp fills the owner, owner-seal checks it"
  row allow  alice "creates an XApp in A, which team-a owns" -- kubectl create --dry-run=server -f - "${ALICE[@]}" <<<"$(tenant_xr XApp sbx-app $A paused)"
  row allow  -     "… and owner-stamp labels it wxops.cloud/owner=team-a from the namespace" -- \
    stamped team-a "${ALICE[@]}" <<<"$(tenant_xr XApp sbx-app $A paused)"
  row policy alice "creates one in B — her role there allows it, but team-b is not her team" -- \
    kubectl create --dry-run=server -f - "${ALICE[@]}" <<<"$(tenant_xr XApp sbx-app $B paused)"
  row rbac   alice "creates one in C — no binding there, so RBAC refuses before any policy runs" -- \
    kubectl create --dry-run=server -f - "${ALICE[@]}" <<<"$(tenant_xr XApp sbx-app $C paused)"
  row allow  alice "creates one in A labelled team-b, as a member of team-b too — an explicit label is kept (ADR-006)" -- \
    stamped team-b "${ALICE_BOTH[@]}" <<<"$(tenant_xr XApp sbx-app $A paused '{"wxops.cloud/owner":"team-b"}')"
  row policy alice "creates one in A labelled team-b, as team-a only — the label must name one of her teams" -- \
    kubectl create --dry-run=server -f - "${ALICE[@]}" <<<"$(tenant_xr XApp sbx-app $A paused '{"wxops.cloud/owner":"team-b"}')"
  row allow  alice "creates an XDatabase in A" -- kubectl create --dry-run=server -f - "${ALICE[@]}" <<<"$(tenant_xr XDatabase sbx-db $A paused)"
  row allow  -     "… stamped team-a too" -- stamped team-a "${ALICE[@]}" <<<"$(tenant_xr XDatabase sbx-db $A paused)"
  row policy alice "creates one in B" -- kubectl create --dry-run=server -f - "${ALICE[@]}" <<<"$(tenant_xr XDatabase sbx-db $B paused)"
  row rbac   alice "creates one in C" -- kubectl create --dry-run=server -f - "${ALICE[@]}" <<<"$(tenant_xr XDatabase sbx-db $C paused)"

  echo "update and delete — only the owner's team, and a protected one only by the platform team"
  row policy alice "updates team-b's XApp in B" -- kubectl -n $B patch xapp sbx-b-app --dry-run=server --type=merge -p '{"spec":{"parameters":{"replicas":2}}}' "${ALICE[@]}"
  row policy alice "relabels it to team-a" -- kubectl -n $B label xapp sbx-b-app wxops.cloud/owner=team-a --overwrite --dry-run=server "${ALICE[@]}"
  row policy alice "deletes it" -- kubectl -n $B delete xapp sbx-b-app --dry-run=server "${ALICE[@]}"
  row allow  bob   "updates it — team-b's own" -- kubectl -n $B patch xapp sbx-b-app --dry-run=server --type=merge -p '{"spec":{"parameters":{"replicas":2}}}' "${BOB[@]}"
  row allow  bob   "deletes it" -- kubectl -n $B delete xapp sbx-b-app --dry-run=server "${BOB[@]}"
  row allow  you   "updates it — not an SCM user, like Argo CD: Git and its review govern that writer" -- \
    kubectl -n $B patch xapp sbx-b-app --dry-run=server --type=merge -p '{"spec":{"parameters":{"replicas":2}}}'
  row policy alice "updates a protected XApp her own team owns" -- \
    kubectl -n $A patch xapp sbx-guarded --dry-run=server --type=merge -p '{"spec":{"parameters":{"replicas":2}}}' "${ALICE[@]}"
  row allow  paula "updates it — exempt persona" -- \
    kubectl -n $A patch xapp sbx-guarded --dry-run=server --type=merge -p '{"spec":{"parameters":{"replicas":2}}}' "${PAULA[@]}"

  echo "composed for real — what the namespace decides, in what the composition writes"
  row allow  you   "creates an XApp in C, a namespace with no owner" -- kubectl create -f - <<<"$(tenant_xr XApp sbx-orphan $C)"
  row allow  -     "… it renders nothing and syncMessage says C is not a tenant namespace" -- \
    within 120 sh -c "kubectl -n $C get xapp sbx-orphan -o jsonpath='{.status.syncMessage}' | grep -q 'not a tenant namespace'"
  row allow  -     "… and composes nothing" -- test -z "$(kubectl -n $C get objects.kubernetes.m.crossplane.io,deployments -o name 2>/dev/null)"
  row allow  alice "creates an nginx XApp in A whose labels say wxops.cloud/owner: team-b" -- kubectl create -f - "${ALICE[@]}" <<<"$(tenant_xr XApp sbx-forge $A '' '' \
    '"image":"nginx:1.27-alpine","containerPort":80,"labels":{"wxops.cloud/owner":"team-b"},"probes":{"liveness":{"enabled":false},"readiness":{"enabled":false}}')"
  row allow  -     "… its Deployment carries the namespace's owner, team-a — a user's wxops.cloud/* label never reaches a resource" -- \
    within 180 deployment_owner_is $A sbx-forge team-a
  row allow  -     "… its pod template carries no owner, so a change of owner never rolls the pods" -- \
    test -z "$(kubectl -n $A get deployment sbx-forge -o jsonpath='{.spec.template.metadata.labels.wxops\.cloud/owner}')"
  row allow  -     "… and owner-stamp labels the pods team-a as the ReplicaSet controller creates them" -- within 120 pods_owned $A sbx-forge team-a
  row policy bob   "deletes it — his role in A allows it, but team-a is not his team" -- kubectl -n $A delete xapp sbx-forge --dry-run=server "${BOB[@]}"
  row allow  alice "deletes it — her own" -- kubectl -n $A delete xapp sbx-forge --wait=false "${ALICE[@]}"

  tenant_teardown
  echo
  echo "$pass passed, $fail failed"
  [ $fail -eq 0 ]
}

# tenant_xr <XApp|XDatabase> <name> <namespace> [paused] [labels-json] [parameters-json] — one tenant XR as JSON, on the nightly channel install-dev applies
tenant_xr() {
  local kind=$1 name=$2 ns=$3 paused=${4:-} labels='{}' params ann='{}'
  [ -n "${5:-}" ] && labels=$5
  [ "$paused" = paused ] && ann='{"crossplane.io/paused":"true"}'
  if [ -n "${6:-}" ]; then params=$6
  elif [ "$kind" = XApp ]; then params='"image":"ghcr.io/example/sbx-app:1"'
  else params='"environment":"dev"'
  fi
  printf '{"apiVersion":"tenant.wxops.cloud/v1alpha1","kind":"%s","metadata":{"name":"%s","namespace":"%s","labels":%s,"annotations":%s},' "$kind" "$name" "$ns" "$labels" "$ann"
  printf '"spec":{"crossplane":{"compositionRevisionSelector":{"matchLabels":{"channel":"nightly"}},"compositionUpdatePolicy":"Automatic"},"parameters":{%s}}}\n' "$params"
}

# stamped <owner> [identity…] — a server-side dry-run create of the XR on stdin comes back labelled with that owner (what owner-stamp left on it)
stamped() {
  local want=$1
  shift
  [ "$(kubectl create --dry-run=server -o jsonpath='{.metadata.labels.wxops\.cloud/owner}' -f - "$@")" = "$want" ]
}

# deployment_owner_is <namespace> <deployment> <owner>
deployment_owner_is() {
  [ "$(kubectl -n "$1" get deployment "$2" -o jsonpath='{.metadata.labels.wxops\.cloud/owner}' 2>/dev/null)" = "$3" ]
}

# pods_owned <namespace> <app> <owner> — the app has pods, and every one is labelled with that owner
pods_owned() {
  local owners
  owners=$(kubectl -n "$1" get pods -l app.kubernetes.io/name="$2",app.kubernetes.io/component=app -o jsonpath='{range .items[*]}{.metadata.labels.wxops\.cloud/owner}{"\n"}{end}')
  [ -n "$owners" ] && ! grep -qvx "$3" <<<"$owners"
}

tenant_teardown() {
  kubectl -n $A delete xapp sbx-forge sbx-guarded --ignore-not-found >/dev/null 2>&1
  kubectl -n $B delete xapp sbx-b-app --ignore-not-found >/dev/null 2>&1
  kubectl -n $C delete xapp sbx-orphan --ignore-not-found >/dev/null 2>&1
  kubectl delete namespace $C --ignore-not-found >/dev/null 2>&1
}

mapping_teardown() {
  kubectl delete xpersonabinding sbx-mapped-owned sbx-carol-a --ignore-not-found >/dev/null
  kubectl delete xpersona sbx-mapped sbx-carol --ignore-not-found >/dev/null
  # Deleted while still paused. It never composed anything, so if a finalizer holds it, clearing that orphans nothing.
  kubectl delete xscmteam sbx-team-a-ops --ignore-not-found --wait=false >/dev/null
  if ! within 30 sh -c '! kubectl get xscmteam sbx-team-a-ops'; then
    kubectl patch xscmteam sbx-team-a-ops --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
  fi
  kubectl -n $A delete configmap carol-a carol-c --ignore-not-found >/dev/null
}

# can <want-persona> <want-you> <what> -- <can-i args…>   read-only: kubectl auth can-i, nothing is written
can() {
  local wp=$1 wy=$2 what=$3 gp gy mark
  shift 4
  gp=$(kubectl auth can-i "$@" "${PERSONA[@]}" 2>/dev/null)
  gy=$(kubectl auth can-i "$@" 2>/dev/null)
  mark=PASS
  [ "$gp" = "$wp" ] && [ "$gy" = "$wy" ] || { mark=FAIL; fail=$((fail + 1)); }
  [ $mark = PASS ] && pass=$((pass + 1))
  printf "  %s  persona=%-3s you=%-3s %s\n" "$mark" "$gp" "$gy" "$what"
}

compare() {
  echo "your platform persona (${PERSONA[*]}) vs your own kubeconfig — RBAC only, read-only"
  can yes yes "read Secrets in wxops-platform" -- get secrets -n wxops-platform
  can yes yes "create Deployments in wxops-platform" -- create deployments -n wxops-platform
  can yes yes "create RoleBindings in wxops-platform (admin)" -- create rolebindings -n wxops-platform
  can no  yes "delete the wxops-platform namespace" -- delete namespaces/wxops-platform
  can no  yes "write in a namespace the binding does not list (wxops-sbx-a)" -- create configmaps -n wxops-sbx-a
  can yes yes "create an XPersona (wxops:platform-admin)" -- create xpersonas.auth.wxops.cloud
  can no  yes "create a ClusterRoleBinding" -- create clusterrolebindings
  can no  yes "list nodes" -- list nodes
  can no  yes "impersonate another user" -- impersonate users
  echo
  echo "$pass passed, $fail failed"
  [ $fail -eq 0 ]
}

teardown() {
  # The XRs first, so their bindings and policies go with them; then the namespaces. The mapping, env-gate and tenant scenarios', if interrupted.
  mapping_teardown
  env_gate_teardown
  tenant_teardown
  kubectl delete xpolicy "${POLICIES[@]}" --ignore-not-found
  kubectl delete xpersonabinding "${BINDINGS[@]}" --ignore-not-found
  kubectl delete xpersona "${PERSONAS[@]}" --ignore-not-found
  kubectl delete -f "$DIR/namespace-editor.yaml" --ignore-not-found
  kubectl delete namespace $A $B --ignore-not-found
  # The Dex users, if `users` ran: deleting each XR deletes its OpenBao record, and Dex drops it on its next re-render.
  kubectl delete xoidcstaticpassword "${USERS[@]}" --ignore-not-found
  session_end
}

case "${1:-test}" in
  setup) setup ;;
  users) users ;;
  session) session "${2:-}" ;;
  session-end) session_end ;;
  test) test_rows ;;
  mapping) mapping ;;
  env-gate) env_gate ;;
  tenant) tenant ;;
  compare) compare ;;
  teardown) teardown ;;
  *) echo "usage: $0 setup | test | mapping | env-gate | tenant | compare | users | session <user> | session-end | teardown"; exit 2 ;;
esac
