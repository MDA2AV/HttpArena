#!/usr/bin/env python3
"""Turn the raw per-attack data from scripts/resilience.sh into an entry's
resilience scores.

    resilience_results.py <work dir> <display name> <entry dir> <attack>...

Reads results/resilience/<entry dir>/<attack>.result.json (written by the
runner) and prints the JSON for results/resilience/<entry dir>.json (and, with
--save, site/data/resilience/<entry dir>.json).

Each attack gets a verdict from the server-side signal:

    oom-killed  the container was OOM-killed (ran out of the memory box) — fail
    crashed     the process died without being OOM-killed (panic/segfault) — fail
    hung        still running but stopped answering and never recovered — fail
    degraded    stopped answering under load but recovered afterwards — pass (warn)
    survived    kept answering throughout, no OOM, memory stayed bounded — pass

plus peak RSS vs the idle baseline, the fraction of liveness probes that failed
during the attack, recovery time, and what the attack client did. "passed" is
true for survived/degraded. File format mirrors the compliance suite's
site/data/spec/<dir>.json.
"""
import json
import os
import sys

# What each attack is trying to exhaust, for the report.
RESOURCE = {
    "slow-body": ("memory", "Drip a large declared body one byte at a time; "
                            "tests the body-read timeout / whole-body buffering."),
    "slow-headers": ("connections", "Hold connections with an unfinished, ever-growing "
                                    "header block; tests header-read timeout / caps."),
    "huge-chunk": ("memory", "Announce a 0x7fffffffffffffff-byte chunk; tests whether "
                            "the server pre-allocates the declared chunk buffer."),
    "continuation-flood": ("memory", "Endless HTTP/2 CONTINUATION frames with no "
                                     "END_HEADERS (CVE-2024-27316); tests the header-block cap."),
    "decompression-bomb": ("memory", "A small gzip request body that inflates to gigabytes; "
                                     "tests whether request Content-Encoding is decoded unbounded."),
    "hpack-bomb": ("memory", "One ~4 KB HPACK dynamic-table entry referenced by thousands of "
                            "1-byte indices (CVE-2016-6581 family); tests header-list size caps."),
    "rapid-reset": ("cpu", "Open-then-immediately-RST streams in a tight loop "
                          "(CVE-2023-44487); tests unbounded stream dispatch."),
    "madeyoureset": ("cpu", "Force server-side RST via WINDOW_UPDATE(0) per stream "
                           "(CVE-2025-8671); tests the Rapid-Reset-mitigation bypass."),
    "settings-flood": ("cpu", "Flood SETTINGS frames the peer must ACK (CVE-2019-9515)."),
    "ping-flood": ("cpu", "Flood PING frames the peer must ACK (CVE-2019-9512)."),
    "empty-frame-flood": ("cpu", "Flood zero-length DATA frames with no END_STREAM "
                                 "(CVE-2019-9518); tests per-frame overhead handling."),
    "window-stall": ("memory", "Open many streams at a 0 flow-control window and never "
                              "grant it (CVE-2019-9517); tests stalled-stream buffering/timeouts."),
    "hashdos": ("cpu", "A form body of many keys; tests whether the body is parsed into an "
                      "un-seeded hash map (O(n^2), CVE-2011-3414 era)."),
    "json-nesting-bomb": ("cpu", "A tiny, deeply nested JSON body; tests the recursion-depth "
                                 "cap of the request-body parser (stack overflow -> crash)."),
    "multipart-flood": ("memory", "multipart/form-data with tens of thousands of tiny parts; "
                                  "tests the part/field-count cap."),
    "redos-headers": ("cpu", "Header values crafted for catastrophic regex backtracking; tests "
                            "the header parsers (Accept/Content-Disposition/Range)."),
    "slow-read": ("memory", "Request a large response then read it ~1 byte/sec; tests the "
                           "send/write timeout and response buffering."),
    "large-upload": ("memory", "A huge uncompressed body delivered fast; tests whole-body "
                              "buffering and the max-body-size cap."),
    "keepalive-hoard": ("connections", "Many complete keep-alive requests held idle; tests the "
                                       "idle-timeout and max-connection caps."),
    "content-length-prealloc": ("memory", "Declare a huge Content-Length and send no body; tests "
                                          "whether the read buffer is sized from the declared length (CVE-2026-5440)."),
    "expect-100-continue": ("memory", "Expect: 100-continue + a large Content-Length, body withheld; "
                                      "tests buffer reservation on the 100-continue handshake (CVE-2020-10705)."),
    "chunk-size-overflow": ("cpu", "A chunk-size near 2**64; tests whether chunk-size arithmetic "
                                   "overflows and crashes the parser."),
    "trailer-flood": ("memory", "A chunked body followed by an unbounded trailer section; tests the "
                               "trailer-count cap, a header-limit blind spot (CVE-2026-22815 era)."),
    "chunk-extension-flood": ("cpu", "1-byte chunks each carrying a huge chunk-extension; tests "
                                     "read-amplification in the chunk parser (CVE-2023-39326)."),
    "tiny-chunk-flood": ("cpu", "A chunked body of millions of 1-byte chunks; tests per-chunk "
                               "framing/dechunk overhead."),
    "header-bomb": ("memory", "One complete request with a single enormous header value; tests the "
                             "per-field / total header size cap."),
    "header-count-flood": ("memory", "Very many tiny distinct header fields; tests the header-COUNT "
                                     "cap (CVE-2026-28980 era)."),
    "duplicate-header-merge": ("cpu", "The same header name repeated N times; tests whether duplicates "
                                      "are joined with O(n^2) concatenation before dispatch."),
    "pipelining-flood": ("memory", "Thousands of pipelined requests on one socket, responses unread; "
                                   "tests whether the inbound queue is bounded (CVE-2026-54273)."),
    "decomp-codec-bypass": ("memory", "A deflate bomb labelled Content-Encoding: deflate; tests whether "
                                      "non-gzip request codecs are decoded unbounded (CVE-2026-42587 era)."),
    "qvalue-cpu-bomb": ("cpu", "A huge Accept-Language list; tests O(n^2) q-value sorting before "
                              "dispatch (CVE-2020-27223)."),
    "cookie-flood": ("memory", "One Cookie header of many tiny pairs under the byte cap; tests the "
                              "cookie-COUNT cap (CVE-2025-58186)."),
    "percent-decode-quadratic": ("cpu", "A path of many percent-encoded tokens; tests super-linear "
                                        "percent-decoding in the router (CVE-2026-45822)."),
    "range-bomb": ("memory", "Many overlapping byte ranges on a static file; tests multipart/byteranges "
                            "response amplification (Apache-Killer, CVE-2011-3192)."),
    "json-bignum": ("cpu", "A single gigantic JSON numeric literal; tests arbitrary-precision number "
                          "parsing (BigDecimal / quadratic int, CVE-2023-4043)."),
    "ws-giant-frame": ("memory", "A WebSocket frame header declaring a 2**63 payload length; tests "
                                 "receive-buffer pre-allocation from the declared length."),
    "ws-fragment-bomb": ("memory", "Endless WebSocket continuation frames with no FIN; tests the "
                                   "fragment-aggregation cap (CVE-2026-48779)."),
    "ws-deflate-bomb": ("memory", "A permessage-deflate frame that inflates to gigabytes; tests the "
                                  "inflated-message cap (CVE-2026-1526 era)."),
    "ws-pong-flood": ("memory", "Flood PING frames, never read; tests whether the auto-PONG queue is "
                               "bounded (CVE-2026-109932)."),
    "tls-handshake-flood": ("cpu", "Many full TLS handshakes; the server pays the asymmetric crypto "
                                   "each time (THC-SSL-DOS class)."),
    "dheat": ("cpu", "Offer only DHE and flood handshakes; forces a modular exponentiation per "
                    "handshake, or reports immune if no DHE is offered (CVE-2002-20001)."),
}

