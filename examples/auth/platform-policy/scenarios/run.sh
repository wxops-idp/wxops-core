#!/usr/bin/env bash
# Plays every XPlatformPolicy template (policies/) against the sandbox in sandbox.yaml and bindings.yaml as SCM users, and compares each row with what it expects.
# Usage: ./run.sh setup | test | compare | users | session <user> | session-end | teardown; SESSION=<user> ./run.sh test for one real login —
# see docs/api-reference/auth/platform-policy.md#trying-the-templates-on-a-cluster.
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
if [ -n "$SESSION" ]; then
  # The session user plays through the kubeconfig `./run.sh session <user>` logged in; everyone else's rows are skipped.
  declare -n PLAYER=${SESSION^^}
  PLAYER=(--kubeconfig="$SESSION_DIR/kubeconfig")
fi
USERS=(sbx-alice sbx-bob sbx-paula)
YOU=()                                           # your own kubeconfig, unchanged
PERSONA=(--as="${SCM_USER:-you}" --as-group="${SCM_GROUP:-wxops-idp:owners}") # compare: you as a member of your real platform persona

POLICIES=(sbx-owner-stamp sbx-owner-seal sbx-secret-readonly sbx-exec-guard sbx-protected sbx-rbac-guard sbx-sa-guard sbx-namespace-guard)
BINDINGS=(sbx-teams-owned sbx-teams-both sbx-platform-both)
PERSONAS=(sbx-teams sbx-devs sbx-platform)

pass=0
fail=0
skipped=0
last_skipped=false

# row <want> <who> <what> -- <command…>   want: allow | policy (refused by an XPlatformPolicy) | rbac (refused by RBAC first)
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
      kubectl wait --for=jsonpath='{.status.created}'=true --timeout=300s "xplatformpolicy/$p" >/dev/null &&
      kubectl wait --for=jsonpath='{.status.conditionStatus.ready}'=true --timeout=120s "$kind/wxops-$p" >/dev/null ||
      { echo "check: kubectl get xplatformpolicy $p; kubectl get $kind wxops-$p"; exit 1; }
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

  echo "secret-readonly — Secrets come from External Secrets Operator, never by hand"
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
  # The XRs first, so their bindings and policies go with them; then the namespaces.
  kubectl delete xplatformpolicy "${POLICIES[@]}" --ignore-not-found
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
  compare) compare ;;
  teardown) teardown ;;
  *) echo "usage: $0 setup | test | compare | users | session <user> | session-end | teardown"; exit 2 ;;
esac
