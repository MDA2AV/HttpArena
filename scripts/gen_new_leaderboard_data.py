#!/usr/bin/env python3
"""Generate site/static/new-leaderboard/data.js from site/data/*.json.

The "new leaderboard" is a standalone static page (plain HTML/CSS/JS, no Hugo
templating). This script reads the same per-profile result files the Hugo
leaderboard consumes and emits a single `window.LB_DATA = {...}` blob the page
renders client-side — both the per-profile explorer and the composite ranking.

The composite mirrors the canonical board: it averages RPS over each profile's
*scored* connection set, applies per-type profile eligibility, and carries the
tpl_*/bandwidth fields needed for the api-4/api-16 (template mix) and json-comp
(compression-ratio) adjustments.

Run after scripts/rebuild_site_data.py (or any time site/data changes):
    python3 scripts/gen_new_leaderboard_data.py
"""

from __future__ import annotations
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "site" / "data"
OUT = ROOT / "site" / "static" / "new-leaderboard" / "data.js"

# Benchmark catalog. Each profile:
#   id, label, category, blurb,
#   explorer:  conn counts shown in the explorer (all useful runs),
#   scored:    conn counts that feed the composite (canonical scored set),
#   s/es/is:   scored / engineScored / infraScored eligibility flags.
# scored conns are always a subset of explorer conns.
CATALOG = [
    ("Connection", [
        ("baseline",     "Baseline",    "Mixed GET/POST with query parsing.",       [512,4096,16384],[512,4096], True,True,True),
        ("pipelined",    "Pipelined",   "16x batched HTTP/1.1 pipelining.",         [512,4096,16384],[512,4096], True,True,True),
        ("limited-conn", "Short-lived", "Connections close after 10 requests.",     [512,4096],      [512,4096], True,True,True),
    ]),
    ("Workload", [
        ("json",      "JSON",            "Per-request JSON serialization.",          [4096],              [4096],          True,False,False),
        ("json-comp", "JSON Compressed", "gzip/brotli content negotiation.",         [512,4096,16384],    [512,4096,16384],True,False,False),
        ("json-tls",  "JSON TLS",        "JSON over HTTP/1.1 + TLS.",                [4096],              [4096],          True,False,False),
        ("upload",    "Upload",          "Large request-body ingestion.",            [32,64,256,512],     [32,256],        True,False,False),
        ("static",    "Static",          "20-file static asset serving.",            [1024,4096,6800,16384],[1024,4096,6800],True,False,True),
    ]),
    ("Database", [
        ("async-db",  "Async DB",  "Async Postgres sequential scan.",                [1024],     [1024],  True,False,False),
        ("crud",      "CRUD",      "REST API: list, cached read, upsert, update.",   [512,4096], [4096],  True,False,False),
        ("fortunes",  "Fortunes",  "DB query + HTML template render (reference).",    [1024],     [1024],  False,False,False),
    ]),
    ("Multi-endpoint", [
        ("api-4",  "API · 4 CPU",  "Mixed workload, server capped at 4 CPUs.",       [256],  [256],  True,True,False),
        ("api-16", "API · 16 CPU", "Mixed workload, server capped at 16 CPUs.",      [1024], [1024], True,False,False),
    ]),
    ("HTTP/2", [
        ("baseline-h2",  "Baseline",       "Baseline over h2 (TLS, ALPN).",          [256,1024],     [256,1024],     True,True,False),
        ("static-h2",    "Static",         "Static assets over h2 multiplexing.",    [256,1024],     [256,1024],     True,True,False),
        ("baseline-h2c", "Baseline (h2c)", "Baseline over cleartext h2.",            [256,1024,4096],[256,1024,4096],True,True,False),
        ("json-h2c",     "JSON (h2c)",     "JSON over cleartext h2.",                [1024,4096],    [1024,4096],    True,False,False),
    ]),
    ("HTTP/3", [
        ("baseline-h3", "Baseline", "Baseline over QUIC + TLS 1.3.",                 [64], [64], True,True,False),
        ("static-h3",   "Static",   "Static assets over QUIC.",                      [64], [64], True,True,False),
    ]),
    ("gRPC", [
        ("unary-grpc",     "Unary",     "Unary gRPC over plaintext h2.",             [256,1024],[256,1024],True,True,False),
        ("unary-grpc-tls", "Unary TLS", "Unary gRPC over TLS.",                      [256,1024],[256,1024],True,True,False),
        ("stream-grpc",    "Stream",    "Server-streaming gRPC, plaintext.",         [64],      [64],      True,True,False),
        ("stream-grpc-tls","Stream TLS","Server-streaming gRPC over TLS.",           [64],      [64],      True,True,False),
    ]),
    ("Gateway", [
        ("gateway-64", "Gateway (H2)", "Reverse proxy + server, mixed h2.",          [256,512,1024],[512,1024],True,True,False),
        ("gateway-h3", "Gateway (H3)", "Reverse proxy + server over h3.",            [64,256],      [64,256],  True,True,False),
        ("production-stack", "Production Stack", "Edge + Redis + JWT auth + server.",[256,1024],[256,1024],True,True,False),
    ]),
    ("WebSocket", [
        ("echo-ws",          "Echo",           "WebSocket echo throughput.",         [512,4096,16384],[512,4096,16384],True,True,False),
        ("echo-ws-pipeline", "Echo Pipelined", "Batched WebSocket echo.",            [512,4096,16384],[512,4096,16384],True,True,False),
    ]),
]

