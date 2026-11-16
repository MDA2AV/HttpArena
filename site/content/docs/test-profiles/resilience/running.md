---
title: Running & Tuning
seo_title: "Resilience: Opting In and Running Locally"
description: "Opt an entry into the resilience suite with one meta.json flag, run it on the bench host or your own machine, and tune the memory box, CPU split, connection counts and per-attack sizes for any hardware."
weight: 3
---

## Opting in

The suite is **off by default** — the attacks are destructive and need the whole machine. An entry opts in with one flag in its `meta.json`:

```json
"resilience": true
```

The suite runs only on request, never as part of a `/benchmark`: comment `/resilience -f <entry>` on the PR (several: `-f <a>,<b>`), and add `--save` to commit the verdicts to `site/data/resilience/<entry>.json`. It goes through the same approval and the same self-hosted bench host as a benchmark, which runs one job at a time, so the suite never competes with another run for CPU, memory or ports — contention that would corrupt a verdict. It builds the image itself and posts the report as its own comment. Only entries with the flag run; naming one that hasn't opted in is a no-op.

An entry runs the [attack families](attacks) its profiles give it a listener for: HTTP/1.1 on 8080, h2c on 8082, `/ws`, TLS. An entry split across directories that share a display name (`ntex`, `ntex-h2`, `ntex-ws`) opts each directory in; each one runs its own families, and the board joins their verdicts under the one name. A directory with none of those listeners, such as a gRPC-only one, has nothing to run.

## Running it locally

```bash
./scripts/resilience.sh aspnet-minimal         # opted-in entry: verdicts in results/resilience/<entry>.json
./scripts/resilience.sh aspnet-minimal --save  # and in site/data/resilience/<entry>.json
./scripts/resilience.sh some-entry slow-body   # name attacks to force a run on an entry that hasn't opted in
```

`<entry>` is the directory under `frameworks/`, not the display name — entries that share a display name each keep their own file, the way `site/data/spec/<entry>.json` does. Without the flag and without a named attack, the runner is a no-op.

## Tuning for a smaller machine

Everything is an environment variable — nothing is pinned to the bench host, and the defaults are sized for a large dedicated box. The CPU split **auto-adapts** to the host's topology (see [The box](#the-box) below), so on a laptop or small VM the knobs that matter are the memory box, the connection counts, and the per-attack time cap:

```bash
# Modest host: shrink the memory box, the connection counts, and the duration.
# A single 127.0.0.1 reaches only ~28k ephemeral ports, so keep the connection
# counts well below that (the big-box defaults are 32768).
RES_MEM=1g RES_DURATION=20 \
  RES_CONNS=4000 RES_H2_CONNS=4000 RES_DECOMP_CONNS=4000 RES_WS_CONNS=4000 RES_TLS_CONNS=512 \
  ./scripts/resilience.sh aspnet-minimal slow-body

# Pin the CPU split by hand instead of the auto-derived one
# (server on one core, attack client on the rest):
RES_CPUSET=0-0 ATTACK_CPUS=1-3 ./scripts/resilience.sh aspnet-minimal slow-body
```

## The knobs

Every default below is overridable from the environment.

### The box

Where the entry runs and who attacks it:

| Variable | Default | What it sets |
|---|---|---|
| `RES_MEM` | `4g` | the memory box the entry runs in; swap is disabled, so going over OOM-kills it deterministically |
| `RES_CPUSET` | 1 core + its SMT sibling | the server's CPUs, read from the host topology. Auto-adapts: a no-SMT/ARM box reads as the single-CPU set `0-0`, a box too small to spare the client a core falls back to a one-CPU server, and a single-CPU box shares and warns |
| `ATTACK_CPUS` | every other logical CPU | the attack client's CPUs, derived with `RES_CPUSET` so the two never share a physical core |

### Timing

How long an attack runs and when it ends early:

| Variable | Default | What it sets |
|---|---|---|
| `RES_DURATION` | `45` | max seconds per attack; ends early the moment the server dies **or** is clearly surviving |
| `RES_MIN_DURATION` | `8` | never declare "surviving" before this many seconds |
| `RES_SETTLE` | `6` | …and only after peak RSS has been flat and liveness 100% this long |
| `RES_RECOVERY` | `15` | seconds to wait for the server to serve again after the attack stops |

### Connection counts

The lever for the slow/hold and flood families. A single `127.0.0.1` reaches only ~28k ephemeral ports, so lower these on a small host:

| Variable | Default | Surface |
|---|---|---|
| `RES_CONNS` | `32768` | HTTP/1.1 slow / hold attacks |
| `RES_H2_CONNS` | `32768` | HTTP/2 floods |
| `RES_DECOMP_CONNS` | `32768` | HTTP/1.1 payload / parser floods |
| `RES_WS_CONNS` | `32768` | WebSocket attacks |
| `RES_TLS_CONNS` | `4000` | TLS handshake attacks |

### Per-attack sizes

Each attack's magnitude:

| Variable | Default | Attack |
|---|---|---|
| `RES_BODY_SIZE` | `104857600` (100 MiB) | `slow-body` declared body |
| `RES_DRIP` | `1.0` | seconds between drips (`slow-body`/`huge-chunk`) |
| `RES_DRIP_BYTES` | `256` | bytes per drip |
| `RES_BOMB_SIZE` | `1073741824` (1 GiB) | decompressed size per gzip/deflate bomb |
| `RES_CL_DECLARE` | `2147483648` (2 GiB) | declared `Content-Length` (`content-length-prealloc`/`expect-100-continue`) |
| `RES_UPLOAD_SIZE` | `2147483648` (2 GiB) | bytes actually delivered (`large-upload`) |
| `RES_CHUNK_COUNT` | `500000` | 1-byte chunks (`tiny-chunk-flood`) |
| `RES_CHUNK_EXT_SIZE` | `4096` | chunk-extension bytes per chunk |
| `RES_HEADER_VALUE_SIZE` | `1048576` (1 MiB) | one header value (`header-bomb`) |
| `RES_HEADER_COUNT` | `50000` | header fields (`header-count-flood`) |
| `RES_DUP_HEADERS` | `20000` | repeats of one header name (`duplicate-header-merge`) |
| `RES_PIPELINE_DEPTH` | `10000` | pipelined requests per batch |
| `RES_QVALUE_COUNT` | `600` | `Accept-Language` entries (`qvalue-cpu-bomb`) |
| `RES_COOKIE_PAIRS` | `1000` | cookie pairs (`cookie-flood`) |
| `RES_PERCENT_COUNT` | `2000` | `%XX` tokens in the path (`percent-decode-quadratic`) |
| `RES_RANGE_COUNT` | `1000` | byte ranges (`range-bomb`) |
| `RES_BIGNUM_DIGITS` | `100000` | digits in the JSON number (`json-bignum`) |
| `RES_HASHDOS_KEYS` | `100000` | form keys (`hashdos`) |
| `RES_JSON_DEPTH` | `100000` | array nesting depth (`json-nesting-bomb`) |
| `RES_MULTIPART_PARTS` | `50000` | parts (`multipart-flood`) |
| `RES_REDOS_PAD` | `4000` | ambiguous-run length (`redos-headers`) |
| `RES_STALL_COUNT` | `5000` | `/json/{count}` size per stalled stream (`window-stall`) |
| `RES_STALL_STREAMS` | `64` | stalled streams per connection (`window-stall`) |
| `RES_WS_FRAME_LEN` | `9223372036854775552` | declared WS frame length (`ws-giant-frame`) |
| `RES_WS_FRAG_SIZE` | `4096` | bytes per WS fragment (`ws-fragment-bomb`) |

### Client selection

| Variable | Default | What it sets |
|---|---|---|
| `RES_USE_GO` | `1` | use the dependency-free Go attack client where it helps; `0` forces the Python client everywhere |
| `RES_SKIP_BUILD` | `0` | `1` reuses an already-built entry image instead of rebuilding |

## Go client vs. Python client

To actually *use* the attack cores, **most of the suite runs on a dependency-free Go client** (`scripts/resilience/attacker/`): the frame-construction floods (the HTTP/2 floods, the TLS-handshake flood), where CPython's GIL otherwise caps a flood near one core; and the slow/hold family (`slow-body`/`-headers`/`-read`, `keepalive-hoard`, the content-length/expect/chunked holds, `large-upload`, `pipelining-flood`, `window-stall`), whose lever is connection count — a goroutine per connection holds tens of thousands where CPython's thread-per-connection model tops out near a few thousand.

Only the parser-differential attacks (`hashdos`, `decompression-bomb`, the JSON/multipart/header floods — where the client sends one small payload and the *server* does the work, so neither the GIL nor connection count is the limit), the WebSocket attacks, and `dheat` (Go's `crypto/tls` has no finite-field DHE) stay on the Python client (`scripts/resilience/attack.py`). Set `RES_USE_GO=0` to force the Python client everywhere.
