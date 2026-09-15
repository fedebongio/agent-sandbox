#!/usr/bin/env bash
# Copyright 2026 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Smoke test for the multi-persona warm pool example: runs the full README
# walkthrough non-interactively against the current kubectl context.
# Expects agent-sandbox (with extensions) already installed.
#
# Every verdict below is COMPUTED from cluster state — principally the
# agents.x-k8s.io/launch-type label, which the controller itself sets to
# "warm" or "cold". Nothing is asserted against a hardcoded banner, and the
# cold-start check is guarded so it cannot pass vacuously: an empty pool would
# make "everything cold-started" trivially true, so spare availability is
# established first.
set -euo pipefail
cd "$(dirname "$0")"

NS=multi-persona-demo
OBSERVER_CLAIMS="agent-sre agent-security agent-finops"
ALL_CLAIMS="$OBSERVER_CLAIMS agent-incident"
PERSONA_LABEL='sandbox.users.io/persona'

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
cleanup() {
  kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete clusterrole multi-persona-observer multi-persona-remediator \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete clusterrolebinding multi-persona-observer multi-persona-remediator \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The persona each claim asks for, kept next to the claim manifests it mirrors.
persona_for() {
  case "$1" in
    agent-sre) echo sre-observer ;;
    agent-security) echo security-auditor ;;
    agent-finops) echo finops-optimizer ;;
    agent-incident) echo incident-responder ;;
    *) fail "no expected persona recorded for claim '$1'" ;;
  esac
}

# launch_type <sandbox> -> "warm" | "cold" | "" — set by the controller, not us.
launch_type() {
  kubectl -n "$NS" get sandbox "$1" \
    -o jsonpath='{.metadata.labels.agents\.x-k8s\.io/launch-type}' 2>/dev/null || true
}

# bound_sandbox <claim> -> sandbox name, empty if unbound
bound_sandbox() {
  kubectl -n "$NS" get sandboxclaim "$1" -o jsonpath='{.status.sandbox.name}' 2>/dev/null || true
}

# ready_sandboxes -> sorted names of every Ready sandbox in the namespace.
# Note: kubectl's jsonpath cannot nest a filter inside a filter, so this
# projects name/status pairs and selects with awk rather than filtering on
# .status.conditions inline.
ready_sandboxes() {
  kubectl -n "$NS" get sandbox \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    2>/dev/null | awk -F'\t' '$2=="True"{print $1}' | sort || true
}

# active_persona <sandbox> -> the persona the agent has actually loaded.
# Reads the frontmatter of the file the activator copied into place, which
# exercises the whole chain: claim label -> pod metadata patch -> downward API
# refresh -> agent-side reload.
active_persona() {
  kubectl -n "$NS" exec "$1" -c agent -- \
    sh -c 'sed -n "s/^name: //p" /opt/active/persona.md 2>/dev/null | head -1' 2>/dev/null || true
}

# await_persona <sandbox> <expected> — poll until the agent reports it, or give up.
await_persona() {
  _got=""
  for _ in $(seq 1 40); do
    _got=$(active_persona "$1")
    [ "$_got" = "$2" ] && break
    sleep 3
  done
  echo "$_got"
}

restart_count() {
  kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true
}

echo "=== 0. preflight"
kubectl get crd sandboxwarmpools.extensions.agents.x-k8s.io >/dev/null 2>&1 \
  || fail "extension CRDs missing — apply a sandbox-with-extensions.yaml release, or 'EXTENSIONS=true make deploy-kind' locally"
pass "extension CRDs present (context: $(kubectl config current-context))"

echo "=== 1. prereqs, persona catalogue, templates, warm pools"
kubectl apply -f 00-prereqs.yaml
# The catalogue and the activator are plain ConfigMaps built from the files in
# this directory. Every pod mounts the FULL catalogue; the claim's label picks
# which entry becomes active, which is what keeps the spares fungible.
kubectl -n "$NS" create configmap persona-catalog \
  --from-file=personas/ --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create configmap persona-activator \
  --from-file=scripts/activate-persona.sh --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f 10-sandboxtemplate-observer.yaml \
  -f 11-sandboxtemplate-remediator.yaml \
  -f 20-warmpools.yaml

