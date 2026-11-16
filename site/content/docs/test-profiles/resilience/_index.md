---
title: Resilience
seo_title: "Resilience: Attacks Against a Capped Entry"
description: "Adversarial HTTP clients — slow-drip bodies, Slowloris headers, oversized chunks, HTTP/2 CONTINUATION floods — run against an entry in a fixed memory/CPU box to see whether it survives, sheds load, hangs, or is OOM-killed."
weight: 7
---

The resilience suite runs adversarial clients against an entry **in a fixed box** — by default 4 GiB of memory and 2 CPUs — and records what happens to the server, not how fast it is. The box is the instrument: an attack that exhausts memory OOM-kills the container, which is a signal we can read, instead of taking the host down. It is **opt-in per entry** and runs as part of a benchmark (see [Opting in](#opting-in)). Nothing here is scored into the composite; it is a separate robustness read, the way the compliance columns are.

Every attack runs against a **fresh capped container** (a crash in one must not cost another its verdict), launched through the same path a benchmark uses — the real entry image, the real mounts — with the memory cap turned on.

## The attacks

The suite has **41 attacks** across four protocol surfaces. The most valuable for this benchmark are the **server-level** ones that fire regardless of what the handler does — most entries are minimal handlers that never parse the body, so **parser-differential** attacks (marked below) mostly read `survived` on them, which is itself a recordable result.

**HTTP/1.1 server-level — fire against any entry:**

| Attack | Exhausts | What it does |
|---|---|---|
| `slow-body` | memory | `POST /echo`, 100 MiB declared `Content-Length`, body dripped ~256 B/s |
| `slow-headers` | connections | Slowloris — an unfinished, ever-growing header block |
| `slow-read` | memory | request a large response, read it ~1 B/s (read-side Slowloris) |
| `keepalive-hoard` | connections | many complete keep-alive requests held idle (idle-timeout / max-conn) |
| `content-length-prealloc` | memory | huge declared `Content-Length`, **no body** ([CVE-2026-5440](https://nvd.nist.gov/vuln/detail/CVE-2026-5440)) |
| `expect-100-continue` | memory | `Expect: 100-continue` + big CL, body withheld ([CVE-2020-10705](https://nvd.nist.gov/vuln/detail/CVE-2020-10705)) |
| `large-upload` | memory | a huge uncompressed body delivered fast (whole-body buffering) |
| `huge-chunk` | memory | chunked, one `0x7fff…`-byte declared chunk (pre-alloc) |
| `chunk-size-overflow` | crash | chunk-size near 2⁶⁴ → arithmetic overflow |
| `chunk-extension-flood` | CPU | 1-byte chunks with kilobyte chunk-extensions ([CVE-2023-39326](https://nvd.nist.gov/vuln/detail/CVE-2023-39326)) |
| `tiny-chunk-flood` | CPU | millions of 1-byte chunks (per-chunk cost) |
| `trailer-flood` | memory | chunked body + an unbounded trailer section ([CVE-2026-22815](https://nvd.nist.gov/vuln/detail/CVE-2026-22815)) |
| `header-bomb` | memory | one enormous header value (per-field / total size cap) |
| `header-count-flood` | memory | tens of thousands of tiny header fields ([CVE-2026-28980](https://nvd.nist.gov/vuln/detail/CVE-2026-28980)) |
| `duplicate-header-merge` | CPU | the same header name ×N → O(n²) join before dispatch |
| `pipelining-flood` | memory | thousands of pipelined requests, responses unread ([CVE-2026-54273](https://nvd.nist.gov/vuln/detail/CVE-2026-54273)) |

**HTTP/1.1 parser-differential — run against the `POST /parse` endpoint.** An entry that implements `/parse` parses the request body with its standard facilities (JSON, form/multipart, request decompression) — so these measure the framework's real parser limits. An entry that does **not** implement `/parse` (returns 404/405) shows **🔌 no-endpoint** and is **not scored** (neither pass nor fail):

| Attack | Exhausts | What it does |
|---|---|---|
| `decompression-bomb` | memory | a gzip body that inflates to GBs |
| `decomp-codec-bypass` | memory | a **deflate** bomb — caps are often gzip-only ([CVE-2026-42587](https://nvd.nist.gov/vuln/detail/CVE-2026-42587)) |
| `hashdos` | CPU | many form keys → O(n²) in an un-seeded hash map |
| `json-nesting-bomb` | CPU | a deeply nested JSON body → stack overflow |
| `json-bignum` | CPU | one gigantic JSON number → BigDecimal / quadratic int ([CVE-2023-4043](https://nvd.nist.gov/vuln/detail/CVE-2023-4043)) |
| `multipart-flood` | memory | `multipart/form-data` with tens of thousands of parts |
| `redos-headers` | CPU | header values crafted for catastrophic regex backtracking |
| `qvalue-cpu-bomb` | CPU | a huge `Accept-Language` list → O(n²) q-value sort ([CVE-2020-27223](https://nvd.nist.gov/vuln/detail/CVE-2020-27223)) |
| `cookie-flood` | memory | many cookie pairs under the header-byte cap ([CVE-2025-58186](https://nvd.nist.gov/vuln/detail/CVE-2025-58186)) |
| `percent-decode-quadratic` | CPU | a path of many `%XX` tokens → super-linear decode ([CVE-2026-45822](https://nvd.nist.gov/vuln/detail/CVE-2026-45822)) |
| `range-bomb` | memory | many ranges on a static file → `multipart/byteranges` amplification ([CVE-2011-3192](https://nvd.nist.gov/vuln/detail/CVE-2011-3192)) |

**HTTP/2 — only when the entry has an **h2c** profile** (`baseline-h2c`/`json-h2c`), over the cleartext h2c listener on :8082. (The attacks target :8082 directly, so an entry that does h2 only over TLS isn't covered yet — gating it in would fire the attacks at an unbound port.)

| Attack | Exhausts | What it does |
|---|---|---|
| `continuation-flood` | memory | endless `CONTINUATION` frames with no `END_HEADERS` ([CVE-2024-27316](https://nvd.nist.gov/vuln/detail/CVE-2024-27316)) |
| `hpack-bomb` | memory | a ~4 KB HPACK entry referenced by thousands of 1-byte indices ([CVE-2016-6581](https://nvd.nist.gov/vuln/detail/CVE-2016-6581)) |
| `rapid-reset` | CPU | open-then-immediately-`RST` streams in a tight loop ([CVE-2023-44487](https://nvd.nist.gov/vuln/detail/CVE-2023-44487)) |
| `madeyoureset` | CPU | force server-side `RST` via `WINDOW_UPDATE(0)` ([CVE-2025-8671](https://nvd.nist.gov/vuln/detail/CVE-2025-8671)) |
| `settings-flood` / `ping-flood` / `empty-frame-flood` | CPU | frame floods the peer must process ([CVE-2019-9515](https://nvd.nist.gov/vuln/detail/CVE-2019-9515)/[9512](https://nvd.nist.gov/vuln/detail/CVE-2019-9512)/[9518](https://nvd.nist.gov/vuln/detail/CVE-2019-9518)) |
| `window-stall` | memory | many streams at a 0 flow-control window, never granted ([CVE-2019-9517](https://nvd.nist.gov/vuln/detail/CVE-2019-9517)) |

**WebSocket — only when the entry has a `/ws` profile** (`echo-ws`/`echo-ws-pipeline`/`echo-ws-limited`), over `/ws` on :8080:

| Attack | Exhausts | What it does |
|---|---|---|
| `ws-giant-frame` | memory | a frame header declaring a 2⁶³ payload length (receive-buffer pre-alloc) |
| `ws-fragment-bomb` | memory | endless continuation frames, no FIN ([CVE-2026-48779](https://nvd.nist.gov/vuln/detail/CVE-2026-48779)) |
| `ws-deflate-bomb` | memory | a permessage-deflate frame inflating to GBs ([CVE-2026-1526](https://nvd.nist.gov/vuln/detail/CVE-2026-1526)) |
| `ws-pong-flood` | memory | flood PINGs, never read → unbounded auto-PONG queue ([CVE-2026-109932](https://nvd.nist.gov/vuln/detail/CVE-2026-109932)) |

**TLS — only when the entry has a TLS listener** (`json-tls`/`static-tls`/`8gbit` on :8081, else `baseline-h2`/`static-h2` on :8443):

| Attack | Exhausts | What it does |
|---|---|---|
| `tls-handshake-flood` | CPU | many full handshakes → the server pays asymmetric crypto each time (THC-SSL-DOS class) |
| `dheat` | CPU | offer only DHE → a modular exponentiation per handshake ([CVE-2002-20001](https://nvd.nist.gov/vuln/detail/CVE-2002-20001)); reports *immune* if no DHE is offered |

A connection the server **reaps** (closes on the client) is the *correct* defense. The **memory** attacks give the cleanest verdict (OOM-kill → exit 137) and `chunk-size-overflow` aims for a **crash**; the **CPU** attacks don't OOM, so they surface as `hung`/`degraded` through the liveness probe. Many reaped connections with flat memory and green liveness means the server defended itself.

### The `/parse` endpoint

The six parser-differential attacks need a route that actually **parses** the request body — benchmark handlers like `/echo` just stream bytes back, so the attack never reaches a parser and would falsely read `survived`. An entry opts into these attacks by implementing:

```
POST /parse   — parse the request body with the framework's standard facilities:
                application/json      → the JSON parser (depth / number limits)
                x-www-form-urlencoded → the form parser (key count / hashing)
                multipart/form-data   → the multipart parser (part count)
                other (+ Content-Encoding) → request decompression + buffering
              Return 200 with anything (the body content is not checked).
```

If an entry doesn't implement `/parse` (returns 404/405), those six attacks report **🔌 no-endpoint** and drop out of its score — honest, rather than a phantom `survived`. `aspnet-minimal` implements it as the reference (System.Text.Json + `ReadFormAsync` + `UseRequestDecompression`).

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

The box and the run are env-overridable: `RES_MEM` (default `4g`), `RES_CPUSET` (one physical core + its SMT sibling, read from the CPU topology — a tight "2 threads on 1 core" box; a no-SMT/SMT-off box, common on ARM, reads as the single-CPU set `0-0`, a box too small to spare the client a core of its own falls back to a one-CPU server, and a single-CPU box warns that it cannot isolate at all), `RES_DURATION` (`15`s max; an attack ends early the moment the server dies **or** is clearly surviving — past `RES_MIN_DURATION` (`8`s) with 100% liveness and peak RSS flat for `RES_SETTLE` (`6`s) — so a hardened server doesn't burn the full window), `RES_CONNS` (`4000` slow-attack connections, held below the ~28k ephemeral-port ceiling), `RES_BODY_SIZE` (100 MiB), `RES_DRIP_BYTES` (`256` B per drip), per-surface connection counts `RES_H2_CONNS` (`256`), `RES_DECOMP_CONNS` (`64`, H1 payload/parser floods), `RES_WS_CONNS` (`256`), `RES_TLS_CONNS` (`128`); and a size knob per attack — `RES_BOMB_SIZE`, `RES_CL_DECLARE`, `RES_UPLOAD_SIZE`, `RES_CHUNK_COUNT`, `RES_CHUNK_EXT_SIZE`, `RES_HEADER_VALUE_SIZE`, `RES_HEADER_COUNT`, `RES_DUP_HEADERS`, `RES_PIPELINE_DEPTH`, `RES_QVALUE_COUNT`, `RES_COOKIE_PAIRS`, `RES_PERCENT_COUNT`, `RES_RANGE_COUNT`, `RES_BIGNUM_DIGITS`, `RES_WS_FRAME_LEN`, `RES_WS_FRAG_SIZE`, `RES_HASHDOS_KEYS`, `RES_JSON_DEPTH`, `RES_MULTIPART_PARTS`, `RES_REDOS_PAD`, `RES_STALL_COUNT`/`RES_STALL_STREAMS` — plus `RES_RECOVERY` (`15`s). The attack client runs on every logical CPU *except* the server's core + sibling (`ATTACK_CPUS`, derived together with `RES_CPUSET` so the two stay disjoint and valid on a machine of any size), so it never shares a physical core with the deliberately CPU-starved server and gets maximum firepower. To actually *use* those cores, **most of the suite runs on a dependency-free Go client**: the frame-construction floods (HTTP/2 floods, TLS-handshake flood), where CPython's GIL otherwise caps a flood near one core; and the slow/hold family (`slow-body`/`-headers`/`-read`, `keepalive-hoard`, the content-length/expect/chunked holds, `large-upload`, `pipelining-flood`, `window-stall`), whose lever is *connection count* — a goroutine per connection holds tens of thousands where CPython's thread-per-connection model tops out near a few thousand. Only the parser-differential attacks (`hashdos`, `decompression-bomb`, the JSON/multipart/header floods — where the client sends one small payload and the *server* does the work, so neither the GIL nor connection count is the limit), the WebSocket attacks, and `dheat` (Go's `crypto/tls` has no finite-field DHE) stay on the Python client (`attack.py`). Set `RES_USE_GO=0` to force the Python client everywhere.

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
