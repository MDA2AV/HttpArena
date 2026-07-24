#!/usr/bin/env python3
"""One-off: split site/data/<profile>-<conns>.json into per-framework files.

Every framework's results used to live in 52 shared arrays, so two pull
requests saving results touched the same files and conflicted (#751). After
this each framework owns exactly one file, and concurrent runs cannot collide.

    site/data/baseline-512.json      [ {actix...}, {hyper...}, ... ]   ->
    site/data/results/actix.json     { framework, results: { "baseline-512": {...} } }

Rows are copied verbatim, so the generated data.js is unchanged. Run once;
rebuild_site_data.py writes the new layout from then on.
"""

from __future__ import annotations
import argparse
import json
import re
import sys
from pathlib import Path

# Files in site/data that are not per-profile result arrays.
NON_RESULT = {"frameworks.json", "current.json", "langcolors.json"}


def slug(name: str) -> str:
    """Filename for a display name. Two entries ('aspnet-minimal + nginx' and
    '+ caddy') contain spaces and a plus, so names cannot be used directly."""
    s = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-")
    return s.lower() or "unnamed"


def collect(site_data: Path) -> dict[str, dict]:
    """{slug: {framework, results: {profile-conns: row}}} from the flat files."""
    out: dict[str, dict] = {}
    for f in sorted(site_data.glob("*.json")):
        if f.name in NON_RESULT:
            continue
        try:
            rows = json.loads(f.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"[warn] skipping {f.name}: {e}", file=sys.stderr)
            continue
        if not isinstance(rows, list):
            continue
        key = f.stem                      # e.g. "baseline-512"
        for row in rows:
            if not isinstance(row, dict):
                continue
            name = row.get("framework")
            if not name:
                continue
            entry = out.setdefault(slug(name), {"framework": name, "results": {}})
            if entry["framework"] != name:
                print(f"[warn] slug collision: {entry['framework']!r} vs {name!r}", file=sys.stderr)
            entry["results"][key] = row
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    site_data = Path(args.root) / "site" / "data"
    results_dir = site_data / "results"

    frameworks = collect(site_data)
    n_rows = sum(len(e["results"]) for e in frameworks.values())
    print(f"{len(frameworks)} frameworks, {n_rows} rows")

    if args.dry_run:
        for s, e in sorted(frameworks.items())[:5]:
            print(f"  {s}.json  <- {e['framework']} ({len(e['results'])} rows)")
        return

    results_dir.mkdir(parents=True, exist_ok=True)
    for s, entry in sorted(frameworks.items()):
        entry["results"] = dict(sorted(entry["results"].items()))
        (results_dir / f"{s}.json").write_text(json.dumps(entry, indent=2) + "\n", encoding="utf-8")

    removed = 0
    for f in sorted(site_data.glob("*.json")):
        if f.name in NON_RESULT:
            continue
        f.unlink()
        removed += 1
    print(f"wrote {len(frameworks)} files to {results_dir.relative_to(Path(args.root))}, "
          f"removed {removed} flat files")


if __name__ == "__main__":
    main()