READY=0
for _ in $(seq 1 60); do
  READY=$(ready_sandboxes | grep -c . || true)
  [ "$READY" -ge 4 ] && break
  sleep 5
done
[ "$READY" -ge 4 ] || fail "warm pools did not reach 4 Ready spares (3 observer + 1 remediator); got $READY"
pass "warm pools: $READY spares Ready before any claim exists"

echo "=== 2. snapshot the pre-claim spares"
# Recording the spares BEFORE any claim exists is what makes "adopted, not
# created" provable: an adopted sandbox must already appear in this set.
SPARES_BEFORE=$(ready_sandboxes)
echo "$SPARES_BEFORE" | sed 's/^/    /'

echo "=== 3. four personas claim across two pools"
kubectl apply -f 30-claims-observer.yaml -f 31-claim-remediator.yaml
for c in $ALL_CLAIMS; do
  kubectl -n "$NS" wait sandboxclaim "$c" --for=condition=Ready --timeout=120s >/dev/null \
    || fail "claim $c never became Ready"
done
pass "all four claims Ready"

echo "=== 4. VERDICT: every claim adopted a pre-existing WARM spare"
for c in $ALL_CLAIMS; do
  SB=$(bound_sandbox "$c")
  [ -n "$SB" ] || fail "$c bound no sandbox"
  LT=$(launch_type "$SB")
  [ "$LT" = "warm" ] || fail "$c -> $SB has launch-type='${LT:-<unset>}', expected warm"
  # Cross-check the controller's own label against our snapshot, so a
  # mislabelled cold start cannot slip through.
  echo "$SPARES_BEFORE" | grep -qx "$SB" \
    || fail "$c -> $SB is labelled warm but was NOT a pre-existing spare"
  echo "    $c -> $SB (launch-type=$LT)"
done
pass "4/4 claims adopted pre-existing spares, launch-type=warm"

echo "=== 5. VERDICT: three personas share ONE pool without colliding"
OBS_SANDBOXES=""
for c in $OBSERVER_CLAIMS; do
  OBS_SANDBOXES="$OBS_SANDBOXES$(bound_sandbox "$c")
"
done
DISTINCT=$(echo "$OBS_SANDBOXES" | grep . | sort -u | wc -l | tr -d ' ')
[ "$DISTINCT" -eq 3 ] || fail "expected 3 distinct observer sandboxes, got $DISTINCT"
# Same ServiceAccount on all three proves they really are fungible spares from
# the same pool, rather than one bespoke pool per persona.
for c in $OBSERVER_CLAIMS; do
  SA=$(kubectl -n "$NS" get pod "$(bound_sandbox "$c")" -o jsonpath='{.spec.serviceAccountName}')
  [ "$SA" = "agent-observer" ] || fail "$c ran as '$SA', expected agent-observer"
done
pass "3 distinct spares, 1 pool, 1 identity — heterogeneous personas, homogeneous pool"

echo "=== 6. VERDICT: the persona is live INSIDE the container, with no restart"
for c in $ALL_CLAIMS; do
  SB=$(bound_sandbox "$c")
  WANT=$(persona_for "$c")

  GOT=$(await_persona "$SB" "$WANT")
  [ "$GOT" = "$WANT" ] || fail "$SB loaded persona '${GOT:-<none>}', expected '$WANT'"

  RESTARTS=$(restart_count "$SB")
  [ "$RESTARTS" = "0" ] || fail "$SB restarted ${RESTARTS}x — the warm pod was not preserved"

  # The pod must PREDATE its claim. Both stamps are RFC3339 UTC, so a
  # lexicographic comparison is also a chronological one.
  POD_START=$(kubectl -n "$NS" get pod "$SB" -o jsonpath='{.status.startTime}')
  CLAIM_MADE=$(kubectl -n "$NS" get sandboxclaim "$c" -o jsonpath='{.metadata.creationTimestamp}')
  [[ "$POD_START" < "$CLAIM_MADE" ]] \
    || fail "$SB started at $POD_START, not before claim $c at $CLAIM_MADE — that is a cold start"

  echo "    $SB: persona=$GOT restarts=$RESTARTS pod=$POD_START < claim=$CLAIM_MADE"
