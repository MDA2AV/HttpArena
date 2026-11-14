#!/usr/bin/env python3
"""Turn the raw output of the compliance suites into an entry's scores.

    spec_results.py <work dir> <display name> <entry dir> <suite>...

Reads what scripts/spec.sh left in <work dir> and prints the JSON it writes to
results/spec/<entry dir>.json (and, with --save, site/data/spec/<entry dir>.json).
The tool versions come from SPEC_VERSION_H1, _H2, _H3 and _WS in the environment.

Per suite: "passed" out of "total", and in "failed" one record per failed test
with what the tool expected and what the server did - enough to see why without
the raw output, which stays on the machine that ran the suite:

    {"id", "test": what it checks, "expected", "got", and where the tool says
     so "rfc", "level" (MUST/SHOULD...) and "note"}

A suite that could not be measured has "error" instead of a score, and one
whose server died part-way has "crashed": true - the tests it could no longer
answer are counted as failed. File format: site/content/docs/test-profiles/compliance/.
"""
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

TOOLS = {"h1": "http11probe", "h2": "h2spec", "h3": "h3spec", "ws": "autobahn-testsuite"}
OK_VERDICTS = {"Pass", "Warn"}                          # Http11Probe: Warn means the RFC allows both
OK_BEHAVIOURS = {"OK", "NON-STRICT", "INFORMATIONAL"}   # Autobahn's passing outcomes


def read(path):
    with open(path, errors="replace") as f:
        return f.read()


def clip(text, n=300):
    text = " ".join(str(text or "").split())
    return text if len(text) <= n else text[:n - 3] + "..."


H1_STATES = {"ClosedByServer": "connection closed", "Open": "connection left open",
             "TimedOut": "timed out", "Error": "connection error"}


def h1_got(r):
    """What the server did, from the probe's own fields: status, connection, error."""
    state = H1_STATES.get(r.get("connectionState"), str(r.get("connectionState") or "").lower())
    status = r.get("statusCode")
    got = (str(status) if status not in (None, "") else "no response") + (", " + state if state else "")
    if r.get("error"):
        got += " (" + clip(r["error"], 120) + ")"
    return got


def h1(work):
    path = os.path.join(work, "h1.json")
    if not os.path.exists(path):
        return None, "the probe wrote no report"
    scored = [r for r in json.loads(read(path))["results"] if r.get("scored")]
    if not scored:
        return None, "the probe reported no scored tests"
    return {
        "passed": sum(r["verdict"] in OK_VERDICTS for r in scored),
        "total": len(scored),
        "warnings": sum(r["verdict"] == "Warn" for r in scored),
        "failed": [dict({"id": r["id"], "test": clip(r.get("description"), 160),
                         "expected": clip(r.get("expected"), 120), "got": h1_got(r)},
                        **{k: clip(r[f], 160) for k, f in (("rfc", "rfcReference"), ("level", "rfcLevel"),
                                                           ("note", "behavioralNote")) if r.get(f)})
                   for r in scored if r["verdict"] not in OK_VERDICTS],
    }, None


def h2_listener(path):
    """One h2spec JUnit report. Failures are <error> elements, whose text lists
    what h2spec would have accepted, one per line, and then what arrived. IDs
    follow h2spec's own numbering, <section>/<position in that section>."""
    passed, total, failed = 0, 0, []
    for suite in ET.fromstring(read(path)).iter("testsuite"):
        for i, case in enumerate(suite.iter("testcase"), 1):
            if case.find("skipped") is not None:
                continue
            total += 1
            error = case.find("error") if case.find("error") is not None else case.find("failure")
            if error is not None:
                lines = [ln.strip() for ln in (error.text or "").strip().splitlines() if ln.strip()]
                failed.append({"id": f'{case.get("package")}/{i}', "test": clip(case.get("classname"), 160),
                               "expected": clip(" or ".join(lines[:-1]), 200),
                               "got": clip(lines[-1] if lines else "", 200)})
            else:
                passed += 1
    return {"passed": passed, "total": total, "failed": failed}


def h2(work):
    listeners = {}
    for name in ("tls", "h2c"):
        path = os.path.join(work, f"h2-{name}.xml")
        log = os.path.join(work, f"h2-{name}.log")
        if os.path.exists(path):
            listeners[name] = h2_listener(path)
        elif os.path.exists(log):
            last = (read(log).strip().splitlines() or ["h2spec wrote no report"])[-1]
            listeners[name] = {"error": last[:200]}
    measured = [v for v in listeners.values() if v.get("total")]
    if not measured:
        return None, "no HTTP/2 listener could be tested"
    # The column shows the weaker listener; both stay in the file.
    worst = min(measured, key=lambda v: v["passed"] / v["total"])
    return dict(worst, listeners=listeners), None


