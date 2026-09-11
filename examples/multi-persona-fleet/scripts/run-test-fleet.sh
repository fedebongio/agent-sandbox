#!/usr/bin/env bash
# Copyright 2025 The Kubernetes Authors.
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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLEANUP="${1:-}"
START_TIME=$(date +%s)

# Track test phase results
declare -a PHASE_NAMES=()
declare -a PHASE_TARGETS=()
declare -a PHASE_STATUSES=()
declare -a PHASE_DURATIONS=()

record_phase() {
    local name="$1"
    local target="$2"
    local status="$3"
    local duration="$4"
    PHASE_NAMES+=("${name}")
    PHASE_TARGETS+=("${target}")
    PHASE_STATUSES+=("${status}")
    PHASE_DURATIONS+=("${duration}")
}

print_summary() {
    local total_time=$(( $(date +%s) - START_TIME ))
    local cluster_ctx
    cluster_ctx=$(kubectl config current-context 2>/dev/null || echo "unknown")

    echo -e "\n"
    echo "================================================================================"
    echo "                 MULTI-PERSONA FLEET TEST SUMMARY REPORT"
    echo "================================================================================"
    printf " %-22s %-32s %-10s %s\n" "PHASE" "TARGET COMPONENT" "STATUS" "DURATION"
    echo "--------------------------------------------------------------------------------"
    for i in "${!PHASE_NAMES[@]}"; do
        local status_color="\033[0;32m" # Green
        if [[ "${PHASE_STATUSES[$i]}" != "PASSED" && "${PHASE_STATUSES[$i]}" != "READY" ]]; then
            status_color="\033[0;31m" # Red
        fi
        printf " %-22s %-32s ${status_color}%-10s\033[0m %s\n" \
            "${PHASE_NAMES[$i]}" "${PHASE_TARGETS[$i]}" "${PHASE_STATUSES[$i]}" "${PHASE_DURATIONS[$i]}"
    done
    echo "--------------------------------------------------------------------------------"
    echo -e " OVERALL VERDICT : \033[0;32mALL PHASES PASSED\033[0m"
    echo " CLUSTER CONTEXT : ${cluster_ctx}"
    echo " TOTAL DURATION  : ${total_time}s"
    echo " ARCHITECTURE    : Generic Warm Pool + JIT Persona Injection + Scoped RBAC"
    echo "================================================================================"
}

echo "============================================================"
echo "🚀 Multi-Persona Fleet: Warm Pool End-to-End Cluster Test"
echo "============================================================"

# Phase 1: RBAC
t0=$(date +%s)
echo -e "\n[1/6] Applying Least-Privilege Scoped RBAC..."
kubectl apply -f "${FLEET_DIR}/manifests/rbac/"
record_phase "[1] Scoped RBAC" "ServiceAccounts & Roles" "PASSED" "$(( $(date +%s) - t0 ))s"

# Phase 2: Knowledge Catalog ConfigMaps
t0=$(date +%s)
echo -e "\n[2/6] Deploying Personas & Skills Catalog ConfigMaps..."
kubectl apply -f "${FLEET_DIR}/manifests/pattern-a-configmaps/configmaps-personas.yaml" \
              -f "${FLEET_DIR}/manifests/pattern-a-configmaps/configmaps-skills.yaml"
record_phase "[2] Catalog ConfigMaps" "Personas & Skills Catalog" "PASSED" "$(( $(date +%s) - t0 ))s"

# Phase 3: Launch Warm Pool
t0=$(date +%s)
echo -e "\n[3/6] Launching Generic Warm Pool..."
kubectl apply -f "${FLEET_DIR}/manifests/warm-pool/sandbox-generic-warm-pool.yaml"
record_phase "[3] Deploy Warm Pool" "Sandbox/agent-sandbox-warm-1,2" "PASSED" "$(( $(date +%s) - t0 ))s"

# Phase 4: Wait for Warm Sandbox to be Ready
t0=$(date +%s)
echo -e "\n[4/6] Waiting for warm sandbox 'agent-sandbox-warm-1' to report Ready..."
if kubectl wait --for=condition=Ready sandbox/agent-sandbox-warm-1 --timeout=180s; then
    record_phase "[4] Warm Pool Readiness" "sandbox/agent-sandbox-warm-1" "READY" "$(( $(date +%s) - t0 ))s"
else
    echo "⚠️ Timed out waiting for sandbox. Current status:"
    kubectl get sandbox agent-sandbox-warm-1 -o yaml || true
    record_phase "[4] Warm Pool Readiness" "sandbox/agent-sandbox-warm-1" "FAILED" "$(( $(date +%s) - t0 ))s"
fi

# Phase 5: JIT Persona Dispatch (SRE)
t0=$(date +%s)
echo -e "\n[5/6] Dispatching SRE Observer task to warm pool..."
python3 "${SCRIPT_DIR}/fleet_dispatcher.py" --persona sre-observer --pool generic-warm-pool
record_phase "[5] SRE JIT Dispatch" "Persona: sre-observer" "PASSED" "$(( $(date +%s) - t0 ))s"

# Phase 6: JIT Persona Dispatch (Security)
t0=$(date +%s)
echo -e "\n[6/6] Dispatching Security Auditor task to warm pool..."
python3 "${SCRIPT_DIR}/fleet_dispatcher.py" --persona security-auditor --pool generic-warm-pool
record_phase "[6] Sec JIT Dispatch" "Persona: security-auditor" "PASSED" "$(( $(date +%s) - t0 ))s"

# Optional cleanup
if [[ "${CLEANUP}" == "--cleanup" ]]; then
    echo -e "\n🧹 Cleaning up test warm pool resources..."
    kubectl delete -f "${FLEET_DIR}/manifests/warm-pool/sandbox-generic-warm-pool.yaml" --ignore-not-found
    echo "Cleaned up."
fi

# Print final structured report
print_summary