done
pass "4/4 pods predate their claims, carry the right persona, and never restarted"

echo "=== 7. VERDICT: a persona can be REASSIGNED live on a claimed sandbox"
SB_SRE=$(bound_sandbox agent-sre)
kubectl -n "$NS" patch sandboxclaim agent-sre --type merge \
  -p "{\"spec\":{\"additionalPodMetadata\":{\"labels\":{\"$PERSONA_LABEL\":\"finops-optimizer\"}}}}" >/dev/null
SWITCHED=$(await_persona "$SB_SRE" finops-optimizer)
[ "$SWITCHED" = "finops-optimizer" ] \
  || fail "$SB_SRE reports '${SWITCHED:-<none>}' after the patch, expected finops-optimizer"
RESTARTS=$(restart_count "$SB_SRE")
[ "$RESTARTS" = "0" ] || fail "$SB_SRE restarted ${RESTARTS}x during reassignment"
pass "re-targeted a running sandbox sre-observer -> finops-optimizer, restarts still 0"

echo "=== 8. VERDICT: the spec.env anti-pattern silently forfeits the pool"
kubectl apply -f 40-antipattern-env.yaml

# Guard against a vacuous pass: if this pool had no spares, a cold start would
# be the only possible outcome and would prove nothing.
#
# Count only THIS pool's spares. Warm spares are named "<pool>-<suffix>",
# whereas a cold-started sandbox takes its claim's name — so the prefix
# distinguishes them. Counting every newly-Ready sandbox instead would sweep
# in the replacements the other two pools create to refill themselves after
# their spares were adopted in step 3.
AP_SPARES=0
for _ in $(seq 1 60); do
  AP_SPARES=$(ready_sandboxes | grep -c '^antipattern-pool-' || true)
  [ "$AP_SPARES" -ge 2 ] && break
  sleep 5
done
[ "$AP_SPARES" -ge 2 ] \
  || fail "anti-pattern pool offered only $AP_SPARES spare(s); the cold-start check would be vacuous"
pass "anti-pattern pool has $AP_SPARES warm spares available to be wasted"

kubectl -n "$NS" wait sandboxclaim agent-env-antipattern --for=condition=Ready --timeout=180s >/dev/null \
  || fail "the env-carrying claim never became Ready (it is expected to SUCCEED, coldly)"
SB_AP=$(bound_sandbox agent-env-antipattern)
[ -n "$SB_AP" ] || fail "agent-env-antipattern bound no sandbox"


LT_AP=$(launch_type "$SB_AP")
[ "$LT_AP" = "cold" ] || fail "env claim -> $SB_AP has launch-type='${LT_AP:-<unset>}', expected cold"
if echo "$SPARES_BEFORE" | grep -qx "$SB_AP"; then
  fail "$SB_AP was a pre-existing spare, contradicting launch-type=cold"
fi
pass "env-carrying claim went Ready with NO error and launch-type=cold — pool bypassed silently"

echo
echo "All verdicts passed:"
printf '  %-30s %s\n' \
  "3 personas, 1 shared pool" "warm adoption onto 3 distinct spares" \
  "persona inside the container" "via downward API, 0 restarts" \
  "live reassignment" "sre-observer -> finops-optimizer, 0 restarts" \
  "separate trust boundary" "incident-responder from remediator-pool" \
  "spec.env anti-pattern" "silently cold-started (launch-type=cold)"