def h3(work):
    path = os.path.join(work, "h3.txt")
    if not os.path.exists(path):
        return None, "h3spec produced no output"
    text = read(path)
    summary = re.findall(r"(\d+) examples?, (\d+) failures?(?:, (\d+) pending)?", text)
    if not summary:
        tail = (text.strip().splitlines() or ["h3spec printed nothing"])[-1]
        return None, "h3spec printed no summary: " + tail[:200]
    examples, failures, pending = (int(x or 0) for x in summary[-1])
    # Each failure: "  N) <requirement>", then the lines saying what happened,
    # then "To rerun use: ...". The requirement is the test, and what h3spec
    # expected is in its wording ("MUST send TRANSPORT_PARAMETER_ERROR if ...").
    failed, cur = [], None
    for line in (text.split("Failures:", 1)[1] if "Failures:" in text else "").splitlines():
        m = re.match(r"^  \d+\) (.+?)\s*$", line)
        if m:
            cur = {"id": clip(m.group(1), 200), "got": []}
            failed.append(cur)
            continue
        s = line.strip()
        if cur is None or not s or re.match(r"^\S+\.hs:\d+:\d+:", s):
            continue
        if s.startswith("To rerun use"):
            cur = None
            continue
        cur["got"].append(s)
    failed = [{"id": f["id"], "got": clip(" / ".join(f["got"]), 200)} for f in failed]
    # Pending tests are ones h3spec could not set up (0-RTT, extra streams),
    # so they are neither passed nor failed.
    total = examples - pending
    return {"passed": total - failures, "total": total, "failed": failed}, None


def ws(work):
    reports = os.path.join(work, "ws", "reports")
    path = os.path.join(reports, "index.json")
    if not os.path.exists(path):
        return None, "Autobahn wrote no report"
    every = next(iter(json.loads(read(path)).values()), {})
    if not every:
        return None, "Autobahn ran no case"

    def report(case):
        p = os.path.join(reports, every[case].get("reportfile", ""))
        return json.loads(read(p)) if os.path.isfile(p) else {}

    # A handshake refused on every case - a 404 on /ws, say - means nothing
    # about WebSocket was tested: not measured, rather than a score of 0.
    if all("never completed" in (report(c).get("resultClose") or "") for c in every):
        first = report(next(iter(every)))
        status = ((first.get("httpResponse") or "").splitlines() or ["no response"])[0].strip()
        return None, "the WebSocket handshake never completed (" + status + ")"

    # INFORMATIONAL cases make no judgement and UNIMPLEMENTED ones test an
    # extension the entry does not offer; like h3spec's pending tests, they are
    # neither passed nor failed. Which cases they are is fixed by the suite.
    cases = {k: v for k, v in every.items() if v.get("behavior") not in ("INFORMATIONAL", "UNIMPLEMENTED")}

    def key(case):
        return [int(x) for x in case.split(".")]

    failed = []
    for c in sorted((c for c, v in cases.items()
                     if v.get("behavior") not in OK_BEHAVIOURS or v.get("behaviorClose") not in OK_BEHAVIOURS),
                    key=key):
        rep_ = report(c)
        got = rep_.get("result") or every[c].get("behavior", "")
        if every[c].get("behaviorClose") not in OK_BEHAVIOURS and rep_.get("resultClose"):
            got += " / close: " + rep_["resultClose"]
        failed.append({"id": c, "test": clip(rep_.get("description"), 160),
                       "expected": clip(rep_.get("expectation"), 200), "got": clip(got, 200)})
    return {
        "passed": len(cases) - len(failed),
        "total": len(cases),
        "non_strict": sum(v.get("behavior") == "NON-STRICT" for v in cases.values()),
        "failed": failed,
    }, None


PARSERS = {"h1": h1, "h2": h2, "h3": h3, "ws": ws}


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    work, display, entry_dir, suites = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    out = {"framework": display, "dir": entry_dir, "suites": {}}
    for suite in suites:
        entry = {"tool": TOOLS[suite], "version": os.environ.get("SPEC_VERSION_" + suite.upper(), "")}
        status_path = os.path.join(work, suite + ".status")
        status = read(status_path).strip() if os.path.exists(status_path) else "error: the suite did not run"
        if status.startswith("error:"):
            entry["error"] = status[len("error:"):].strip()
        else:
            score, error = PARSERS[suite](work)
            if error:
                entry["error"] = error
            else:
                entry.update(score)
                if status == "crashed":
                    entry["crashed"] = True
        out["suites"][suite] = entry
        if "error" in entry:
            line = "not measured - " + entry["error"]
        else:
            line = f'{entry["passed"]}/{entry["total"]} ({len(entry["failed"])} failed)'
            if entry.get("crashed"):
                line += " - the server crashed during the suite"
        print(f'[spec] {suite}  {entry["tool"]} {entry["version"]}: {line}', file=sys.stderr)
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
