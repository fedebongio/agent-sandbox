#!/usr/bin/env python3
"""
Validation script for multi-persona-fleet example.
Zero-dependency validator (pure Python standard library).
Validates persona definitions, skill frontmatter, and Kubernetes manifests.
"""

import os
import re
import sys
from pathlib import Path

def parse_yaml_frontmatter(content: str) -> dict:
    """Parses frontmatter without external pyyaml dependency."""
    if not content.startswith("---"):
        raise ValueError("File does not start with YAML frontmatter delimiter '---'")
    
    parts = content.split("---", 2)
    if len(parts) < 3:
        raise ValueError("Missing closing '---' for frontmatter")
    
    frontmatter_text = parts[1]
    data = {}
    for line in frontmatter_text.strip().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" in line:
            key, val = line.split(":", 1)
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            data[key] = val
    return data

def validate_personas(personas_dir: Path):
    print(f"Validating personas in {personas_dir}...")
    files = list(personas_dir.glob("*.md"))
    if not files:
        raise ValueError(f"No persona files found in {personas_dir}")
    for file in files:
        fm = parse_yaml_frontmatter(file.read_text(encoding="utf-8"))
        for req in ["name", "description", "role"]:
            if req not in fm:
                raise ValueError(f"Persona {file.name} missing required field: '{req}'")
        print(f"  ✓ Persona {fm['name']} validated: {fm['role']}")

def validate_skills(skills_dir: Path):
    print(f"\nValidating skills in {skills_dir}...")
    files = list(skills_dir.rglob("SKILL.md"))
    if not files:
        raise ValueError(f"No SKILL.md files found in {skills_dir}")
    for file in files:
        fm = parse_yaml_frontmatter(file.read_text(encoding="utf-8"))
        for req in ["name", "description", "version"]:
            if req not in fm:
                raise ValueError(f"Skill {file.relative_to(skills_dir)} missing required field: '{req}'")
        print(f"  ✓ Skill {fm['name']} (v{fm['version']}) validated")

def validate_manifests(manifests_dir: Path):
    print(f"\nValidating Kubernetes manifests in {manifests_dir}...")
    yaml_files = sorted(manifests_dir.rglob("*.yaml"))
    if not yaml_files:
        raise ValueError(f"No yaml files found in {manifests_dir}")

    for yf in yaml_files:
        content = yf.read_text(encoding="utf-8")
        docs = re.split(r"^---\s*$", content, flags=re.MULTILINE)
        for idx, doc in enumerate(docs):
            doc = doc.strip()
            if not doc:
                continue
            kind_match = re.search(r"^kind:\s*([^\s#]+)", doc, re.MULTILINE)
            name_match = re.search(r"^\s*name:\s*([^\s#]+)", doc, re.MULTILINE)
            api_match = re.search(r"^apiVersion:\s*([^\s#]+)", doc, re.MULTILINE)

            if not kind_match or not api_match:
                raise ValueError(f"Manifest {yf.relative_to(manifests_dir)} doc #{idx} missing apiVersion or kind")
            if not name_match:
                raise ValueError(f"Manifest {yf.relative_to(manifests_dir)} doc #{idx} missing metadata.name")

            print(f"  ✓ {kind_match.group(1)}/{name_match.group(1)} in {yf.relative_to(manifests_dir)}")

def main():
    root = Path(__file__).resolve().parent.parent
    personas_dir = root / "personas"
    skills_dir = root / "skills"
    manifests_dir = root / "manifests"

    try:
        validate_personas(personas_dir)
        validate_skills(skills_dir)
        validate_manifests(manifests_dir)
        print("\nAll multi-persona-fleet components validated successfully!")
    except Exception as e:
        print(f"\n❌ Validation error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
