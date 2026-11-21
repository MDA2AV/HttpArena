---
title: Implementation Guidelines
seo_title: "Held-Connection Benchmarks (CON-1M, CON-1M-TLS, CON-5M): Implementation Guide"
description: "What to implement, what the listener must allow, how the load is run, what is measured, and how the held-connection profiles CON-1M, CON-1M-TLS and CON-5M are scored."
---
{{< type-rules standard="Nothing new to implement - the profiles drive `GET /baseline11`, which the baseline profile already specifies and validates. What they ask of you is a server that can hold the whole fleet - a million connections, five million on CON-5M: it must listen on every loopback address (0.0.0.0 or [::], not 127.0.0.1 or localhost), must not cap connections below the fleet, and must not close an idle keep-alive connection in under five seconds. Over TLS it also needs TLS 1.3 on the h1 TLS port, serving the same route. Memory is a quarter of the score, so buffers and TLS state kept per connection count directly against it." tuned="May size buffers, pools and accept loops for the fleet, raise connection caps and idle timeouts, and set the runtime's heap and GC options. All of it is charged: memory is read from the container, which is capped at 128 GiB (96 GiB on the million-connection profiles)." engine="Same as above. An engine with a fixed-size connection table, or one that preallocates a full read buffer per connection, finds out here." >}}


A fleet of keep-alive connections is opened against the server and held for the whole run, and `GET /baseline11?a=1&b=2` is paced across it: **one request per connection every four seconds**. At that rate the work per request is a fraction of what a fast server carries on this cpuset, so what is left to measure is what holding the rest of the fleet costs.

