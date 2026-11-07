#!/usr/bin/env python3
"""Checks the variant fields of every meta.json. See the Variants section of the framework docs.

    python3 scripts/check_variants.py frameworks
"""
import json
import sys
from pathlib import Path

MAX_VARIANTS = 2


def problems(root):
    found, seen = [], {}
    for path in sorted(Path(root).glob("*/meta.json")):
        name = path.parent.name
        try:
            meta = json.loads(path.read_text(encoding="utf-8"))
        except ValueError as e:
            found.append(f"{name}: {e}")
            continue
        framework, variant = meta.get("framework"), meta.get("variant")
        if bool(framework) != bool(variant):
            found.append(f"{name}: framework and variant go together")
        if "default_visible" in meta and not (framework and variant):
            found.append(f"{name}: default_visible is only for a variant")
        if not isinstance(meta.get("default_visible", True), bool):
            found.append(f"{name}: default_visible is true or false")
        if framework and variant:
            seen.setdefault(framework, []).append((name, variant))
    for framework, entries in seen.items():
        names = ", ".join(name for name, _ in entries)
        if len(entries) > MAX_VARIANTS:
            found.append(f"{framework}: at most {MAX_VARIANTS} variants, found {names}")
        if len({variant for _, variant in entries}) != len(entries):
            found.append(f"{framework}: two entries name the same variant: {names}")
    return found


if __name__ == "__main__":
    wrong = problems(sys.argv[1] if len(sys.argv) > 1 else "frameworks")
    for line in wrong:
        print("FAIL: " + line)
    sys.exit(1 if wrong else 0)
