---
title: Resilience
seo_title: "Resilience: Attacks Against a Capped Entry"
description: "Adversarial HTTP clients — slow-drip bodies, Slowloris headers, oversized chunks, HTTP/2 CONTINUATION floods — run against an entry in a fixed memory/CPU box to see whether it survives, sheds load, hangs, or is OOM-killed."
weight: 7
---

The resilience suite runs adversarial clients against an entry **in a fixed box** — by default 8 GiB of memory and 2 CPUs — and records what happens to the server, not how fast it is. The box is the instrument: an attack that exhausts memory OOM-kills the container, which is a signal we can read, instead of taking the host down. It is **opt-in per entry** and runs as part of a benchmark (see [Opting in](#opting-in)). Nothing here is scored into the composite; it is a separate robustness read, the way the compliance columns are.

Every attack runs against a **fresh capped container** (a crash in one must not cost another its verdict), launched through the same path a benchmark uses — the real entry image, the real mounts — with the memory cap turned on.

## The attacks

**HTTP/1.1 — run against any entry:**

| Attack | Exhausts | What it does | What a hardened server does |
|---|---|---|---|
| `slow-body` | memory | `POST /echo` with a 100 MiB declared `Content-Length`, body dripped ~256 B/s, never finishing | reaps on a body-read-rate timeout, or caps the body size |
| `slow-headers` | connections | an unfinished request whose header block keeps growing, never terminated (Slowloris) | reaps on a header-read timeout or a header-size cap |
| `huge-chunk` | memory | `Transfer-Encoding: chunked` announcing a `0x7fffffffffffffff`-byte chunk | rejects the chunk size instead of pre-allocating it |
| `decompression-bomb` | memory | a small `Content-Encoding: gzip` body that inflates to gigabytes | doesn't decode request bodies unbounded / caps the inflated size |
| `hashdos` | CPU | a form body of tens of thousands of keys | caps the parameter count / uses a seeded hash (SipHash) |
| `json-nesting-bomb` | CPU | a tiny, deeply nested JSON body | caps the parser's recursion depth |
| `multipart-flood` | memory | `multipart/form-data` with tens of thousands of tiny parts | caps the part/field count |
| `redos-headers` | CPU | header values crafted for catastrophic regex backtracking | uses RE2/string parsers, or caps header length |

The last four are **differential**: they only bite a server that actually parses that input (a form/JSON/multipart body, or a regex-based header parser). A minimal benchmark handler that doesn't parse the body is a clean `survived` — which is itself worth recording.

**HTTP/2 — run only when the entry subscribes to an H2 profile** (`baseline-h2`, `static-h2`, `baseline-h2c`, `json-h2c`); over the h2c listener on port 8082:

| Attack | Exhausts | What it does | What a hardened server does |
|---|---|---|---|
| `continuation-flood` | memory | a header block spread over endless `CONTINUATION` frames with no `END_HEADERS` ([CVE-2024-27316](https://nvd.nist.gov/vuln/detail/CVE-2024-27316)) | caps the header-block size, sends `GOAWAY` |
| `hpack-bomb` | memory | one ~4 KB HPACK dynamic-table entry referenced by thousands of 1-byte indices ([CVE-2016-6581](https://nvd.nist.gov/vuln/detail/CVE-2016-6581)) | caps the decoded header-list size |
| `rapid-reset` | CPU | open-then-immediately-`RST` streams in a tight loop ([CVE-2023-44487](https://nvd.nist.gov/vuln/detail/CVE-2023-44487)) | caps concurrent/total streams and in-flight work |
| `madeyoureset` | CPU | force *server-side* `RST` via `WINDOW_UPDATE(0)` per stream ([CVE-2025-8671](https://nvd.nist.gov/vuln/detail/CVE-2025-8671)) | accounts server-sent resets, not just client ones |
| `settings-flood` | CPU | flood `SETTINGS` frames the peer must ACK ([CVE-2019-9515](https://nvd.nist.gov/vuln/detail/CVE-2019-9515)) | rate-limits / bounds the ACK queue |
| `ping-flood` | CPU | flood `PING` frames the peer must ACK ([CVE-2019-9512](https://nvd.nist.gov/vuln/detail/CVE-2019-9512)) | rate-limits / bounds the pong queue |
| `empty-frame-flood` | CPU | flood zero-length `DATA` frames with no `END_STREAM` ([CVE-2019-9518](https://nvd.nist.gov/vuln/detail/CVE-2019-9518)) | caps empty/idle frames per connection |
| `window-stall` | memory | open many streams at a 0 flow-control window and never grant it ([CVE-2019-9517](https://nvd.nist.gov/vuln/detail/CVE-2019-9517)) | times out stalled streams / caps buffered response data |

A connection the server **reaps** (closes on the client) is the *correct* defense — a timeout fired, a cap held. The **memory** attacks produce the cleanest verdict (OOM-kill → exit 137); the **CPU** floods don't OOM, so they surface as `hung`/`degraded` through the liveness probe instead. Many reaped connections with flat memory and green liveness means the server defended itself.

## The verdict

For each attack the runner records a verdict from the server-side signal, plus peak RSS (vs. the idle baseline), the share of liveness probes that failed *during* the attack, and how long the server took to serve again *after* it:

| Verdict | Meaning | Pass |
|---|---|---|
| `survived` | kept answering throughout, no OOM, memory stayed bounded | ✓ |
| `degraded` | stopped answering under load but recovered afterwards | ✓ |
| `hung` | still running but stopped answering and never recovered | ✗ |
| `crashed` | the process died without being OOM-killed (panic/segfault) | ✗ |
| `oom-killed` | the container ran out of its memory box | ✗ |

A liveness probe — a cheap `GET` on port 8080 — runs every second during the attack; recovery is measured by the same probe after the attack client stops. OOM is read straight from the container (`State.OOMKilled` / exit 137), and peak RSS from the cgroup's `memory.peak`.

## Opting in

The suite is **off by default** — the attacks are destructive and need the whole machine. An entry opts in with one flag in its `meta.json`:

```json
"resilience": true
```

On a PR, a full `/benchmark` (no `-t`) then runs the suite for that entry **right after its benchmark**, on the self-hosted bench runner, and `--save` commits the verdicts to `site/data/resilience/<entry>.json` alongside the benchmark results. It rides the benchmark's slot on purpose: the bench host runs one job at a time, so the suite never competes with another run for CPU, memory or ports — contention that would corrupt a verdict. An entry without the flag is skipped.

To run **only** the suite, without a benchmark, comment **`/resilience -f <entry>`** (add `--save` to commit the verdicts). It goes through the same approval and the same bench host as `/benchmark`, builds the image itself, and posts the report as its own comment. Only entries with the flag run; naming one that hasn't opted in is a no-op.

## Running it locally

```bash
./scripts/resilience.sh aspnet-minimal         # opted-in entry: verdicts in results/resilience/<entry>.json
./scripts/resilience.sh aspnet-minimal --save  # and in site/data/resilience/<entry>.json
./scripts/resilience.sh some-entry slow-body   # name attacks to force a run on an entry that hasn't opted in
```

`<entry>` is the directory under `frameworks/`, not the display name — entries that share a display name each keep their own file, the way `site/data/spec/<entry>.json` does. Without the flag and without a named attack, the runner is a no-op.

The box and the run are env-overridable: `RES_MEM` (default `8g`), `RES_CPUSET` (`0-1`), `RES_DURATION` (`60`s), `RES_CONNS` (`4000` slow-attack connections, held below the ~28k ephemeral-port ceiling), `RES_BODY_SIZE` (100 MiB), `RES_DRIP_BYTES` (`256` B per drip), `RES_H2_CONNS` (`256` for the H2 floods), `RES_DECOMP_CONNS` (`64` for the H1 payload/parser floods), `RES_BOMB_SIZE` (1 GiB decompressed), `RES_HASHDOS_KEYS` (`100000`), `RES_JSON_DEPTH` (`100000`), `RES_MULTIPART_PARTS` (`50000`), `RES_REDOS_PAD` (`4000`), `RES_STALL_COUNT`/`RES_STALL_STREAMS` (`5000`/`64`), `RES_RECOVERY` (`15`s). The attack client runs on the load-generator cores so it never steals CPU from the deliberately CPU-starved server.

## The scores

```json
{
  "framework": "aspnet-minimal",
  "dir": "aspnet-minimal",
  "passed": 4,
  "total": 4,
  "attacks": {
    "slow-body": {
      "verdict": "survived",
      "passed": true,
      "resource": "memory",
      "peak_mem_mb": 71.2,
      "baseline_mem_mb": 68.9,
      "mem_limit_mb": 8192,
      "liveness_fail_pct": 0.0,
      "recovery_s": 0.0,
      "oom_killed": false,
      "client": { "established": 1000, "reaped": 1000, "open_at_end": 0 }
    }
  }
}
```

`passed` is the number of attacks the entry survived or only degraded under. The verdicts are not yet shown on the board or folded into the composite score — the suite records them for now, the way the TLS hardening checks did before they earned a badge.
