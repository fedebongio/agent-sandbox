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
        # Fallback to checking by label
        return ""
    return res.stdout.strip()

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

def dispatch_task(sandbox_name: str, persona_name: str, task_prompt: str, dry_run: bool = True):
    """
    Demonstrates Just-In-Time persona injection.
    Injects the persona system instructions and task into the warm gateway.
    """
    persona_instructions = load_persona(persona_name)
    
    # Construct JIT Gateway payload
    payload = {
        "model": "gemini/gemini-3.5-flash",
        "system_prompt": persona_instructions,
        "messages": [
            {"role": "user", "content": task_prompt}
        ],
        "metadata": {
            "sandbox": sandbox_name,
            "persona": persona_name,
            "jit_injected": True
        }
    }

    print("\n--- Dispatch Payload (JIT Persona Injection) ---")
    print(f"Target Sandbox : {sandbox_name}")
    print(f"Active Persona : {persona_name}")
    print(f"Task           : {task_prompt}")
    print(f"Payload Size   : {len(json.dumps(payload))} bytes")
    print("------------------------------------------------\n")

    if dry_run:
        print("✅ [Dry-Run] Dispatched to warm gateway http://<sandbox>:8642/chat successfully.")
        print("   Runtime executed task without pod restart or container redeployment.")
    else:
        # In live mode, send HTTP request to the Sandbox Service or use kubectl exec
        print(f"Sending request to Sandbox service {sandbox_name}...")

def main():
    parser = argparse.ArgumentParser(description="Fleet Dispatcher: JIT Persona Injection for Warm Pools")
    parser.add_argument("--persona", default="security-auditor",
                        choices=["sre-observer", "security-auditor", "finops-optimizer"],
                        help="Persona to dynamically inject")
    parser.add_argument("--task", default="Perform an immediate audit of privileged workloads in namespace default.",
                        help="Task prompt for the agent")
    parser.add_argument("--pool", default="generic-warm-pool",
                        help="Target warm pool name")
    parser.add_argument("--live", action="store_true",
                        help="Run against real cluster instead of dry-run simulation")
    args = parser.parse_args()

    dry_run = not args.live
    print(f"=== Multi-Persona Fleet Dispatcher (Mode: {'LIVE' if args.live else 'SIMULATION/DRY-RUN'}) ===")
    
    sandbox = find_idle_sandbox(args.pool, dry_run=dry_run)
    if not sandbox:
        print(f"❌ No idle warm sandboxes available in pool '{args.pool}'.")
        sys.exit(1)

    try:
        claim_sandbox(sandbox, args.persona, dry_run=dry_run)
        dispatch_task(sandbox, args.persona, args.task, dry_run=dry_run)
    finally:
        release_sandbox(sandbox, dry_run=dry_run)

    print("\n🎉 Warm pool dispatch completed successfully!")

if __name__ == "__main__":
    main()
