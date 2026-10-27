#!/usr/bin/env python3
"""Composite score of a framework before and after a benchmark run, for the PR comment.

Reads two site/data directories, main's and the run's, and writes one markdown
table per framework with the score and the rank of each family, in the board's
default view of the framework's league. The numbers come from badge_composite(),
the same port of computeComposite() the badges use.

"After" is main with only the run's frameworks replaced: a run without --save
does not merge main, and the rest of the PR's site/data can be behind it.

    python3 scripts/composite_delta.py <main site/data> <run site/data> <out dir> <framework dir>...

Writes <out dir>/<framework dir>.composite.md, nothing when the framework has no
composite score in any family.
"""

from __future__ import annotations
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_leaderboard_data as g  # noqa: E402


def standings(frameworks, index):
    """{display name: {family: (score, rank, field)}} for every framework in the index."""
    meta = g.build_meta(frameworks)
    # lat_scores() reads the fixed-rate rows from the module's RESULTS and caches them
    g.RESULTS = index
    g._LAT_CACHE.clear()
    profiles, results, _ = g.build_profiles(g.RESULTS)
    agg = g.badge_aggregate(profiles, results)
    fw_lang = g._fw_languages(results)
    out = {}
    for types in g.LEAGUES:
        for scope in g.SCOPE_NAME:
            rows = g.badge_composite(agg, profiles, meta, scope, types, show_tuned=True, fw_lang=fw_lang)
            for rank, (fw, score) in enumerate(rows, 1):
                out.setdefault(fw, {})[scope] = (score, rank, len(rows))
    return out


def replaced(main, run, names):
    """main's rows with the rows of the named frameworks taken from the run."""
    index = {}
    for key in main.keys() | run.keys():
        rows = [r for r in main.get(key, []) if r.get("framework") not in names]
        rows += [r for r in run.get(key, []) if r.get("framework") in names]
        if rows:
            index[key] = sorted(rows, key=lambda r: (r.get("framework") or "").lower())
    return index


def display_name(frameworks, fw_dir):
    for name, m in frameworks.items():
        if m.get("dir") == fw_dir:
            return name
    return fw_dir


def cell(entry):
    if not entry:
        return "-"
    score, rank, field = entry
    return f"{score:.1f} (#{rank} of {field})"


def table(before, after):
    lines = ["**Composite score**, main against this run, in the board's default view:", "",
             "| Family | main | this run | Δ |", "|--------|------|----------|---|"]
    for scope, label in g.SCOPE_NAME.items():
        b, a = before.get(scope), after.get(scope)
        if not b and not a:
            continue
        delta = f"{a[0] - b[0]:+.1f}" if a and b else "-"
        lines.append(f"| {label} | {cell(b)} | {cell(a)} | {delta} |")
    lines += ["", "_The results on main were measured in another session, so a few points up or down "
                  "can be the machine and not the change._"]
    return "\n".join(lines)


def main():
    main_data, run_data, out_dir = (Path(a) for a in sys.argv[1:4])
    main_fws = g.load("frameworks.json", main_data) or {}
    run_fws = g.load("frameworks.json", run_data) or {}
    names = {display_name(run_fws, d) for d in sys.argv[4:]}
    main_index = g.load_results(main_data)
    before = standings(main_fws, main_index)
    after_fws = {n: m for n, m in main_fws.items() if n not in names}
    after_fws.update({n: m for n, m in run_fws.items() if n in names})
    after = standings(after_fws, replaced(main_index, g.load_results(run_data), names))
    out_dir.mkdir(parents=True, exist_ok=True)
    for fw_dir in sys.argv[4:]:
        name = display_name(run_fws, fw_dir)
        if name in before or name in after:
            (out_dir / f"{fw_dir}.composite.md").write_text(
                table(before.get(name, {}), after.get(name, {})) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
