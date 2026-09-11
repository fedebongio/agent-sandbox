---
name: finops-resource-waste
description: "Detect unrequested CPU/memory allocations, over-provisioned workloads, and idle cloud resource waste."
version: 1.0.0
category: finops
author: "Antigravity Fleet FinOps"
---

# Skill: FinOps Resource Waste Detection

Use this procedure to audit resource efficiency and identify cost-saving opportunities.

## Step 1: Check for Missing Resource Requests and Limits
Query all running pods:
```bash
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
APISERVER=https://kubernetes.default.svc

curl -s --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/pods" > /tmp/pods.json
```

Filter for containers where:
- `resources.requests.cpu` is missing
- `resources.requests.memory` is missing
- `resources.limits` are unbounded or excessively high compared to requests (e.g. limit > 10x request)

## Step 2: Query Node Allocatable vs Workload Requests
Fetch node capacities:
```bash
curl -s --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/nodes" > /tmp/nodes.json
```
Calculate aggregate requested CPU and memory per node vs `allocatable`. Flag nodes running below 20% requested capacity that could be consolidated by cluster autoscaler.

## Step 3: Check for Unbound or Abandoned PersistentVolumeClaims
Fetch PVCs:
```bash
curl -s --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/persistentvolumeclaims" > /tmp/pvcs.json
```
Identify PVCs not referenced by any active pod volume mount.

## Step 4: Record Efficiency Report
Append to `/opt/data/learnings/observations.md`:
- Heading: `## [YYYY-MM-DDTHH:MM:SSZ] FinOps Efficiency Audit`
- Workloads missing request constraints
- Recommended Vertical Pod Autoscaler (VPA) snippet or revised resource requests
