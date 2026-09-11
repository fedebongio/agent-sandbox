# Multi-Persona Fleet & Warm Pools for Hermes & OpenClaw on agent-sandbox

This example demonstrates how to run a **large fleet of concurrent agent sandboxes** using the Kubernetes [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) primitive (`agents.x-k8s.io/v1beta1`), maintaining **warm pools of sandboxes** and dynamically injecting **different personas and skills** across instances **without restarting pods or rebuilding container images**.

Rather than focusing on prompt engineering, this example exemplifies the **operational architecture** of running fleets of autonomous sandboxes in production:
* **Warm Pooling & Just-In-Time (JIT) Persona Injection**: Avoid cold-start pod creation latency by dynamically dispatching personas to running, pre-warmed sandboxes.
* **Massive Concurrency**: Managing dozens or hundreds of parallel sandbox instances efficiently.
* **Scalability at Fleet Scale**: Mitigating etcd bottlenecks by contrasting ConfigMaps against native OCI Image Volumes.
* **Lifecycle & Resource Efficiency**: Leveraging `operatingMode: Suspended` to pause standby sandboxes without deleting persistent state.
* **Runtime Parity**: Working configurations for both **Hermes Agent** and **OpenClaw**.

---

## 1. Warm Pool Architectures

Cold-starting an agent sandbox in Kubernetes requires pod scheduling, image pulling, runtime boot, and establishing LLM client connections (often 10–30+ seconds). Warm pooling eliminates this delay.

```
                  ┌──────────────────────────────────────────────┐
                  │          Fleet Dispatcher / Queue            │
                  │ (Task: "Run CVE audit" -> security-auditor)  │
                  └──────────────────────┬───────────────────────┘
                                         │ 1. Claim Idle Sandbox
                                         ▼
                 ┌─────────────────────────────────────────────────┐
                 │          Generic Warm Pool (Running)            │
                 │   [Sandbox-1 (busy)]    [Sandbox-2 (idle)]      │
                 └───────────────┬─────────────────────────────────┘
                                 │ 2. JIT Persona & Skill Injection
                                 │    (HTTP Gateway API: /v1/chat/completions)
                                 ▼
                     ┌───────────────────────────┐
                     │ Hermes / OpenClaw Gateway │
                     │   - System Prompt Injected│
                     │   - Tool Catalog Active   │
                     │   - ZERO Pod Restart      │
                     └───────────────────────────┘
```

### Topology A: Generic Warm Pool with JIT Injection (Recommended)
* **How it works**: A pool of generic `Sandbox` instances runs in `operatingMode: Running` with access to a shared catalog (mounted via an OCI volume or ConfigMap).
* **Dispatch**: When an incident or task arrives, the dispatcher:
  1. Finds an idle sandbox (`agent.x-k8s.io/status=idle`).
  2. Marks it `status=busy` with the active persona.
  3. Injects the persona system prompt and task instructions via the OpenAI-compatible Gateway API (`POST /v1/chat/completions` on port `:8642`).
  4. Releases the sandbox back to `idle` upon task completion.
* **Benefits**: Maximum resource efficiency; any warm sandbox can handle any persona instantly.
* **Manifest**: [`manifests/warm-pool/sandbox-generic-warm-pool.yaml`](manifests/warm-pool/sandbox-generic-warm-pool.yaml)
* **Reference Dispatcher**: [`scripts/fleet_dispatcher.py`](scripts/fleet_dispatcher.py)

### Topology B: Partitioned Pre-Warmed Pools
* **How it works**: Pre-warmed pools partitioned by persona type (`sre-warm-pool`, `security-warm-pool`, `finops-warm-pool`).
* **Benefits**: Ensures dedicated capacity per team or domain and pre-attaches strictly scoped RBAC ServiceAccounts.
* **Standby Mode**: Uses `operatingMode: Suspended` for off-peak cost savings, flipping to `Running` when batch demand spikes.
* **Manifest**: [`manifests/warm-pool/sandbox-partitioned-warm-pools.yaml`](manifests/warm-pool/sandbox-partitioned-warm-pools.yaml)

---

## 2. Injecting Personas & Skills: Beyond ConfigMaps

When running at fleet scale, how you deliver personas and skills directly impacts cluster stability:

