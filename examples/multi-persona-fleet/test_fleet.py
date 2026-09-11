#!/usr/bin/env python3
"""
Unit tests for the Multi-Persona Fleet example.
Validates persona files, skill definitions, RBAC configurations, and Sandbox manifests.
"""

import importlib.util
import os
import re
import unittest
from pathlib import Path

FLEET_DIR = Path(__file__).resolve().parent

def parse_frontmatter(text: str) -> dict:
    if not text.startswith("---"):
        raise ValueError("Content missing starting '---'")
    parts = text.split("---", 2)
    if len(parts) < 3:
        raise ValueError("Content missing closing '---'")
    fm = {}
    for line in parts[1].strip().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" in line:
            k, v = line.split(":", 1)
            fm[k.strip()] = v.strip().strip('"').strip("'")
    return fm

class TestMultiPersonaFleet(unittest.TestCase):

    def test_personas_exist_and_valid(self):
        personas_dir = FLEET_DIR / "personas"
        self.assertTrue(personas_dir.exists(), "Personas directory missing")
        expected_personas = ["sre-observer.md", "security-auditor.md", "finops-optimizer.md"]
        for p in expected_personas:
            p_path = personas_dir / p
            self.assertTrue(p_path.exists(), f"Persona file {p} missing")
            content = p_path.read_text(encoding="utf-8")
            fm = parse_frontmatter(content)
            self.assertIn("name", fm)
            self.assertIn("description", fm)
            self.assertIn("role", fm)
            self.assertIn("engine", fm)
            self.assertIn("Strictly Read-Only", content, f"Persona {p} must enforce read-only safety boundary")

    def test_skills_exist_and_valid(self):
        skills_dir = FLEET_DIR / "skills"
        self.assertTrue(skills_dir.exists(), "Skills directory missing")
        skill_files = list(skills_dir.rglob("SKILL.md"))
        self.assertGreaterEqual(len(skill_files), 3, "Expected at least 3 skill definitions")
        for sf in skill_files:
            content = sf.read_text(encoding="utf-8")
            fm = parse_frontmatter(content)
            self.assertIn("name", fm)
            self.assertIn("description", fm)
            self.assertIn("version", fm)
            self.assertIn("category", fm)

    def test_rbac_least_privilege_separation(self):
        rbac_dir = FLEET_DIR / "manifests" / "rbac"
        self.assertTrue(rbac_dir.exists(), "RBAC directory missing")
        
        # 1. SRE RBAC
        sre_rbac = (rbac_dir / "rbac-sre.yaml").read_text(encoding="utf-8")
        self.assertIn("sandbox-sre", sre_rbac)
        self.assertIn("ingresses", sre_rbac)
        self.assertNotIn('"secrets"', sre_rbac, "SRE persona should not have access to secrets")

        # 2. Security RBAC
        sec_rbac = (rbac_dir / "rbac-security.yaml").read_text(encoding="utf-8")
        self.assertIn("sandbox-security", sec_rbac)
        self.assertIn("clusterrolebindings", sec_rbac)
        self.assertIn("networkpolicies", sec_rbac)

        # 3. FinOps RBAC
        finops_rbac = (rbac_dir / "rbac-finops.yaml").read_text(encoding="utf-8")
        self.assertIn("sandbox-finops", finops_rbac)
        self.assertIn("metrics.k8s.io", finops_rbac)
        self.assertIn("persistentvolumeclaims", finops_rbac)

    def test_sandbox_manifests_pattern_a(self):
        pattern_a_dir = FLEET_DIR / "manifests" / "pattern-a-configmaps"
        self.assertTrue(pattern_a_dir.exists())

        for persona, sa, skill_key in [
            ("sre", "sandbox-sre", "fleet-skills-sre"),
            ("security", "sandbox-security", "fleet-skills-security"),
            ("finops", "sandbox-finops", "fleet-skills-finops")
        ]:
            sb_file = pattern_a_dir / f"sandbox-{persona}.yaml"
            self.assertTrue(sb_file.exists(), f"Sandbox {sb_file} missing")
            content = sb_file.read_text(encoding="utf-8")
            self.assertIn("kind: Sandbox", content)
            self.assertIn(f"serviceAccountName: {sa}", content)
            self.assertIn("name: fleet-personas", content)
            self.assertIn(f"name: {skill_key}", content)

    def test_sandbox_manifests_pattern_b_scale(self):
        pattern_b_dir = FLEET_DIR / "manifests" / "pattern-b-oci-volumes"
        self.assertTrue(pattern_b_dir.exists())

        img_vol_file = pattern_b_dir / "sandbox-oci-imagevolume.yaml"
        self.assertTrue(img_vol_file.exists())
        img_content = img_vol_file.read_text(encoding="utf-8")
        self.assertIn("image:", img_content)
        self.assertIn("pullPolicy: IfNotPresent", img_content)

        init_file = pattern_b_dir / "sandbox-oci-initcopier.yaml"
        self.assertTrue(init_file.exists())
        init_content = init_file.read_text(encoding="utf-8")
        self.assertIn("initContainers:", init_content)
        self.assertIn("copy-skills-catalog", init_content)

    def test_openclaw_manifests(self):
        openclaw_dir = FLEET_DIR / "manifests" / "openclaw"
        self.assertTrue(openclaw_dir.exists())
        
        cfg_file = openclaw_dir / "openclaw-config.yaml"
        self.assertTrue(cfg_file.exists())
        self.assertIn("openclaw.json", cfg_file.read_text(encoding="utf-8"))

        sb_file = openclaw_dir / "sandbox-openclaw.yaml"
        self.assertTrue(sb_file.exists())
        sb_content = sb_file.read_text(encoding="utf-8")
        self.assertIn("ghcr.io/openclaw/openclaw:latest", sb_content)
        self.assertIn("/workspace", sb_content)

    def test_warm_pool_manifests(self):
        warm_pool_dir = FLEET_DIR / "manifests" / "warm-pool"
        self.assertTrue(warm_pool_dir.exists())

        generic_file = warm_pool_dir / "sandbox-generic-warm-pool.yaml"
        self.assertTrue(generic_file.exists())
        generic_content = generic_file.read_text(encoding="utf-8")
        self.assertIn("operatingMode: Running", generic_content)
        self.assertIn("agent.x-k8s.io/pool: generic-warm-pool", generic_content)
        self.assertIn("containerPort: 8642", generic_content)

        partitioned_file = warm_pool_dir / "sandbox-partitioned-warm-pools.yaml"
        self.assertTrue(partitioned_file.exists())
        part_content = partitioned_file.read_text(encoding="utf-8")
        self.assertIn("pool-sre-warm-0", part_content)
        self.assertIn("pool-security-warm-0", part_content)
        self.assertIn("operatingMode: Suspended", part_content)

    def test_fleet_dispatcher_load_persona(self):
        dispatcher_path = FLEET_DIR / "scripts" / "fleet_dispatcher.py"
        spec = importlib.util.spec_from_file_location("fleet_dispatcher", dispatcher_path)
        dispatcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(dispatcher)
        
        for persona_name in ["sre-observer", "security-auditor", "finops-optimizer"]:
            text = dispatcher.load_persona(persona_name)
            self.assertIn("Strictly Read-Only", text)

if __name__ == "__main__":
    unittest.main()
