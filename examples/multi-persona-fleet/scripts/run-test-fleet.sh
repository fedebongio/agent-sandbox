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

echo "============================================================"
echo "🚀 Multi-Persona Fleet: Warm Pool End-to-End Cluster Test"
echo "============================================================"

# 1. Apply RBAC
echo -e "\n[1/5] Applying Least-Privilege Scoped RBAC..."
kubectl apply -f "${FLEET_DIR}/manifests/rbac/"

# 2. Apply ConfigMaps & Skills Catalog
echo -e "\n[2/5] Deploying Personas & Skills Catalog ConfigMaps..."
kubectl apply -f "${FLEET_DIR}/manifests/pattern-a-configmaps/configmaps-personas.yaml" \
              -f "${FLEET_DIR}/manifests/pattern-a-configmaps/configmaps-skills.yaml"

# 3. Deploy Generic Warm Pool
echo -e "\n[3/5] Launching Generic Warm Pool..."
kubectl apply -f "${FLEET_DIR}/manifests/warm-pool/sandbox-generic-warm-pool.yaml"

# 4. Wait for Warm Sandbox to be Ready
echo -e "\n[4/5] Waiting for warm sandbox 'agent-sandbox-warm-1' to report Ready..."
kubectl wait --for=condition=Ready sandbox/agent-sandbox-warm-1 --timeout=180s || {
    echo "⚠️ Timed out waiting for sandbox. Current status:"
    kubectl get sandbox agent-sandbox-warm-1 -o yaml || true
}

# 5. Run Fleet Dispatcher to claim, inject, and execute
echo -e "\n[5/5] Listing fleet warm pools..."
python3 "${SCRIPT_DIR}/fleet_dispatcher.py" --list

echo -e "\nDispatching SRE Observer task to warm pool..."
python3 "${SCRIPT_DIR}/fleet_dispatcher.py" --persona sre-observer --pool generic-warm-pool

echo -e "\nDispatching Security Auditor task to warm pool..."
python3 "${SCRIPT_DIR}/fleet_dispatcher.py" --persona security-auditor --pool generic-warm-pool

if [[ "${CLEANUP}" == "--cleanup" ]]; then
    echo -e "\n🧹 Cleaning up test warm pool resources..."
    kubectl delete -f "${FLEET_DIR}/manifests/warm-pool/sandbox-generic-warm-pool.yaml" --ignore-not-found
    echo "Cleaned up."
fi

echo -e "\n============================================================"
echo "✅ End-to-end warm pool lifecycle test completed successfully!"
echo "============================================================"
