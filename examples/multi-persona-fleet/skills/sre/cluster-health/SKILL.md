---
name: sre-cluster-health
description: "Inspect Kubernetes cluster health, identify unhealthy pods, crash loops, node pressure, and ingress errors."
version: 1.0.0
category: sre
author: "Antigravity Fleet SRE"
---

# Skill: SRE Cluster Health Inspection

Use this procedure during every observation cycle to assess cluster runtime health.

## Step 1: Query Pod Phase and Container States
Fetch pod statuses across all accessible namespaces:
```bash
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
APISERVER=https://kubernetes.default.svc

curl -s --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/pods" > /tmp/pods.json
```

Filter for:
- Pods where `status.phase != "Running"` and `status.phase != "Succeeded"`
- Containers with `restartCount > 0`
- Waiting state reasons: `CrashLoopBackOff`, `ImagePullBackOff`, `CreateContainerConfigError`, `OOMKilled`

## Step 2: Correlate with Events
Fetch cluster warning events within the last 1-2 hours:
```bash
curl -s --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/events?fieldSelector=type=Warning" > /tmp/events.json
```
Check if warning events match the impacted pods.

## Step 3: Check Ingress and Service Endpoints
Inspect Ingress resources for missing backends or load balancer sync warnings:
```bash
curl -s --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/apis/networking.k8s.io/v1/ingresses" > /tmp/ingresses.json
```

## Step 4: Record Observations and Hypotheses
Log findings in `/opt/data/learnings/observations.md` with:
- Timestamp: `## [YYYY-MM-DDTHH:MM:SSZ]`
- Status summary (Healthy / Degraded / Critical)
- Impacted workloads with namespace/pod name
- Causal hypothesis and recommended remediation
