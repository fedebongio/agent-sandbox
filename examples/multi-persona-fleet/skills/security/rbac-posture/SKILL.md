---
name: security-rbac-posture
description: "Audit RBAC permissions, cluster-admin bindings, wildcard authorizations, and privileged pod security contexts."
version: 1.0.0
category: security
author: "Antigravity Fleet Security"
---

# Skill: Security RBAC and Workload Posture Audit

Use this procedure to identify security misconfigurations and privilege escalations.

## Step 1: Scan for ClusterRoleBindings with Wildcard or Cluster-Admin Permissions
Query all ClusterRoleBindings:
```bash
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
APISERVER=https://kubernetes.default.svc

curl -s --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/apis/rbac.authorization.k8s.io/v1/clusterrolebindings" > /tmp/crb.json
```

Evaluate:
- Bindings referencing `cluster-admin` where subjects include `default` service accounts or non-system groups.
- ClusterRoles with verbs `["*"]` and resources `["*"]` granted broadly.

## Step 2: Workload SecurityContext Verification
Query Pod specs across namespaces:
```bash
curl -s --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/pods" > /tmp/pods.json
```

Check each container spec for:
- `securityContext.privileged == true`
- `securityContext.allowPrivilegeEscalation == true`
- `securityContext.runAsNonRoot == false` or `runAsUser == 0`
- Pod-level `hostPID: true`, `hostNetwork: true`, `hostIPC: true`

## Step 3: Network Policy Coverage Check
Check namespaces that have running workloads but lack any NetworkPolicies:
```bash
curl -s --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/apis/networking.k8s.io/v1/networkpolicies" > /tmp/netpols.json
```

## Step 4: Record Findings & Remediation Advice
Append to `/opt/data/learnings/observations.md`:
- Heading: `## [YYYY-MM-DDTHH:MM:SSZ] Security Posture Audit`
- Findings categorized by Severity (CRITICAL, HIGH, MEDIUM, LOW)
- Exact Kyverno/Gatekeeper constraint or Pod spec remediation patch
