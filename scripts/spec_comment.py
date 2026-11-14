#!/usr/bin/env python3
"""Markdown for one entry's compliance scores, for the /benchmark and /spec
result comments.

    spec_comment.py <framework dir>

Reads results/spec/<framework dir>.json, which scripts/spec.sh wrote during
this run, rather than site/data/spec/: a PR branch can carry an older saved
copy, and that must not be shown as if it had just been measured. Prints
nothing when the entry ran no suite.
"""
import json
import os
import sys

LABELS = {"h1": "H/1.1", "h2": "H/2", "h3": "H/3", "ws": "WebSocket"}


def main():
    fw = sys.argv[1]
    path = os.path.join("results", "spec", fw + ".json")
    if not os.path.exists(path):
        return
    with open(path) as f:
        suites = json.load(f).get("suites", {})
    if not suites:
        return

    rows = ["| Suite | Tool | Score | Failed |", "|---|---|---|---|"]
    failed_lists = []
    for key, s in suites.items():
        label = f"{LABELS.get(key, key)} (`{key}`)"
        tool = f'{s.get("tool", "")} {s.get("version", "")}'.strip()
        if "error" in s:
            rows.append(f'| {label} | {tool} | not measured | {s["error"]} |')
            continue
        score = f'{s["passed"]} / {s["total"]}'
        listeners = s.get("listeners") or {}
        if len(listeners) > 1:
            parts = [f'{n} {v["passed"]}/{v["total"]}' if "total" in v else f"{n} not measured"
                     for n, v in listeners.items()]
            score += " (" + ", ".join(parts) + ")"
        if s.get("crashed"):
            score += " - **the server crashed during the suite**"
        rows.append(f'| {label} | {tool} | {score} | {len(s["failed"])} |')
        if s["failed"]:
            failed_lists.append(f"**{LABELS.get(key, key)}:** " + ", ".join(f"`{t}`" for t in s["failed"]))

    out = "#### Compliance\n\n" + "\n".join(rows)
    if failed_lists:
        out += "\n\n<details><summary>Failed tests</summary>\n\n" + "\n\n".join(failed_lists) + "\n</details>"
    print(out)


if __name__ == "__main__":
    main()
