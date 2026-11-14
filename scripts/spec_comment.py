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
    details = []
    for key, s in suites.items():
        label = f"{LABELS.get(key, key)} (`{key}`)"
        tool = f'{s.get("tool", "")} {s.get("version", "")}'.strip()
        if "error" in s:
            rows.append(f'| {label} | {tool} | not measured | {cell(s["error"])} |')
            continue
        score = f'{s["passed"]} / {s["total"]}'
        listeners = s.get("listeners") or {}
        if len(listeners) > 1:
            parts = [f'{n} {v["passed"]}/{v["total"]}' if "total" in v else f"{n} not measured"
                     for n, v in listeners.items()]
            score += " (" + ", ".join(parts) + ")"
        if s.get("crashed"):
            score += " - **the server crashed during the suite**"
        failed = [f if isinstance(f, dict) else {"id": f} for f in s.get("failed") or []]
        rows.append(f'| {label} | {tool} | {score} | {len(failed)} |')
        if failed:
            details.append(f"<details><summary>{LABELS.get(key, key)}: {len(failed)} failed</summary>\n\n"
                           + failure_table(failed) + "\n\n</details>")

    out = "#### Compliance\n\n" + "\n".join(rows)
    if details:
        out += "\n\n" + "\n\n".join(details)
    print(out)


def cell(text):
    """Text for one cell of a markdown table."""
    return " ".join(str(text or "").split()).replace("|", "\\|")


def failure_table(failed):
    """One row per failed test: what it checks, what was expected, what came back."""
    rows = ["| Test | Expected | Got |", "|---|---|---|"]
    for f in failed:
        tid = cell(f.get("id"))
        test = f"`{tid}`" if " " not in tid else tid
        if f.get("test"):
            test += " " + cell(f["test"])
        ref = ", ".join(x for x in (f.get("rfc"), str(f.get("level") or "").upper()) if x)
        if ref:
            test += f" ({cell(ref)})"
        got = cell(f.get("got")) or "-"
        if f.get("note"):
            got += f" ({cell(f['note'])})"
        rows.append(f"| {test} | {cell(f.get('expected')) or '-'} | {got} |")
    return "\n".join(rows)

if __name__ == "__main__":
    main()
