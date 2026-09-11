#!/usr/bin/env python3
"""
Fleet Dispatcher: Demonstrates Just-In-Time (JIT) persona and skill injection
into a warm pool of agent-sandboxes.

This script illustrates the warm pool lifecycle:
 1. Discover idle warm sandboxes (`agent.x-k8s.io/status=idle`).
 2. Claim an idle sandbox by setting `agent.x-k8s.io/status=busy`.
 3. Inject the requested persona & skill instructions into the warm runtime
    via HTTP Gateway API or ephemeral execution without restarting the pod.
 4. Release the sandbox back to the idle pool upon task completion.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PERSONAS_DIR = REPO_ROOT / "personas"
SKILLS_DIR = REPO_ROOT / "skills"

def load_persona(persona_name: str) -> str:
    persona_file = PERSONAS_DIR / f"{persona_name}.md"
    if not persona_file.exists():
        raise FileNotFoundError(f"Persona file not found: {persona_file}")
    return persona_file.read_text(encoding="utf-8")

def build_dispatch_payload(sandbox_name: str, persona_name: str, task_prompt: str, model: str = "hermes-agent") -> dict:
    """Constructs an OpenAI-compatible payload for JIT persona injection via /v1/chat/completions."""
    persona_instructions = load_persona(persona_name)
    return {
        "model": model,
        "messages": [
            {"role": "system", "content": persona_instructions},
            {"role": "user", "content": task_prompt}
        ],
        "temperature": 0.2,
        "metadata": {
            "sandbox": sandbox_name,
            "persona": persona_name,
            "jit_injected": True
        }
    }

def find_idle_sandbox(pool_name: str = "generic-warm-pool", dry_run: bool = False) -> str:
    """Queries Kubernetes for an idle sandbox in the specified pool."""
    if dry_run:
        return "agent-sandbox-warm-1 (mock)"

    cmd = [
        "kubectl", "get", "sandboxes",
        "-l", f"agent.x-k8s.io/pool={pool_name},agent.x-k8s.io/status=idle",
        "-o", "jsonpath={.items[0].metadata.name}"
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0 or not res.stdout.strip():
        return ""
    return res.stdout.strip().split()[0]

def list_sandboxes(pool: str = None):
    """Lists all fleet sandboxes, their warm pool, status, and active persona."""
    label_filter = f"agent.x-k8s.io/pool={pool}" if pool else "app.kubernetes.io/part-of=multi-persona-fleet"
    cmd = ["kubectl", "get", "sandboxes", "-l", label_filter, "-o", "json"]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"Error querying sandboxes: {res.stderr}")
        return

    data = json.loads(res.stdout) if res.stdout.strip() else {"items": []}
    items = data.get("items", [])
    if not items:
        print(f"No sandboxes found matching label filter '{label_filter}'.")
        return

    print(f"\n{'SANDBOX NAME':<32} {'POOL':<22} {'STATUS':<12} {'ACTIVE PERSONA':<20} {'OPERATING MODE':<15}")
    print("=" * 105)
    for sb in items:
        name = sb.get("metadata", {}).get("name", "")
        labels = sb.get("metadata", {}).get("labels", {})
        pool_val = labels.get("agent.x-k8s.io/pool", "none")
        status_val = labels.get("agent.x-k8s.io/status", "unknown")
        persona_val = labels.get("agent.x-k8s.io/active-persona") or labels.get("agent.x-k8s.io/persona", "-")
        mode_val = sb.get("spec", {}).get("operatingMode", "Running")
        print(f"{name:<32} {pool_val:<22} {status_val:<12} {persona_val:<20} {mode_val:<15}")
    print()

def claim_sandbox(sandbox_name: str, persona_name: str, dry_run: bool = False):
    """Marks the sandbox as claimed/busy with the assigned persona."""
    print(f"🔒 Claiming warm sandbox '{sandbox_name}' for persona '{persona_name}'...")
    if not dry_run:
        subprocess.run([
            "kubectl", "label", "sandbox", sandbox_name,
            "agent.x-k8s.io/status=busy",
            f"agent.x-k8s.io/active-persona={persona_name}",
            "--overwrite"
        ], check=True)

def release_sandbox(sandbox_name: str, dry_run: bool = False):
    """Releases the sandbox back to the idle warm pool."""
    print(f"🔓 Releasing sandbox '{sandbox_name}' back to the warm pool as idle...")
    if not dry_run:
        subprocess.run([
            "kubectl", "label", "sandbox", sandbox_name,
            "agent.x-k8s.io/status=idle",
            "agent.x-k8s.io/active-persona-",
            "--overwrite"
        ], check=True)

def set_operating_mode(sandbox_name: str, mode: str, dry_run: bool = False):
    """Switches sandbox operatingMode between 'Running' and 'Suspended'."""
    print(f"⚙️  Setting operatingMode='{mode}' on sandbox '{sandbox_name}'...")
    if not dry_run:
        patch = json.dumps({"spec": {"operatingMode": mode}})
        subprocess.run(["kubectl", "patch", "sandbox", sandbox_name, "--type=merge", "-p", patch], check=True)

def dispatch_task(sandbox_name: str, persona_name: str, task_prompt: str, dry_run: bool = True,
                  model: str = "hermes-agent", api_key: str = None):
    """
    Demonstrates Just-In-Time persona injection.
    Injects the persona system instructions and task into the warm gateway.
    """
    payload = build_dispatch_payload(sandbox_name, persona_name, task_prompt, model=model)

    print("\n--- Dispatch Payload (JIT Persona Injection) ---")
    print(f"Target Sandbox : {sandbox_name}")
    print(f"Active Persona : {persona_name}")
    print(f"Task           : {task_prompt}")
    print(f"Payload Size   : {len(json.dumps(payload))} bytes")
    print("------------------------------------------------\n")

    if dry_run:
        print("✅ [Dry-Run] Dispatched to warm gateway http://<sandbox>:8642/v1/chat/completions successfully.")
        print("   Runtime executed task without pod restart or container redeployment.")
        return

    # In live mode, send request directly to container via kubectl exec
    headers = ["Content-Type: application/json"]
    if api_key:
        headers.append(f"Authorization: Bearer {api_key}")

    header_args = []
    for h in headers:
        header_args.extend(["-H", h])

    cmd = [
        "kubectl", "exec", "-i", sandbox_name, "-c", "hermes", "--",
        "curl", "-s", "-X", "POST", "http://localhost:8642/v1/chat/completions"
    ] + header_args + ["-d", json.dumps(payload)]

    print(f"📡 Sending JIT request to gateway in sandbox '{sandbox_name}'...")
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"❌ Execution failed: {res.stderr}")
        return

    try:
        reply = json.loads(res.stdout)
        choices = reply.get("choices", [])
        if choices:
            content = choices[0].get("message", {}).get("content", "")
            print(f"🤖 Response from {persona_name}:\n{content}\n")
        else:
            print(f"Response: {res.stdout}")
    except json.JSONDecodeError:
        print(f"Raw response: {res.stdout}")

def main():
    parser = argparse.ArgumentParser(description="Fleet Dispatcher: JIT Persona Injection for Warm Pools")
    parser.add_argument("--persona", default="security-auditor",
                        choices=["sre-observer", "security-auditor", "finops-optimizer"],
                        help="Persona to dynamically inject")
    parser.add_argument("--task", default="Perform an immediate audit of privileged workloads in namespace default.",
                        help="Task prompt for the agent")
    parser.add_argument("--pool", default="generic-warm-pool",
                        help="Target warm pool name")
    parser.add_argument("--model", default="hermes-agent",
                        help="Model identifier for completion request")
    parser.add_argument("--api-key", default=None,
                        help="API key for gateway auth (API_SERVER_KEY)")
    parser.add_argument("--live", action="store_true",
                        help="Run against real cluster instead of dry-run simulation")
    parser.add_argument("--list", action="store_true",
                        help="List fleet sandboxes and their status")
    parser.add_argument("--release", metavar="SANDBOX_NAME",
                        help="Explicitly release a claimed sandbox back to idle")
    parser.add_argument("--suspend", metavar="SANDBOX_NAME",
                        help="Suspend a sandbox (operatingMode: Suspended)")
    parser.add_argument("--resume", metavar="SANDBOX_NAME",
                        help="Resume a sandbox (operatingMode: Running)")
    args = parser.parse_args()

    if args.list:
        list_sandboxes(args.pool if args.pool != "generic-warm-pool" else None)
        return

    if args.release:
        release_sandbox(args.release, dry_run=not args.live)
        return

    if args.suspend:
        set_operating_mode(args.suspend, "Suspended", dry_run=not args.live)
        return

    if args.resume:
        set_operating_mode(args.resume, "Running", dry_run=not args.live)
        return

    dry_run = not args.live
    print(f"=== Multi-Persona Fleet Dispatcher (Mode: {'LIVE' if args.live else 'SIMULATION/DRY-RUN'}) ===")
    
    sandbox = find_idle_sandbox(args.pool, dry_run=dry_run)
    if not sandbox:
        print(f"❌ No idle warm sandboxes available in pool '{args.pool}'.")
        sys.exit(1)

    try:
        claim_sandbox(sandbox, args.persona, dry_run=dry_run)
        dispatch_task(sandbox, args.persona, args.task, dry_run=dry_run, model=args.model, api_key=args.api_key)
    finally:
        release_sandbox(sandbox, dry_run=dry_run)

    print("\n🎉 Warm pool dispatch completed successfully!")

if __name__ == "__main__":
    main()
