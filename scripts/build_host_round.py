#!/usr/bin/env python3
"""Package a host profile's results as an archived round.

    scripts/build_host_round.py rpi --name "Raspberry Pi 4 (arm64)"

benchmark.sh run with HOST_PROFILE=<host> --save writes its results to
results-hosts/<host>/<profile>/<conns>/<framework>.json and leaves site/data/
alone. This bundles them into site/data/rounds/<id>.json in the shape
archive.sh writes ({"<profile>-<conns>": [row, ...], "current": {...}}) and
adds or updates the round's entry in rounds/index.json, with the hardware read
from the machine it runs on - so run it on the host that produced the results.

Re-running it updates the same round (matched by its "host" field) rather than
adding another one, so a round can be filled in framework by framework.
"""

from __future__ import annotations

import argparse
import datetime
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE_DATA = ROOT / "site" / "data"
ROUNDS = SITE_DATA / "rounds"

sys.path.insert(0, str(ROOT / "scripts"))
from rebuild_site_data import write_current_json  # noqa: E402


def collect(results_dir: Path) -> dict[str, list]:
    bundle: dict[str, list] = {}
    for profile_dir in sorted(p for p in results_dir.iterdir() if p.is_dir() and not p.name.startswith("_")):
        for conn_dir in sorted(p for p in profile_dir.iterdir() if p.is_dir()):
            key = f"{profile_dir.name}-{conn_dir.name}"
            for f in sorted(conn_dir.glob("*.json")):
                try:
                    row = json.loads(f.read_text())
                except Exception as e:
                    print(f"[warn] skipping {f}: {e}", file=sys.stderr)
                    continue
                if row.get("framework"):
                    bundle.setdefault(key, []).append(row)
    for rows in bundle.values():
        rows.sort(key=lambda r: (r.get("framework") or "").lower())
    return bundle


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("host", help="host profile name, e.g. rpi")
    ap.add_argument("--name", required=True, help="round name shown in the selector")
    args = ap.parse_args()

    results_dir = ROOT / "results-hosts" / args.host
    if not results_dir.is_dir():
        sys.exit(f"{results_dir} not found - run benchmark.sh with HOST_PROFILE={args.host} --save first")

    bundle = collect(results_dir)
    if not bundle:
        sys.exit(f"no results under {results_dir}")

    with tempfile.TemporaryDirectory() as tmp:
        write_current_json(ROOT, Path(tmp))
        current = json.loads((Path(tmp) / "current.json").read_text())
    current["arch"] = subprocess.check_output(["uname", "-m"]).decode().strip()
    try:
        current["model"] = Path("/proc/device-tree/model").read_text().strip("\x00 \n")
    except OSError:
        pass
    bundle["current"] = current

    ROUNDS.mkdir(parents=True, exist_ok=True)
    index_path = ROUNDS / "index.json"
    index = json.loads(index_path.read_text()) if index_path.exists() else []

    entry = next((r for r in index if r.get("host") == args.host), None)
    if entry is None:
        # Ids already used by bundles that are no longer indexed stay taken.
        used = [r.get("id", 0) for r in index] + [int(p.stem) for p in ROUNDS.glob("*.json") if p.stem.isdigit()]
        entry = {"id": max(used, default=0) + 1}
        index.append(entry)

    commit = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
                            capture_output=True, text=True).stdout.strip() or "unknown"
    entry.update({
        "name": args.name,
        "host": args.host,
        "date": datetime.date.today().isoformat(),
        "cpu": current.get("cpu"),
        "cores": current.get("cores"),
        "threads": current.get("threads"),
        "ram": current.get("ram"),
        "os": current.get("os"),
        "kernel": current.get("kernel"),
        "docker": current.get("docker"),
        "docker_runtime": current.get("docker_runtime"),
        "governor": current.get("governor"),
        "arch": current.get("arch"),
        "commit": commit,
    })
    if current.get("tcp"):
        entry["tcp"] = current["tcp"]

    (ROUNDS / f"{entry['id']}.json").write_text(json.dumps(bundle, separators=(",", ":")))
    index_path.write_text(json.dumps(index, indent=2) + "\n")

    fws = {r["framework"] for k, rows in bundle.items() if k != "current" for r in rows}
    print(f"round {entry['id']} ({args.name}): {len(bundle) - 1} views, {len(fws)} frameworks")


if __name__ == "__main__":
    main()
