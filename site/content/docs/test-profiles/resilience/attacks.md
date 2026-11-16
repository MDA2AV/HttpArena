---
title: The Attacks
seo_title: "Resilience: The 41 Attacks"
description: "The resilience attack catalog — slow-drip and Slowloris holds, oversized and malformed chunks, header and parser floods, HTTP/2 CONTINUATION and rapid-reset, WebSocket and TLS handshake attacks — each mapped to what it exhausts and the CVE class it models."
weight: 1
---

The suite has **41 attacks** across four protocol surfaces. The most valuable for this benchmark are the **server-level** ones that fire regardless of what the handler does — most entries are minimal handlers that never parse the body, so the **parser-differential** attacks (the `POST /parse` table below) mostly read `survived` on them, which is itself a recordable result. The **Exhausts** column says what each attack targets; how that becomes a [verdict](verdicts) is read from the container afterwards.

## HTTP/1.1 server-level

Fire against any entry with an HTTP/1.1 profile on :8080 (`baseline`, `pipelined`, `limited-conn`, `json-comp`, `async`, `async-db`, `fortunes` or a latency profile):

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

## HTTP/1.1 parser-differential

Run against the `POST /parse` endpoint, for the same entries as the server-level attacks. An entry that implements `/parse` parses the request body with its standard facilities (JSON, form/multipart, request decompression) — so these measure the framework's real parser limits. An entry that does **not** implement `/parse` (returns 404/405) shows **🔌 no-endpoint** and is **not scored** (neither pass nor fail):

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

## HTTP/2

Only when the entry has an **h2c** profile (`baseline-h2c`/`json-h2c`), over the cleartext h2c listener on :8082. (The attacks target :8082 directly, so an entry that does h2 only over TLS isn't covered yet — gating it in would fire the attacks at an unbound port.)

| Attack | Exhausts | What it does |
|---|---|---|
| `continuation-flood` | memory | endless `CONTINUATION` frames with no `END_HEADERS` ([CVE-2024-27316](https://nvd.nist.gov/vuln/detail/CVE-2024-27316)) |
| `hpack-bomb` | memory | a ~4 KB HPACK entry referenced by thousands of 1-byte indices ([CVE-2016-6581](https://nvd.nist.gov/vuln/detail/CVE-2016-6581)) |
| `rapid-reset` | CPU | open-then-immediately-`RST` streams in a tight loop ([CVE-2023-44487](https://nvd.nist.gov/vuln/detail/CVE-2023-44487)) |
| `madeyoureset` | CPU | force server-side `RST` via `WINDOW_UPDATE(0)` ([CVE-2025-8671](https://nvd.nist.gov/vuln/detail/CVE-2025-8671)) |
| `settings-flood` / `ping-flood` / `empty-frame-flood` | CPU | frame floods the peer must process ([CVE-2019-9515](https://nvd.nist.gov/vuln/detail/CVE-2019-9515)/[9512](https://nvd.nist.gov/vuln/detail/CVE-2019-9512)/[9518](https://nvd.nist.gov/vuln/detail/CVE-2019-9518)) |
| `window-stall` | memory | many streams at a 0 flow-control window, never granted ([CVE-2019-9517](https://nvd.nist.gov/vuln/detail/CVE-2019-9517)) |

## WebSocket

Only when the entry has a `/ws` profile (`echo-ws`/`echo-ws-pipeline`/`echo-ws-limited`), over `/ws` on :8080:

| Attack | Exhausts | What it does |
|---|---|---|
| `ws-giant-frame` | memory | a frame header declaring a 2⁶³ payload length (receive-buffer pre-alloc) |
| `ws-fragment-bomb` | memory | endless continuation frames, no FIN ([CVE-2026-48779](https://nvd.nist.gov/vuln/detail/CVE-2026-48779)) |
| `ws-deflate-bomb` | memory | a permessage-deflate frame inflating to GBs ([CVE-2026-1526](https://nvd.nist.gov/vuln/detail/CVE-2026-1526)) |
| `ws-pong-flood` | memory | flood PINGs, never read → unbounded auto-PONG queue ([CVE-2026-109932](https://nvd.nist.gov/vuln/detail/CVE-2026-109932)) |

## TLS

Only when the entry has a TLS listener (`json-tls`/`static-tls`/`8gbit` on :8081, else `baseline-h2`/`static-h2` on :8443):

| Attack | Exhausts | What it does |
|---|---|---|
| `tls-handshake-flood` | CPU | many full handshakes → the server pays asymmetric crypto each time (THC-SSL-DOS class) |
| `dheat` | CPU | offer only DHE → a modular exponentiation per handshake ([CVE-2002-20001](https://nvd.nist.gov/vuln/detail/CVE-2002-20001)); reports *immune* if no DHE is offered |

## The `/parse` endpoint

The parser-differential attacks need a route that actually **parses** the request body — benchmark handlers like `/echo` just stream bytes back, so the attack never reaches a parser and would falsely read `survived`. An entry opts into these attacks by implementing:

```
POST /parse   — parse the request body with the framework's standard facilities:
                application/json      → the JSON parser (depth / number limits)
                x-www-form-urlencoded → the form parser (key count / hashing)
                multipart/form-data   → the multipart parser (part count)
                other (+ Content-Encoding) → request decompression + buffering
              Return 200 with anything (the body content is not checked).
```

If an entry doesn't implement `/parse` (returns 404/405), those attacks report **🔌 no-endpoint** and drop out of its score — honest, rather than a phantom `survived`. `aspnet-minimal` implements it as the reference (System.Text.Json + `ReadFormAsync` + `UseRequestDecompression`).
