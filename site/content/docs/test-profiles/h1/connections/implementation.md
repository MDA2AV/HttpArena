---
title: Implementation Guidelines
seo_title: "Held-Connection Benchmarks (CON-1M, CON-1M-TLS, CON-5M): Implementation Guide"
description: "What to implement, what the listener must allow, how the load is run, what is measured, and how the held-connection profiles CON-1M, CON-1M-TLS and CON-5M are scored."
---
{{< type-rules standard="Nothing new to implement - the profiles drive `GET /baseline11`, which the baseline profile already specifies and validates. What they ask of you is a server that can hold the whole fleet - a million connections, five million on CON-5M: it must listen on every loopback address (0.0.0.0 or [::], not 127.0.0.1 or localhost), must not cap connections below the fleet, and must not close an idle keep-alive connection in under five seconds. Over TLS it also needs TLS 1.3 on the h1 TLS port, serving the same route. Memory is a quarter of the score, so buffers and TLS state kept per connection count directly against it." tuned="May size buffers, pools and accept loops for the fleet, raise connection caps and idle timeouts, and set the runtime's heap and GC options. All of it is charged: memory is read from the container, which is capped at 128 GiB (96 GiB on the million-connection profiles)." engine="Same as above. An engine with a fixed-size connection table, or one that preallocates a full read buffer per connection, finds out here." >}}


A fleet of keep-alive connections is opened against the server and held for the whole run, and `GET /baseline11?a=1&b=2` is paced across it: **one request per connection every four seconds**. At that rate the work per request is small, so what the profiles measure is what holding the fleet costs: the memory each connection keeps, the CPU a request carries while the rest of the fleet waits, and how long a request takes.

