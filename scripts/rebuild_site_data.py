#!/usr/bin/env python3
"""
Rebuild site/data/*.json from results/<profile>/<conns>/<framework>.json files.

Writes:
  site/data/frameworks.json    — hybrid map of {display_name: {dir, description, ..., variants?}}
  site/data/results/<framework>.json — per-framework results keyed by <profile>-<conns>
  site/data/current.json       — hardware + OS + round info for the current round

This is a straightforward data transform; it used to live as two embedded
Python scripts inside benchmark.sh heredocs. Extracted for readability and
so you can run it independently without firing a full benchmark.
"""

from __future__ import annotations
import argparse
import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path


# The four things a framework can do for you between an arriving request and a
# finished response. Each one an entry does not do costs it 5% of its composite
# — see site/content/docs/scoring/completeness.md.
COMPLETENESS_AXES = ("routing", "middleware", "request", "response")


def _completeness(value, meta_path: str) -> dict:
    """Normalize meta.json's `completeness` to the four known axes.

    Only `false` carries weight, so a typo'd key would silently mean "done"
    rather than failing — hence the warning. An axis left out is left out on
    purpose: it reads as done, which is what makes a partial declaration like
    `{"middleware": false}` the natural way to write "only middleware missing".
    """
    if not isinstance(value, dict):
        print(f"[warn] {meta_path}: completeness must be an object of "
              f"{'/'.join(COMPLETENESS_AXES)} booleans - ignoring", file=sys.stderr)
        return {}
    for k in value:
        if k not in COMPLETENESS_AXES:
            print(f"[warn] {meta_path}: unknown completeness axis {k!r} - ignored "
                  f"(expected {', '.join(COMPLETENESS_AXES)})", file=sys.stderr)
    return {a: bool(value[a]) for a in COMPLETENESS_AXES if a in value}


def rebuild_frameworks_json(root: Path, site_data: Path) -> None:
    """Aggregate every frameworks/*/meta.json into site/data/frameworks.json.

    Hybrid shape — primary entry fields stay at top level for backwards
    compatibility with all leaderboards. Additional entries that share the
    same `display_name` go into a `variants` array (read only by the composite
    popup to surface every grouped variant).

    Primary selection: entry whose dir == display_name, else first alphabetical.
    """
    groups: dict[str, list[dict]] = {}
    for meta_path in sorted(glob.glob(str(root / "frameworks" / "*" / "meta.json"))):
        fw_dir = os.path.basename(os.path.dirname(meta_path))
        try:
            m = json.load(open(meta_path))
        except Exception as e:
            print(f"[warn] skipping {meta_path}: {e}", file=sys.stderr)
            continue
        display = m.get("display_name", fw_dir)
        entry = {
            "dir": fw_dir,
            "description": m.get("description", ""),
            "repo": m.get("repo", ""),
            "type": m.get("type", "emerging"),
            "engine": m.get("engine", ""),
        }
        if "mode" in m:
            entry["mode"] = m["mode"]
        if "completeness" in m:
            entry["completeness"] = _completeness(m["completeness"], meta_path)
        groups.setdefault(display, []).append(entry)

    out: dict[str, dict] = {}
    for display, entries in groups.items():
        entries_sorted = sorted(entries, key=lambda e: e["dir"])
        primary = next(
            (e for e in entries_sorted if e["dir"] == display),
            entries_sorted[0],
        )
        variants = [e for e in entries_sorted if e["dir"] != primary["dir"]]
        obj = dict(primary)
        if variants:
            obj["variants"] = variants
        out[display] = obj

    site_data.mkdir(parents=True, exist_ok=True)
    target = site_data / "frameworks.json"
    target.write_text(json.dumps(out, indent=2))
    print(f"[updated] {target}")


