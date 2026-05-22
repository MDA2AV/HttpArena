#!/usr/bin/env python3
"""
Rebuild site/data/*.json from results/<profile>/<conns>/<framework>.json files.

Writes:
  site/data/frameworks.json    — hybrid map of {display_name: {dir, description, ..., variants?}}
  site/data/<profile>-<conns>.json  — merged per-profile-per-conn result arrays
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
import subprocess
import sys
from pathlib import Path


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
            "type": m.get("type", "realistic"),
            "engine": m.get("engine", ""),
        }
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


def merge_results(results_dir: Path, site_data: Path) -> None:
    """For each results/<profile>/<conns>/ directory, merge the per-framework
    JSON files with any existing entries in site/data/<profile>-<conns>.json.

    Rules:
      * New results always replace existing entries with the same framework name
      * Existing entries for frameworks not in the current run are preserved
      * Deduplicate by framework name, keeping the highest rps
      * Sort alphabetically by framework name
    """
    for profile_dir in sorted(results_dir.iterdir()):
        if not profile_dir.is_dir():
            continue
        profile = profile_dir.name
        for conn_dir in sorted(profile_dir.iterdir()):
            if not conn_dir.is_dir():
                continue
            conns = conn_dir.name
            data_file = site_data / f"{profile}-{conns}.json"

            new_entries: dict[str, dict] = {}
            for f in sorted(conn_dir.glob("*.json")):
                try:
                    entry = json.load(open(f))
                    new_entries[entry.get("framework", "")] = entry
                except Exception as e:
                    print(f"[warn] skipping {f}: {e}", file=sys.stderr)

            existing: list[dict] = []
            if data_file.exists():
                try:
                    existing = json.load(open(data_file))
                except Exception:
                    existing = []

            # Start from existing entries whose framework name isn't in the new batch,
            # then add every new entry.
            merged = [e for e in existing if e.get("framework", "") not in new_entries]
            merged.extend(new_entries.values())

            # Dedup by framework name, keeping the one with the highest rps.
            by_name: dict[str, dict] = {}
            for e in merged:
                name = e.get("framework", "")
                if name not in by_name or e.get("rps", 0) > by_name[name].get("rps", 0):
                    by_name[name] = e

            final = sorted(by_name.values(), key=lambda e: e.get("framework", "").lower())
            data_file.write_text(json.dumps(final, indent=2))
            print(f"[updated] {data_file}")


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
    # at archive time; the displayed badge for the "current" round is hidden
    # in round-selector.html when the field is absent.
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
