#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
START_TIME=$(date +%s)

declare -a CHECK_NAMES=()
declare -a CHECK_TARGETS=()
declare -a CHECK_STATUSES=()

record_check() {
    CHECK_NAMES+=("$1")
    CHECK_TARGETS+=("$2")
    CHECK_STATUSES+=("$3")
}

echo "=== 1. Validating Personas, Skills, and Manifest Structure ==="
python3 "${SCRIPT_DIR}/validate_manifests.py"
record_check "Schema Validator" "Personas & Skills Frontmatter" "PASSED"

echo -e "\n=== 2. Testing Kubernetes Manifests with kubectl dry-run ==="

echo "Testing RBAC manifests..."
kubectl apply --dry-run=client -f "${FLEET_DIR}/manifests/rbac/"
record_check "RBAC Validation" "3 ServiceAccounts & ClusterRoles" "PASSED"

echo -e "\nTesting Pattern A (ConfigMaps & Projections)..."
kubectl apply --dry-run=client -f "${FLEET_DIR}/manifests/pattern-a-configmaps/"
record_check "Pattern A (ConfigMaps)" "Personas, Skills & Sandboxes" "PASSED"

echo -e "\nTesting Pattern B (High-Scale OCI Volumes & Copier)..."
kubectl apply --dry-run=client -f "${FLEET_DIR}/manifests/pattern-b-oci-volumes/"
record_check "Pattern B (OCI Volumes)" "ImageVolume & InitCopier Sandboxes" "PASSED"

echo -e "\nTesting OpenClaw manifests..."
kubectl apply --dry-run=client -f "${FLEET_DIR}/manifests/openclaw/"
record_check "OpenClaw Runtime" "openclaw.json & Sandbox CR" "PASSED"

echo -e "\nTesting Warm Pool & Concurrency manifests..."
kubectl apply --dry-run=client -f "${FLEET_DIR}/manifests/warm-pool/"
record_check "Warm Pool Architecture" "Generic & Partitioned Pools" "PASSED"

echo -e "\n=== 3. Testing Fleet Dispatcher & JIT Persona Injection ==="
python3 "${SCRIPT_DIR}/fleet_dispatcher.py" --persona sre-observer
record_check "JIT SRE Dispatch" "Claim, Injected Payload, Release" "PASSED"

python3 "${SCRIPT_DIR}/fleet_dispatcher.py" --persona security-auditor
record_check "JIT Security Dispatch" "Claim, Injected Payload, Release" "PASSED"

total_time=$(( $(date +%s) - START_TIME ))

echo -e "\n"
echo "================================================================================"
echo "                  DRY-RUN VALIDATION & TEST SUMMARY REPORT"
echo "================================================================================"
printf " %-24s %-38s %s\n" "VERIFICATION CHECK" "TARGET ARTIFACT" "STATUS"
echo "--------------------------------------------------------------------------------"
for i in "${!CHECK_NAMES[@]}"; do
    printf " %-24s %-38s \033[0;32m%-10s\033[0m\n" \
        "${CHECK_NAMES[$i]}" "${CHECK_TARGETS[$i]}" "${CHECK_STATUSES[$i]}"
done
echo "--------------------------------------------------------------------------------"
echo -e " OVERALL VERDICT : \033[0;32mALL 8 VERIFICATION CHECKS PASSED\033[0m"
echo " TOTAL DURATION  : ${total_time}s"
echo "================================================================================"