| Dimension | **Pattern A: ConfigMaps & Volume Projections** | **Pattern B: High-Scale OCI Image Volumes** |
| :--- | :--- | :--- |
| **Fleet Scale** | 1 – 50 sandboxes (prototyping, small dev clusters) | 100 – 1,000+ sandboxes (enterprise fleet) |
| **Size Limit** | **1 MiB hard ceiling** in etcd | **Gigabyte-scale** (can bundle diagnostics, toolchains, datasets) |
| **etcd & API Load** | **High**: Each pod mount creates kubelet watches; updates cause watch storms | **Zero**: Kubelet resolves volumes via container registry; etcd is bypassed |
| **Node Caching** | Kubelet generates tmpfs per pod | **Node-cached**: containerd pulls the image layer once per node and shares it across pods |
| **Startup Latency** | Adds sync latency under high pod churn | **Sub-second** layer overlay |
| **Multi-Tenancy** | Must duplicate ConfigMaps across namespaces | Single OCI reference shared across all namespaces and clusters |

> [!WARNING]
> **Why ConfigMaps fail at fleet scale**:
> In large Kubernetes clusters, mounting ConfigMaps into hundreds of concurrent sandboxes can degrade the control plane. Large ConfigMaps increase etcd latency, and thousands of kubelet watches stress the API server. If skills change frequently or include rich procedural datasets, always use **Pattern B (OCI Image Volumes)**.

### The Production Pairing
In production warm pools, combine both mechanisms:
1. **OCI Image Volumes (`volumes[].image`)**: Deliver the **heavy, immutable skill catalog and CLI toolchains** into `/opt/skills-catalog`. The layers are pulled once per node and cached by containerd.
2. **Just-In-Time (JIT) Gateway API**: Injects the **lightweight persona system instructions and goal prompt** dynamically into the warm sandbox at request time.
3. **Clean Session Boundary**: When the HTTP completion finishes, the persona context terminates with the session, leaving the warm sandbox clean and ready for the next task.

---

## 3. Runtime Engine Parity: Hermes vs. OpenClaw

Both agent engines run as stock container images inside the `Sandbox` CR without custom builds:

| Feature | **Hermes Agent** | **OpenClaw** |
| :--- | :--- | :--- |
| **Container Image** | `nousresearch/hermes-agent:latest` | `ghcr.io/openclaw/openclaw:latest` |
| **Skill Discovery** | `$HERMES_HOME/skills/custom/<name>/SKILL.md` (YAML frontmatter + markdown procedure) | `/workspace/skills/<name>/SKILL.md` or tools configured in `openclaw.json` |
| **JIT Persona Injection** | Hermes Gateway HTTP API (`:8642/v1/chat/completions`) or `$HERMES_HOME/persona.md` | Configured via `/workspace/persona.md` and referenced in `openclaw.json` |
| **Manifests** | [`manifests/warm-pool/sandbox-generic-warm-pool.yaml`](manifests/warm-pool/sandbox-generic-warm-pool.yaml) | [`manifests/openclaw/sandbox-openclaw.yaml`](manifests/openclaw/sandbox-openclaw.yaml) |

---

## 4. Least-Privilege Scoped RBAC

When running fleets of sandboxes, each persona pool must use an isolated `ServiceAccount`:
* **SRE Observer** ([`rbac-sre.yaml`](manifests/rbac/rbac-sre.yaml)): Read-only access to pods, events, ingresses, and services. **No secret access**.
* **Security Auditor** ([`rbac-security.yaml`](manifests/rbac/rbac-security.yaml)): Read-only access to `ClusterRoleBindings`, `NetworkPolicies`, and workload security contexts.
* **FinOps Optimizer** ([`rbac-finops.yaml`](manifests/rbac/rbac-finops.yaml)): Read-only access to nodes, `metrics.k8s.io`, and `PersistentVolumeClaims`.

---

## 5. Directory Structure