| | CON-1M | CON-1M-TLS | CON-5M |
|---|---|---|---|
| Profile | `connections-1m` | `connections-1m-tls` | `connections-5m` |
| Connections | 1,000,000 | 1,000,000 over TLS 1.3 | 5,000,000 |
| Rate | 250,000 req/s | 250,000 req/s | 1,250,000 req/s |
| Addresses | 127.0.0.1-.32 | 127.0.0.1-.32, port 8081 | 127.0.0.1-.160 |
| Load generator | 32 zrk 3.0.2, [one per address](#con-1m-a-million-on-zrk) | gcannon ≥ 0.8.4, [below](#con-1m-tls-a-million-over-tls) | gcannon ≥ 0.8.2 |
| Scored | yes | yes | no, and [by allowlist only](#con-5m-by-allowlist) |

**Endpoint:** `GET /baseline11?a=1&b=2` · **CPU:** cpuset `0-31,64-95` · **Window:** 20s, after the fleet is connected

## What your server must allow

The request is the baseline one, so there is no code to write. Five things about the listener decide whether an entry can run here at all (the numbers are CON-5M's; CON-1M and CON-1M-TLS hold a fifth of it):

- **Listen on every address.** A connection is identified by its source and destination address and port, so one client address can hold at most about 64.5K connections to one server address and port. The five million are therefore spread over 160 loopback addresses, `127.0.0.1` to `127.0.0.160`, 31,250 connections each. A listener on `0.0.0.0` or `[::]` accepts on all of them; one bound to `127.0.0.1` or `localhost` refuses 159 of the 160. [Validation](../validation) checks this, and the run refuses to start without it.
- **No connection cap below the fleet.** Some servers ship with a per-worker or global limit: actix's is 25,600 per worker, about 1.64 million across 64 workers, so the actix entry raises it to 100,000. Raise anything lower.
- **An idle timeout of five seconds or more.** Each connection is idle for four seconds between requests, and for up to four seconds between connecting and its first request. Node's, uvicorn's and actix's default keep-alive timeouts are five seconds, which is enough; anything shorter closes the fleet between requests and shows up as reconnects and errors. (At 1M req/s the interval would be five seconds, and those defaults raced every request.)
- **File descriptors.** The container is started with `--ulimit nofile=8388608` (capped at the host's `fs.nr_open`), so five million sockets fit. A server that sets a lower limit of its own, or spends a descriptor per connection on something besides the socket, has to leave room for them.
- **TLS 1.3, for CON-1M-TLS.** The TLS listener on port 8081 (the one JSON TLS uses) must serve `/baseline11` too, listen on every address, and speak TLS 1.3, the only version the load generator offers.

## How the load is run

On CON-5M, one [gcannon](/docs/load-generators/h1/gcannon/) process holds the whole fleet: `--rate 1250000` gives each connection its own schedule, one request every four seconds, with every client thread's connections spread over the whole interval so the five million do not fire in waves, and latency counted from each request's scheduled time. `--addr-span 160` spreads the connections over `127.0.0.1`-`127.0.0.160`, 31,250 on each, and `--connect-limit 64` keeps at most 64 first connects in flight per thread, so they never arrive as one burst of SYNs.

gcannon's warmup waits until every connection has opened (up to 300s), then keeps the load running 30 seconds more (`--settle 30s`) so the server can work off the connect phase, and **what is reported is the 20 seconds after that**. [`scripts/conn_hold.py`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/conn_hold.py) reads the server's cgroup CPU when gcannon marks the window's start and end, so neither the five million connects (or handshakes) nor the five million closes are in the CPU figure. It also probes the listener, refuses a run the host cannot hold in memory, and raises the open-file limit gcannon needs for five million sockets.

Every run gets a fresh server, and connects only once the last run's connections are gone. After the window, the harness waits, with the server still up so it closes its own side, until the host's TCP socket count (`alloc` in `/proc/net/sockstat`) is back to within 50,000 of what it was before the first profile; then it stops the server and starts the next. gcannon 0.8.3 and later close their connections themselves before exiting, in seconds. Earlier versions leave them for the kernel to close one at a time after exit, which on the bench host took longer than the minute the harness used to sleep, so runs 2 and 3 connected and measured on a host still closing the last fleet.

The load generator is gcannon rather than [zrk](/docs/load-generators/h1/zrk/), the other paced generator here, because of memory: zrk 2.3.0 keeps ~303 KiB resident per connection and even 3.0.2 ~41 KiB, ~200 GiB for five million. gcannon holds a connection in ~3.3 KiB.

## CON-1M-TLS: a million over TLS

`connections-1m-tls` is the gcannon run over TLS 1.3 at a million connections: 250,000 req/s, still one request per connection every four seconds, over `127.0.0.1`-`127.0.0.32` (31,250 on each), against the TLS listener on port 8081. Every connection handshakes once, then carries its requests encrypted, so what it adds is the TLS session the server keeps for each connection.

- **A million, for now.** Five million over TLS was still connecting 7.7 minutes into its first run.
- **Handshakes are paced to the server.** gcannon ≥ 0.8.4 counts a connection against `--connect-limit` until its handshake is done, so at most 64 per client thread wait at the server, and a new connection starts only when one of them finishes ([MDA2AV/gcannon#33](https://github.com/MDA2AV/gcannon/pull/33)). Earlier versions released the slot at the TCP connect, which the kernel completes on its own, and the handshakes piled up past the server's handshake timeout (10 s on ioxide and Kestrel, 3 s on actix), which closed them mid-handshake. The run refuses an older gcannon.
- **gcannon's side.** It handshakes each connection with OpenSSL (TLS 1.3, no certificate verification: the bench certificate is self-signed), then hands the session to kernel TLS and frees its own TLS state. A TLS connection costs the client what a plaintext one does plus the kernel's record state, so what the profile adds to the server's figures is its own TLS sessions.
- **Limits.** The warmup waits up to 900s for the handshakes, and the server gets the million-connection caps: `nofile` 2,097,152 and 96 GiB.

## CON-1M: a million on zrk

`connections-1m` holds one million connections at 250,000 req/s with zrk 3.0.2 as the load generator, on the same cpusets, 64 client threads and 20s window. Run next to gcannon at the same scale, it is also how gcannon 0.8.0's `--rate` was caught sending each thread's connections in one burst ([MDA2AV/gcannon#30](https://github.com/MDA2AV/gcannon/pull/30)).

- **zrk 3.0.2, not the pinned 2.3.0.** 3.0.2 shares one latency histogram per thread instead of keeping one per connection, which takes a connection from ~303 KiB to ~41 KiB (measured flat at 4K and 16K connections), ~40 GiB for the million. The other zrk profiles stay on 2.3.0; this one builds its own `zrk:3.0.2` image from the same Dockerfile, and refuses an older zrk.
- **One process per address.** zrk takes one URL, so [`scripts/zrk_fanout.py`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/zrk_fanout.py) runs 32 of them, one per address from `127.0.0.1` to `127.0.0.32`, each holding 31,250 connections at 7,812 req/s on 2 threads.
- **Staggered starts instead of a connect limit.** Each zrk opens all of its connections the moment it starts, so the 32 start one second apart, the 10s after the last start are discarded, and the 20s that follow are measured.
- **Merged histograms.** Each process writes its full latency histogram every second; the rows inside the window are summed bucket by bucket and the percentiles read off the sum, never averaged across processes.
- **Held** is counted from the server's side: its established sockets on :8080, read with `ss` after the window.

## CON-5M: by allowlist

Holding five million connections, a server may grow to its 128 GiB cap, so CON-5M is not open to every entry: it runs only for the frameworks listed in [`scripts/connections-5m-allowlist.json`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/connections-5m-allowlist.json). Subscribing to `connections-5m` in `meta.json` is not enough on its own: an entry that subscribes but is not on the list is skipped, and the run says why. To be added, ask in your pull request.

## What is measured

| field | meaning |
|---|---|
| `connections_open` | connections still open when the window closed, counted by gcannon ("Held" on the board); on `connections-1m`, the server's established sockets after the window |
| `memory` | the container's peak memory across the run, the whole fleet included - a quarter of the score. Divided by the fleet it is the cost of a connection, to within the server's baseline |
| `cpu_usec` | server CPU microseconds over the window only, read from cgroup v2 `cpu.stat`, so the connects and handshakes are not in it |
| `cpu_per_req_us` | the same divided by requests served in the window |
| `p50_latency`, `p99_latency` | the median and the 99th percentile, coordinated-omission-corrected, over the window: both are in the score |
| `avg_latency`, `p99_9_latency` | coordinated-omission-corrected, over the window, shown but not scored |
| `rate_ratio` | achieved over offered in the window. A connection that never opened sends nothing, so a fleet only partly held lands here too |
| `window_connect_errors` | connect failures inside the window: connections the server dropped and refused again |

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /baseline11?a=1&b=2` (GET only, no body); over TLS 1.3 on port 8081 for `connections-1m-tls` |
| Connections | 1,000,000 over 127.0.0.1-127.0.0.32 (CON-1M, CON-1M-TLS); 5,000,000 over 127.0.0.1-127.0.0.160 (CON-5M); 31,250 per address |
| Offered rate | 250,000 req/s (CON-1M, CON-1M-TLS), 1,250,000 req/s (CON-5M), paced: one request per connection every 4s |
| CPU | cpuset `0-31,64-95` (32 cores, both threads) |
| Memory cap | 128 GiB (`CONN5M_MEM_LIMIT`), 96 GiB on the million-connection profiles (`CONN1M_MEM_LIMIT`); a server above it is OOM-killed |
| Ramp | at most 64 first connects in flight per thread (over TLS, until the handshake is done); the warmup waits up to 300s (900s on `connections-1m-tls`) for all of them |
| Settle | 30s at the full rate after the fleet is up, before the window (`--settle`) |
| Window | 20s |
| Runs | 3, and the highest-scoring one is kept |
| Load generator | [gcannon](/docs/load-generators/h1/gcannon/) ≥ 0.8.2 with `--rate` and `--settle` (≥ 0.8.4 on `connections-1m-tls`), under `scripts/conn_hold.py`; on `connections-1m`, 32 [zrk](/docs/load-generators/h1/zrk/) 3.0.2 processes under `scripts/zrk_fanout.py` |
| Host limits | `fs.nr_open`, `vm.max_map_count` (zrk maps ~4 regions per connection) and the conntrack table are raised for these profiles only (`system_tune_held_connections`) |

## Scoring

What holding the fleet costs, against the best in the field, times the share of the rate delivered:

```
rateFactor = min(1, achieved_rps / full_rate)
quality    = 0.25 x cpuScore + 0.25 x memScore + 0.25 x p50Score + 0.25 x p99Score
score      = 100 x rateFactor x quality
```

| term | measured as | scale |
|---|---|---|
| cpuScore | CPU microseconds per request, over the window | best / yours |
| memScore | the server's peak memory with the fleet held | best / yours |
| p50Score | median latency | 1 - log10(yours / best) / 3: ten times the best costs a third of the term |
| p99Score | 99th-percentile latency | the same three-decade scale |

Memory and CPU spread over a few times across the field, so they are plain ratios; latency spans orders of magnitude, where a ratio would leave everyone but the leader near zero, so both percentiles get the three-decade scale [Latency-1M](../latency-1m/implementation/#scoring) uses for its p99. The rate earns full credit at 95% of what is offered: 237,500 req/s on CON-1M and CON-1M-TLS, 1,187,500 on CON-5M. A connection that never opened sends nothing, so a fleet only partly held falls short in the rate factor as well as in Held. Computed by [`scripts/latency_score.py`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/latency_score.py); the board computes the same.

**CON-1M and CON-1M-TLS are scored.** Each is worth up to 1,000 in the HTTP/1.1 composite, normalised against the field's leader like the other fixed-rate profiles, for frameworks and engines (not infrastructure). **CON-5M is reference-only:** measured and shown, part of no composite.

Subscribe by adding `connections-1m` and `connections-1m-tls` to `tests` in your `meta.json`. `connections-5m` also needs the entry on the [allowlist](#con-5m-by-allowlist).
