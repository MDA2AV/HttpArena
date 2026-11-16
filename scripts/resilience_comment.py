#!/usr/bin/env python3
"""Markdown for the resilience report comment on a /benchmark PR.

    resilience_comment.py <framework dir>...

Reads results/resilience/<dir>.json (written by scripts/resilience.sh this run)
for each entry named and prints one section per entry that ran the suite — every
attack, its verdict, peak RSS against the cap, liveness during the attack,
recovery after it, and what the attack client saw. Prints nothing when no entry
ran, so the workflow can skip the comment entirely. Reads results/, not
site/data/, so a stale saved copy on the branch is never shown as freshly run.
"""
import json
import os
import sys

VERDICT = {
    "survived":   ("✅", "survived"),
    "degraded":   ("⚠️", "degraded"),
    "hung":       ("🟠", "hung"),
    "crashed":    ("💀", "crashed"),
    "oom-killed": ("💥", "oom-killed"),
    "error":      ("❓", "not measured"),
}


def cell(text):
    return " ".join(str(text if text is not None else "").split()).replace("|", "\\|")


def pct(x):
    return f"{x:g}%" if isinstance(x, (int, float)) else "—"


def entry_section(fw):
    path = os.path.join("results", "resilience", fw + ".json")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        data = json.load(f)
    attacks = data.get("attacks") or {}
    if not attacks:
        return None

    passed = data.get("passed", 0)
    total = data.get("total", len(attacks))
    mark = "✅" if passed == total else "⚠️"
    limit_mb = next((a.get("mem_limit_mb") for a in attacks.values() if a.get("mem_limit_mb")), None)
    box = f"{limit_mb / 1024:g} GiB / 2 CPU" if limit_mb else "a fixed memory/CPU box"

    lines = [f"### {mark} `{data.get('framework', fw)}` — survived {passed}/{total}",
             f"Box: **{box}**, a fresh container per attack.",
             "",
             "| Attack | Exhausts | Verdict | Peak RSS | Liveness fail | Recovery | Client est./reaped |",
             "|---|---|---|---|---|---|---|"]
    for name, a in attacks.items():
        if a.get("verdict") == "error":
            lines.append(f"| `{name}` | — | ❓ {cell(a.get('error', 'not measured'))} | — | — | — | — |")
            continue
        if a.get("verdict") == "no-endpoint":
            lines.append(f"| `{name}` | {cell(a.get('resource'))} | 🔌 no endpoint | — | — | — | — |")
            continue
        emoji, label = VERDICT.get(a["verdict"], ("", a["verdict"]))
        peak, lim = a.get("peak_mem_mb"), a.get("mem_limit_mb")
        if peak is not None and lim:
            peak_cell = f"{peak:g} / {lim:g} MiB"
        elif peak is not None:
            peak_cell = f"{peak:g} MiB"
        else:
            peak_cell = "—"
        rec = a.get("recovery_s")
        rec_cell = f"{rec:g}s" if isinstance(rec, (int, float)) else ("dead" if a["verdict"] in ("hung", "crashed", "oom-killed") else "—")
        c = a.get("client") or {}
        clients = f"{c.get('established', '—')} / {c.get('reaped', '—')}"
        # Flag an attack that never reached the server (wrong port / no endpoint):
        # est 0 + connect errors means the result is "didn't land", not "survived".
        ce = c.get("connect_errors") or 0
        if ce and not c.get("established"):
            clients += f" ⚠️ {ce} no-connect"
        lines.append(f"| `{name}` | {cell(a.get('resource'))} | {emoji} {label} | {peak_cell} | "
                     f"{pct(a.get('liveness_fail_pct'))} | {rec_cell} | {clients} |")

    det = ["<details><summary>What each attack does</summary>", ""]
    for name, a in attacks.items():
        if a.get("description"):
            det.append(f"- **`{name}`** — {cell(a['description'])}")
    det += ["", "</details>"]
    return "\n".join(lines + ["", "\n".join(det)])


def main():
    sections = [s for s in (entry_section(fw) for fw in sys.argv[1:]) if s]
    if not sections:
        return
    legend = ("✅ survived · ⚠️ degraded (shed load, then recovered) · 🟠 hung · "
              "💀 crashed · 💥 OOM-killed · 🔌 no endpoint (entry doesn't implement "
              "the endpoint the attack needs — not scored). A connection the server "
              "**reaped** is the correct defense — a read-timeout or a size cap fired.")
    out = ["## 🛡️ Resilience Report", "",
           "Adversarial load against each opted-in entry in a fixed memory/CPU box — does it "
           "survive, shed load, hang, or run out of memory? Verdicts are not scored into the "
           "composite. See [docs](https://http-arena.com/docs/test-profiles/resilience/).",
           "", legend, "",
           "\n\n".join(sections)]
    body = "\n".join(out)
    if len(body) > 60000:
        body = body[:60000] + "\n\n… (truncated to fit GitHub's comment limit; full verdicts in `site/data/resilience/`)"
    print(body)


if __name__ == "__main__":
    main()