def _slug(name: str) -> str:
    """Filename for a display name. A couple of gateway entries contain spaces
    and a '+', so names can't be used as filenames directly."""
    return (re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-") or "unnamed").lower()


def merge_results(results_dir: Path, site_data: Path) -> None:
    """Fold results/<profile>/<conns>/<framework>.json into the per-framework
    files under site/data/results/.

    One file per framework, keyed by "<profile>-<conns>". Results used to be
    stored as one array per profile-conns holding every framework, so two pull
    requests saving results wrote the same files and conflicted (#751); now a
    run only ever touches the file belonging to the framework it benchmarked.

    Rules (unchanged from the flat layout):
      * A new result replaces the existing one for that framework and key
      * Keys the run didn't produce are left alone
      * Frameworks that no longer exist in frameworks.json are dropped
    """
    # frameworks.json was just rebuilt from meta.json, so its keys are the
    # current display names; anything else is stale (e.g. a renamed framework).
    valid_names: set[str] = set()
    fj = site_data / "frameworks.json"
    if fj.exists():
        try:
            valid_names = set(json.load(open(fj)).keys())
        except Exception:
            valid_names = set()

    out_dir = site_data / "results"
    out_dir.mkdir(parents=True, exist_ok=True)

    # Collect this run's rows, grouped by framework: {name: {key: row}}
    incoming: dict[str, dict] = {}
    for profile_dir in sorted(results_dir.iterdir()):
        if not profile_dir.is_dir():
            continue
        for conn_dir in sorted(profile_dir.iterdir()):
            if not conn_dir.is_dir():
                continue
            key = f"{profile_dir.name}-{conn_dir.name}"
            for f in sorted(conn_dir.glob("*.json")):
                try:
                    entry = json.load(open(f))
                except Exception as e:
                    print(f"[warn] skipping {f}: {e}", file=sys.stderr)
                    continue
                name = entry.get("framework", "")
                if not name:
                    continue
                incoming.setdefault(name, {})[key] = entry

    for name, rows in sorted(incoming.items()):
        path = out_dir / f"{_slug(name)}.json"
        data = {"framework": name, "results": {}}
        if path.exists():
            try:
                prev = json.load(open(path))
                if isinstance(prev.get("results"), dict):
                    data["results"] = prev["results"]
            except Exception:
                pass
        data["results"].update(rows)
        data["results"] = dict(sorted(data["results"].items()))
        path.write_text(json.dumps(data, indent=2) + "\n")
        print(f"[updated] {path} - {len(rows)} new, {len(data['results'])} total")

    if valid_names:
        for path in sorted(out_dir.glob("*.json")):
            try:
                name = json.load(open(path)).get("framework", "")
            except Exception:
                continue
            if name and name not in valid_names:
                path.unlink()
                print(f"[purged stale] {path.name} ({name})", file=sys.stderr)


def write_current_json(root: Path, site_data: Path) -> None:
    """Capture host/OS/docker info for the current benchmark round.

    Best-effort — each field falls back to `unknown` if the underlying command
    isn't available or errors out.
    """
    def run(cmd: list[str], default: str = "unknown") -> str:
        try:
            return subprocess.check_output(
                cmd, stderr=subprocess.DEVNULL
            ).decode().strip()
        except Exception:
            return default

    def sysctl(key: str) -> str | None:
        try:
            return subprocess.check_output(
                ["sysctl", "-n", key], stderr=subprocess.DEVNULL
            ).decode().strip()
        except Exception:
            return None

    # CPU model
    cpu = "unknown"
    try:
        out = subprocess.check_output(["lscpu"], stderr=subprocess.DEVNULL).decode()
        for line in out.splitlines():
            if line.startswith("Model name:"):
                cpu = line.split(":", 1)[1].strip()
                break
    except Exception:
        pass

    threads = run(["nproc"], "unknown")
    threads_per_core = "1"
    try:
        out = subprocess.check_output(["lscpu"], stderr=subprocess.DEVNULL).decode()
        for line in out.splitlines():
            if line.startswith("Thread(s) per core:"):
                threads_per_core = line.split(":", 1)[1].strip()
                break
    except Exception:
        pass

    try:
        cores = str(int(threads) // int(threads_per_core))
    except Exception:
        cores = threads

    ram = "unknown"
    try:
        out = subprocess.check_output(["free", "-h"], stderr=subprocess.DEVNULL).decode()
        for line in out.splitlines():
            if line.startswith("Mem:"):
                ram = line.split()[1]
                break
    except Exception:
        pass

    ram_speed = "unknown"
    try:
        out = subprocess.check_output(
            ["sudo", "dmidecode", "-t", "memory"], stderr=subprocess.DEVNULL
        ).decode()
        for line in out.splitlines():
            if "Configured Memory Speed:" in line and "MHz" in line:
                ram_speed = line.split()[3] + " MHz"
                break
    except Exception:
        pass

    governor = "unknown"
    try:
        governor = Path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor").read_text().strip()
    except Exception:
        pass

    os_info = "unknown"
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            if line.startswith("PRETTY_NAME="):
                os_info = line.split("=", 1)[1].strip().strip('"')
                break
    except Exception:
        os_info = run(["uname", "-s"], "unknown")

    kernel = run(["uname", "-r"])
    docker_ver = run(["docker", "version", "--format", "{{.Server.Version}}"])
    docker_runtime = run(["docker", "info", "--format", "{{.DefaultRuntime}}"])

    lo_mtu = None
    try:
        out = subprocess.check_output(["ip", "link", "show", "lo"], stderr=subprocess.DEVNULL).decode()
        for line in out.splitlines():
            if " mtu " in line:
                parts = line.split()
                idx = parts.index("mtu")
                lo_mtu = parts[idx + 1]
                break
    except Exception:
        pass

    # date and commit were intentionally dropped — they churned on every
    # /benchmark --save run and were the dominant source of merge conflicts
    # between concurrent PRs. archive.sh re-derives commit from git directly
    # at archive time; the leaderboard omits the "current" round badge when
    # the field is absent.
    out: dict = {
        "cpu": cpu,
        "cores": cores,
        "threads": threads,
        "threads_per_core": threads_per_core,
        "ram": ram,
        "os": os_info,
        "kernel": kernel,
        "docker": docker_ver,
        "docker_runtime": docker_runtime,
        "governor": governor,
    }
    if ram_speed != "unknown":
        out["ram_speed"] = ram_speed

    tcp: dict = {}
    if lo_mtu:
        tcp["lo_mtu"] = lo_mtu
    for key, label in [
        ("net.ipv4.tcp_congestion_control", "congestion"),
        ("net.core.somaxconn", "somaxconn"),
        ("net.core.rmem_max", "rmem_max"),
        ("net.core.wmem_max", "wmem_max"),
    ]:
        v = sysctl(key)
        if v:
            tcp[label] = v
    if tcp:
        out["tcp"] = tcp

    target = site_data / "current.json"
    target.write_text(json.dumps(out, indent=2))
    print(f"[updated] {target}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parent.parent,
        help="Repository root (default: parent of this script)",
    )
    args = parser.parse_args()
    root = args.root.resolve()
    site_data = root / "site" / "data"
    results_dir = root / "results"

    rebuild_frameworks_json(root, site_data)
    if results_dir.exists():
        merge_results(results_dir, site_data)
    write_current_json(root, site_data)


if __name__ == "__main__":
    main()
