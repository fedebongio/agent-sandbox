#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== 1. Validating Personas, Skills, and Manifest Structure ==="
python3 "${SCRIPT_DIR}/validate_manifests.py"

echo -e "\n=== 2. Testing Kubernetes Manifests with kubectl dry-run ==="

echo "Testing RBAC manifests..."
kubectl apply --dry-run=client -f "${FLEET_DIR}/manifests/rbac/"

echo -e "\nTesting Pattern A (ConfigMaps & Projections)..."
kubectl apply --dry-run=client -f "${FLEET_DIR}/manifests/pattern-a-configmaps/"

echo -e "\nTesting Pattern B (High-Scale OCI Volumes & Copier)..."
kubectl apply --dry-run=client -f "${FLEET_DIR}/manifests/pattern-b-oci-volumes/"

echo -e "\nTesting OpenClaw manifests..."
kubectl apply --dry-run=client -f "${FLEET_DIR}/manifests/openclaw/"

echo -e "\nTesting Warm Pool & Concurrency manifests..."
kubectl apply --dry-run=client -f "${FLEET_DIR}/manifests/warm-pool/"

echo -e "\n=== 3. Testing Fleet Dispatcher & JIT Persona Injection ==="
python3 "${SCRIPT_DIR}/fleet_dispatcher.py" --persona sre-observer
python3 "${SCRIPT_DIR}/fleet_dispatcher.py" --persona security-auditor

echo -e "\n=============================================="
echo "✅ All dry-run deployments & simulations passed!"
echo "=============================================="