LIVENESS_FAIL_THRESHOLD = 0.5   # over half the probes failing = "stopped answering"


def mem_limit_mb(s):
    s = str(s).strip().lower()
    try:
        if s.endswith("g"):
            return int(float(s[:-1]) * 1024)
        if s.endswith("m"):
            return int(float(s[:-1]))
        if s.endswith("k"):
            return int(float(s[:-1]) / 1024)
        return int(int(s) / (1024 * 1024))
    except ValueError:
        return None


def classify(r):
    """verdict, passed from one attack's raw result record. passed is None for a
    verdict that is neither pass nor fail (the target doesn't implement the
    endpoint the attack needs), so it drops out of the pass/total count."""
    if r.get("verdict") == "error":
        return "error", False
    if (r.get("client") or {}).get("endpoint_missing"):
        return "no-endpoint", None
    if r.get("oom_killed") or r.get("exit_code") == 137:
        return "oom-killed", False
    if not r.get("running"):
        return "crashed", False
    total = r.get("liveness_total") or 0
    ok = r.get("liveness_ok") or 0
    fail_frac = (total - ok) / total if total else 0.0
    if fail_frac > LIVENESS_FAIL_THRESHOLD:
        if r.get("recovery") == "dead":
            return "hung", False
        return "degraded", True
    return "survived", True