```text
examples/multi-persona-fleet/
├── README.md                                # Architecture, warm pools & scalability guide
├── personas/                                # Persona definitions
│   ├── sre-observer.md                      # SRE Cluster Observer persona
│   ├── security-auditor.md                  # Security & Compliance Auditor persona
│   └── finops-optimizer.md                  # FinOps & Resource Efficiency persona
├── skills/                                  # Skill catalog with standard frontmatter
│   ├── sre/cluster-health/SKILL.md          # SRE pod health and ingress skill
│   ├── security/rbac-posture/SKILL.md       # RBAC wildcard and privileged container skill
│   └── finops/resource-waste/SKILL.md       # Resource request right-sizing skill
├── manifests/
│   ├── warm-pool/                           # WARM POOLS & CONCURRENCY
│   │   ├── sandbox-generic-warm-pool.yaml   # Generic warm pool with JIT injection
│   │   └── sandbox-partitioned-warm-pools.yaml # Pre-warmed pools with Suspended/Running modes
│   ├── rbac/                                # Least-privilege RBAC per persona
│   │   ├── rbac-sre.yaml
│   │   ├── rbac-security.yaml
│   │   └── rbac-finops.yaml
│   ├── pattern-a-configmaps/                # Low/Medium scale: ConfigMaps & Projections
│   │   ├── configmaps-personas.yaml
│   │   ├── configmaps-skills.yaml
│   │   ├── sandbox-sre.yaml
│   │   ├── sandbox-security.yaml
│   │   └── sandbox-finops.yaml
│   ├── pattern-b-oci-volumes/               # High Scale: OCI Image Volumes
│   │   ├── catalog-deployment.yaml          # Verification deployment for catalog container
│   │   ├── sandbox-oci-imagevolume.yaml     # Native K8s 1.31+ ImageVolumeSource
│   │   └── sandbox-oci-initcopier.yaml      # Universal Init Container Copier
│   └── openclaw/                            # OpenClaw Sandbox manifests
│       ├── openclaw-config.yaml
│       └── sandbox-openclaw.yaml
├── cmd/
│   └── skill-loader/                        # Static Go binary & distroless Dockerfile
│       ├── main.go
│       ├── main_test.go
│       ├── go.mod
│       └── Dockerfile
├── test_fleet.py                            # Comprehensive Python unit test suite
└── scripts/
    ├── fleet_dispatcher.py                  # Warm pool claiming & JIT injection dispatcher
    ├── validate_manifests.py                # Zero-dependency Python validation script
    ├── test_deploy_dryrun.sh                # Manifest validation & dry-run test suite
    └── run-test-fleet.sh                    # End-to-end cluster lifecycle test
```

---

## 6. Testing & Running the Warm Pool

### 1. Run the Fleet Dispatcher (Simulate JIT Warm Pool Injection)
```bash
# Claim a warm sandbox and inject the SRE persona
python3 examples/multi-persona-fleet/scripts/fleet_dispatcher.py --persona sre-observer

# Claim a warm sandbox and inject the Security persona
python3 examples/multi-persona-fleet/scripts/fleet_dispatcher.py --persona security-auditor

# List all fleet sandboxes, pools, and operating modes
python3 examples/multi-persona-fleet/scripts/fleet_dispatcher.py --list
```

### 2. Run Automated Unit Tests
```bash
python3 examples/multi-persona-fleet/test_fleet.py
```

### 3. Run the Full Dry-Run & Validation Suite
```bash
./examples/multi-persona-fleet/scripts/test_deploy_dryrun.sh
```

---

## 7. Deploying to a Live Cluster

### Step 1: Apply Least-Privilege RBAC
```bash
kubectl apply -f examples/multi-persona-fleet/manifests/rbac/
```

### Step 2: Deploy ConfigMaps & Skills Catalog
```bash
kubectl apply -f examples/multi-persona-fleet/manifests/pattern-a-configmaps/configmaps-personas.yaml \
              -f examples/multi-persona-fleet/manifests/pattern-a-configmaps/configmaps-skills.yaml
```

### Step 3: Spin up the Generic Warm Pool
```bash
kubectl apply -f examples/multi-persona-fleet/manifests/warm-pool/sandbox-generic-warm-pool.yaml
```

### Step 4: Dispatch Tasks Live to the Warm Pool
```bash
# Dispatch a task to the first available idle sandbox
python3 examples/multi-persona-fleet/scripts/fleet_dispatcher.py --persona security-auditor --live

# Explicitly suspend a standby sandbox for cost optimization
python3 examples/multi-persona-fleet/scripts/fleet_dispatcher.py --suspend pool-finops-standby-0 --live

# Resume a standby sandbox when batch work arrives
python3 examples/multi-persona-fleet/scripts/fleet_dispatcher.py --resume pool-finops-standby-0 --live
```

### Step 5: Run the Automated End-to-End Cluster Test
```bash
# Automatically applies RBAC, boots a warm pool, dispatches personas, and verifies ready status
./examples/multi-persona-fleet/scripts/run-test-fleet.sh --cleanup
```