| | CON-1M | CON-1M-TLS | CON-5M |
|---|---|---|---|
| Profile | `connections-1m` | `connections-1m-tls` | `connections-5m` |
| Connections | 1,000,000 | 1,000,000 over TLS 1.3 | 5,000,000 |
| Rate | 250,000 req/s | 250,000 req/s | 1,250,000 req/s |
| Server addresses | 127.0.0.1-.32, port 8080 | 127.0.0.1-.32, port 8081 | 127.0.0.1-.160, port 8080 |
| Load generator | [32 zrk processes](#con-1m-32-zrk-processes) | [one gcannon](#con-5m-and-con-1m-tls-one-gcannon) | [one gcannon](#con-5m-and-con-1m-tls-one-gcannon) |
| Memory cap | 96 GiB | 96 GiB | 128 GiB |
| Scored | yes | yes | no, and [by allowlist only](#con-5m-by-allowlist) |

**Endpoint:** `GET /baseline11?a=1&b=2` · **CPU:** cpuset `0-31,64-95` · **Window:** 20s, after the fleet is connected

## What your server must allow

The request is the baseline one, so there is no code to write. What decides whether an entry can run here is how its server is set up:

- **Listen on every address.** One client address can hold about 64.5K connections to one server address and port, so the fleet is spread over loopback addresses, 31,250 connections on each: `127.0.0.1`-`127.0.0.32` for a million, `127.0.0.1`-`127.0.0.160` for five million. A listener on `0.0.0.0` or `[::]` accepts on all of them; one bound to `127.0.0.1` or `localhost` accepts on one. [Validation](../validation) checks this, and the run checks it again before it starts.
- **No connection cap below the fleet.** Raise any per-worker or global connection limit above it. actix, for example, defaults to 25,600 per worker, about 1.64 million across 64 workers, so the actix entry sets 100,000.
- **An idle timeout of at least five seconds.** A connection is idle for four seconds between requests, and for up to four seconds between connecting and its first request. The five-second keep-alive defaults of Node, uvicorn and actix are enough; anything shorter closes connections between requests, which shows up as reconnects and errors.
- **File descriptors.** The container is started with `--ulimit nofile` at 8,388,608 on CON-5M and 2,097,152 on the million-connection profiles, capped at the host's `fs.nr_open`. A server that lowers its own limit, or spends more than one descriptor per connection, has to leave room for the fleet.
- **TLS 1.3, for CON-1M-TLS.** The TLS listener on port 8081 (the one JSON over TLS uses) must serve `/baseline11`, listen on every address, and speak TLS 1.3, the only version the load generator offers.

## How the load is run

Every connection has its own schedule: one request every four seconds, with the fleet's connections spread evenly over that interval so they never fire in waves. Latency counts from each request's scheduled time, which corrects for coordinated omission: a stall is charged to every request scheduled during it, not only to those already sent.

A run has three phases. The fleet connects in bounded steps rather than all at once. The load then keeps running for a while, so the server has worked off the connect phase. Then **20 seconds are measured**. The harness reads the server's CPU from its cgroup v2 `cpu.stat` at the window's start and end, so neither the connects and handshakes nor the closes after the window are in the figure.

Around each run, the harness:

- probes the listener on the second and last address of the range, and refuses to start if either does not answer, instead of reporting millions of connect errors;
- refuses a run the host cannot hold: the client's and the kernel's memory per connection, plus what the server may still grow into, must fit in `MemAvailable`;
- raises `fs.nr_open`, `vm.max_map_count` and the conntrack table, for these profiles only (`system_tune_held_connections`);
- gives every run a fresh server, and connects only once the host's TCP socket count (`alloc` in `/proc/net/sockstat`) is back within 50,000 of what it was before the first profile. After the window the server stays up while the client closes the fleet, so it closes its own side.

### CON-5M and CON-1M-TLS: one gcannon

One [gcannon](/docs/load-generators/h1/gcannon/) process holds the whole fleet, at about 3.3 KiB per connection, under [`scripts/conn_hold.py`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/conn_hold.py):

| gcannon option | CON-5M | CON-1M-TLS |
|---|---|---|
| URL | `http://127.0.0.1:8080/baseline11?a=1&b=2` | `https://127.0.0.1:8081/baseline11?a=1&b=2` |
| `-c` / `-t` | 5,000,000 / 64 | 1,000,000 / 64 |
| `--rate` | 1,250,000 | 250,000 |
| `--addr-span` | 160 | 32 |
| `--connect-limit` (per thread) | 64 | 64 |
| `--warmup-max` | 300s | 900s |
| `--settle` | 30s | 30s |
| `-d` | 20s | 20s |

`--warmup-max` is how long gcannon waits for every connection to open, and `--settle` how long the load then runs before the window opens. gcannon marks the window's start and end on stderr, and `conn_hold.py` reads the server's CPU at those marks. CON-5M needs gcannon 0.8.2 or later, CON-1M-TLS 0.8.4 or later; the run refuses an older one.

### CON-1M-TLS: the handshakes

Every connection handshakes once, TLS 1.3 without certificate verification (the bench certificate is self-signed), and then carries its requests encrypted. gcannon hands each session to kernel TLS after the handshake and frees its own TLS state, so the client costs about what it does in plaintext, and what the profile adds is the TLS state the server keeps per connection.

A connection counts against `--connect-limit` until its handshake is done, so at most 64 handshakes per client thread wait on the server at a time, and the fleet connects as fast as the server completes them. The warmup allows 900 seconds for that.

### CON-1M: 32 zrk processes

[zrk](/docs/load-generators/h1/zrk/) takes a single URL, so [`scripts/zrk_fanout.py`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/zrk_fanout.py) runs 32 of them, one per address from `127.0.0.1` to `127.0.0.32`, each holding 31,250 connections on 2 threads at a 32nd of the rate.

- **Staggered starts.** A zrk process opens all of its connections the moment it starts, so the 32 start one second apart, the 10 seconds after the last start are discarded, and the 20 seconds after that are measured.
- **Merged histograms.** Each process writes its full latency histogram every second. The rows inside the window are summed bucket by bucket and the percentiles read off the sum, never averaged across processes.
- **Held** is counted on the server's side: its established sockets on port 8080, read with `ss` after the window.
- **zrk 3.0.2.** It keeps about 41 KiB per held connection; the other zrk profiles stay on the pinned 2.3.0. A native `zrk` 3.0.2 or later on the `PATH` is used, otherwise the harness builds a `zrk:3.0.2` image from `docker/zrk.Dockerfile`.

## CON-5M: by allowlist

A server holding five million connections may grow to its 128 GiB cap, so CON-5M runs only for the frameworks listed in [`scripts/connections-5m-allowlist.json`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/connections-5m-allowlist.json). An entry that subscribes to `connections-5m` but is not on the list is skipped, and the run says why. To be added, ask in your pull request.

## What is measured

| field | meaning |
|---|---|
| `connections_open` | connections still open when the window closed ("Held" on the board): counted by gcannon on CON-5M and CON-1M-TLS, and as the server's established sockets after the window on CON-1M |
| `memory` | the container's peak memory across the run, the whole fleet included - a quarter of the score. Divided by the fleet, it is roughly what one connection costs |
| `cpu_usec` | server CPU microseconds over the window only, read from cgroup v2 `cpu.stat` |
| `cpu_per_req_us` | the same divided by requests served in the window |
| `p50_latency`, `p99_latency` | the median and the 99th percentile over the window, coordinated-omission-corrected: both are in the score |
| `avg_latency`, `p99_9_latency` | the same correction and window, shown but not scored |
| `rate_ratio` | achieved over offered in the window. A connection that never opened sends nothing, so a fleet only partly held lands here too |
| `window_connect_errors` | connect failures inside the window: connections the server dropped and refused again |

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /baseline11?a=1&b=2` (GET only, no body); over TLS 1.3 on port 8081 for `connections-1m-tls` |
| Connections | 1,000,000 over 127.0.0.1-127.0.0.32 (CON-1M, CON-1M-TLS); 5,000,000 over 127.0.0.1-127.0.0.160 (CON-5M); 31,250 per address |
| Offered rate | 250,000 req/s (CON-1M, CON-1M-TLS), 1,250,000 req/s (CON-5M), paced: one request per connection every 4s |
| CPU | cpuset `0-31,64-95` (32 cores, both threads) |
| Memory cap | 128 GiB on CON-5M (`CONN5M_MEM_LIMIT`), 96 GiB on CON-1M and CON-1M-TLS (`CONN1M_MEM_LIMIT`); a server above it is OOM-killed |
| Connect phase | gcannon: at most 64 connects in flight per thread (over TLS, until the handshake is done), up to 300s (900s on CON-1M-TLS), then 30s at the full rate; zrk: processes started 1s apart, then 10s discarded |
| Window | 20s |
| Runs | 3, each on a fresh server, and the highest-scoring one is kept |
| Load generator | [gcannon](/docs/load-generators/h1/gcannon/) under `scripts/conn_hold.py` (CON-5M: 0.8.2 or later; CON-1M-TLS: 0.8.4 or later); 32 [zrk](/docs/load-generators/h1/zrk/) 3.0.2 processes under `scripts/zrk_fanout.py` (CON-1M) |

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

**CON-1M and CON-1M-TLS are scored.** Each is normalised to 1,000 for the field's leader like the other fixed-rate profiles, for frameworks and engines (not infrastructure), and the two share the weight of one profile in the HTTP/1.1 composite, 0.5 each ([weights](/docs/scoring/composite-score/#weights)), so each adds up to 500. **CON-5M is reference-only:** measured and shown, part of no composite.

Subscribe by adding `connections-1m` and `connections-1m-tls` to `tests` in your `meta.json`. `connections-5m` also needs the entry on the [allowlist](#con-5m-by-allowlist).