def score_attack(r):
    verdict, passed = classify(r)
    if verdict == "error":
        return {"verdict": "error", "error": r.get("error", "could not measure"),
                "passed": False}
    if verdict == "no-endpoint":
        resource, desc = RESOURCE.get(r["attack"], ("", ""))
        return {"verdict": "no-endpoint", "passed": None, "resource": resource,
                "description": desc,
                "note": "the entry does not implement the endpoint this attack needs"}
    total = r.get("liveness_total") or 0
    ok = r.get("liveness_ok") or 0
    fail_pct = round(100 * (total - ok) / total, 1) if total else 0.0
    resource, desc = RESOURCE.get(r["attack"], ("", ""))
    recovery = r.get("recovery")
    limit_mb = mem_limit_mb(r.get("mem_limit"))
    peak_mb = round(r.get("peak_mem", 0) / (1024 * 1024), 1)
    # An OOM-killed container's cgroup is gone by the time we read memory.peak, so
    # the sampler's last value can undercount. By definition it reached the cap.
    if verdict == "oom-killed" and limit_mb and peak_mb < limit_mb:
        peak_mb = float(limit_mb)
    # Offered load: the client's own frames/elapsed. Meaningful for the floods;
    # the slow/hold attacks report 0 frames (their pressure is held connections).
    _cl = r.get("client") or {}
    _fr, _el = _cl.get("frames_sent") or 0, _cl.get("elapsed_s") or 0
    rps = round(_fr / _el) if (_fr and _el) else None
    out = {
        "verdict": verdict,
        "passed": passed,
        "resource": resource,
        "description": desc,
        "peak_mem_mb": peak_mb,
        "baseline_mem_mb": round(r.get("baseline_mem", 0) / (1024 * 1024), 1),
        "mem_limit_mb": limit_mb,
        "liveness_fail_pct": fail_pct,
        "recovery_s": None if recovery == "dead" else _num(recovery),
        "oom_killed": bool(r.get("oom_killed")),
        "exit_code": r.get("exit_code"),
        "duration_s": r.get("duration_s"),
        "rps": rps,
        "client_cpu_cores": r.get("client_cpu_cores"),
        "server_cpu_cores": r.get("server_cpu_cores"),
    }
    client = r.get("client") or {}
    # A server that reaped most of our connections defended itself; surface it.
    if client:
        out["client"] = {k: client[k] for k in
                         ("established", "reaped", "open_at_end", "frames_sent",
                          "drip_sent_bytes", "connect_errors")
                         if k in client}
    return out


def _num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def main():
    work, display, entry = sys.argv[1], sys.argv[2], sys.argv[3]
    attacks = sys.argv[4:]

    scored = {}
    for name in attacks:
        path = os.path.join(work, f"{name}.result.json")
        if not os.path.exists(path):
            scored[name] = {"verdict": "error", "passed": False,
                            "error": "the runner wrote no result"}
            continue
        with open(path) as f:
            scored[name] = score_attack(json.load(f))

    # no-endpoint attacks have passed=None — not a pass, not a fail, not counted.
    passed = sum(1 for a in scored.values() if a.get("passed") is True)
    result = {
        "framework": display,
        "dir": entry,
        "passed": passed,
        "total": sum(1 for a in scored.values() if a.get("passed") is not None),
        "attacks": scored,
        "tool": {"driver": "resilience/attack.py"},
    }
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