# Fields kept per result row. tpl_* only emitted when present (api/gateway/prod).
BASE_FIELDS = ("rps", "avg_latency", "p99_latency", "cpu", "memory", "bandwidth", "input_bw",
               "status_2xx", "status_3xx", "status_4xx", "status_5xx")
TPL_FIELDS = ("tpl_baseline", "tpl_json", "tpl_upload", "tpl_static", "tpl_async_db")


def load(name):
    p = DATA / name
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except Exception as e:
        print(f"[warn] {name}: {e}")
        return None


def main():
    frameworks = load("frameworks.json") or {}
    langcolors = load("langcolors.json") or {}
    current = load("current.json") or {}

    meta = {n: {"type": m.get("type", "production"),
                "language": m.get("language", ""),
                "repo": m.get("repo", ""),
                "dir": m.get("dir", ""),
                "engine": m.get("engine", ""),
                "desc": m.get("description", "")} for n, m in frameworks.items()}

    profiles, results = [], {}
    for category, entries in CATALOG:
        for pid, label, blurb, explorer, scored, s, es, isc in entries:
            present = []
            for c in explorer:
                rows = load(f"{pid}-{c}.json")
                if not rows:
                    continue
                trimmed = []
                for r in rows:
                    fw = r.get("framework")
                    if not fw:
                        continue
                    row = {"fw": fw, "lang": r.get("language", "")}
                    for f in BASE_FIELDS:
                        row[f] = r.get(f)
                    for f in TPL_FIELDS:
                        if r.get(f):
                            row[f] = r.get(f)
                    trimmed.append(row)
                if trimmed:
                    results[f"{pid}-{c}"] = trimmed
                    present.append(c)
            if present:
                profiles.append({
                    "id": pid, "label": label, "category": category, "blurb": blurb,
                    "conns": present,
                    "scoredConns": [c for c in scored if c in present],
                    "scored": s, "engineScored": es, "infraScored": isc,
                })

    payload = {"current": current, "langColors": langcolors, "meta": meta,
               "profiles": profiles, "results": results}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("window.LB_DATA = " + json.dumps(payload, separators=(",", ":")) + ";\n")
    n_rows = sum(len(v) for v in results.values())
    print(f"wrote {OUT.relative_to(ROOT)} — {len(profiles)} profiles, "
          f"{len(results)} views, {n_rows} rows, {OUT.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
