---
title: Implementation Guidelines
seo_title: "CON-RAMP Benchmark: Implementation Guide"
description: "What to implement, what the listener must allow, how the ramp is run, what is measured, and how CON-RAMP (connections-ramp-h1) is scored."
---
{{< type-rules standard="Nothing new to implement - the profile drives `GET /baseline11`, which the baseline profile already specifies and validates. It asks for a server that can accept two million connections over two minutes while a small active part of them stays under a 2 ms p99: it must listen on every loopback address (0.0.0.0 or [::], not 127.0.0.1 or localhost) and must not cap connections below the fleet. Closing a connection that has been idle for at least 30 seconds is allowed and counted; closing one sooner is not, and is validated." tuned="May size buffers, pools, accept loops and timeouts for the fleet, raise connection caps, and set the runtime's heap and GC options, but an idle connection still has to be kept for at least 30 seconds. All of it is charged: memory is read from the container, which is capped at 128 GiB." engine="Same as above. An engine with a fixed-size connection table, or one that preallocates a full read buffer per connection, finds out here." >}}

`GET /baseline11?a=1&b=2` is the only request. The fleet is two million connections, opened evenly over two minutes: **95% of them are idle** - they connect, send the one request, read its answer, and are never used or reopened - and **5% are active**: 100,000 connections that carry a fixed 100,000 req/s between them. 4,096 of the active ones are open before the ramp starts; the rest of them, and every idle one, open on the way up.

| | |
|---|---|
| Profile | `connections-ramp-h1` |
| Connections | 2,000,000 over 127.0.0.1-.64, 31,250 on each address |
| Idle | 95%: one request each, then nothing |
| Active | 5% (100,000): 100,000 req/s, held throughout |
| Ramp | 4,096 active connections first, then everything else evenly over 120 s |
| Window | 130 s: the ramp, then ten seconds of the full fleet |
| p99 limit | 2 ms, on the active connections, read every 5 s |
| Load generator | one gcannon, `--ramp-up`, `--idle`, `--rate` (0.10.0 or later) |
| Scored | no, reference-only while the first field is measured |

**Endpoint:** `GET /baseline11?a=1&b=2` · **CPU:** cpuset `0-31,64-95` · **Memory cap:** 128 GiB

## What your server must allow

- **Listen on every address.** One client address can hold about 64.5K connections to one server address and port, so the fleet is spread over loopback addresses, 31,250 connections on each: `127.0.0.1`-`127.0.0.64`. A listener on `0.0.0.0` or `[::]` accepts on all of them. [Validation](../validation) checks this, and the run checks it again before it starts.
- **No connection cap below the fleet.** Raise any per-worker or global connection limit above two million.
- **File descriptors.** The container is started with `--ulimit nofile` at 8,388,608, capped at the host's `fs.nr_open`. A server that lowers its own limit, or spends more than one descriptor per connection, has to leave room for the fleet.
- **Keep an idle connection for at least 30 seconds.** An idle connection sends one request and is never used again, and closing it after that is a decision the profile measures - but not before 30 seconds. The keep-alive timeout of your server has to be above that (the default is 5 seconds in actix-web and node:http, 75 in nginx, 120 in Go's fib, 130 in Kestrel): a short one holds a few percent of the fleet, and the profile would be measuring how fast it opens and closes connections. [Validation](../validation/#idle-connections-are-kept) checks it, and [so does the run](#the-idle-minimum). The active ones send one request a second, well inside any timeout this allows.

## How the load is run

[gcannon](/docs/load-generators/h1/gcannon/) opens the fleet and drives it, under [`scripts/conn_hold.py`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/conn_hold.py), which probes the listener, refuses a run the host cannot hold, raises the open-file limit, and reads the server's CPU from its cgroup over the measured window.

| gcannon option | Value |
|---|---|
| `-c` / `-t` | 2,000,000 / 64 |
| `--idle` | 95% |
| `--ramp` / `--ramp-up` | 4096 / 120s |
| `--rate` | 100,000 |
| `--addr-span` | 64 |
| `--connect-limit` (per thread) | 64 |
| `--warmup-max` / `--settle` | 60s / 30s |
| `-d` | 130s |

The 4,096 active connections open in the warmup and carry the offered rate for 30 seconds, which lets a JIT, a garbage collector and the caches settle before anything counts. The window then opens, and the ramp with it: the rest of the active connections and all the idle ones open evenly over 120 seconds, about 16,600 a second. The rate stays at 100,000 req/s throughout, paced by thread over whichever active connections are open, so the total does not depend on how many that is. Latency counts from each request's scheduled time.

Each interval (five seconds), gcannon reports how many connections are open, how many idle ones have been opened and closed so far, and the active connections' rate and latency in it. Those lines are the result.

**The p99 limit is the harness's.** gcannon does not stop at it. The run takes the full two minutes, and the harness then finds where the intervals crossed 2 ms: an interval over the limit, followed by another that is too (or at the end of the window), is where the ramp ends. A single noisy interval between two good ones is ignored. An interval whose rate falls short of 90% of the offered one counts as over the limit as well: a server that has stopped answering has no p99 worth the name.

### The idle minimum

Closing an idle connection is allowed, but only one that has been idle for at least 30 seconds. The same intervals say whether a server did: gcannon reports how many idle connections it has opened and how many the server has closed so far, and since a server that gives each connection the same time closes them oldest first, the time since the n-th was opened, for the n-th close, is how long it was kept. An interval in which that is under 29 seconds - a second of slack for timers that are coarse - ends the ramp like an interval over the p99 limit does, with `ramp_stop` `shed`. It is the average over the closes so far, so a few stray resets, under 1% of the idle connections opened, do not count. A server with a short timeout is scored on what the ramp had opened before its first closes: nothing with a five second one, about 340,000 connections with a twenty second one.

The run starts on a fresh server, once the host's TCP socket count is back near what it was before the first profile, as on the [held-connection profiles](../../connections/implementation/#how-the-load-is-run). There is one run, not several: the ramp is the measurement, and a warm-up precedes it.

## What is measured

| field | meaning |
|---|---|
| `ramp_reached` | connections opened by the last interval that held the 2 ms p99, idle ones included: every one the ramp had opened, whether or not the server has closed some of them since. The score is this |
| `connections_open` | the most of them that were open at once, in any interval up to then ("Peak open" on the board) |
| `idle_closed` | idle connections the server had closed by then ("Closed" on the board) |
| `ramp_stop` | what ended the ramp: `p99` (over the limit), `rate` (short of it), `shed` (an idle connection closed before 30 seconds), or `ceiling` (the whole two million were opened within it) |
| `memory` | the container's peak memory across the run |
| `cpu_usec`, `cpu_per_req_us` | server CPU microseconds over the window, read from cgroup v2 `cpu.stat`, and divided by requests served |
| `p50_latency`, `p99_latency`, `avg_latency`, `p99_9_latency` | the active connections' over the whole run, coordinated-omission corrected. The per-interval p99 that stops the ramp is the one in the log |
| `rate_ratio` | achieved over offered across the run |

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /baseline11?a=1&b=2` (GET only, no body) |
| Connections | 2,000,000 over 127.0.0.1-127.0.0.64, 31,250 per address |
| Idle | 95%, one request each |
| Offered rate | 100,000 req/s over the active connections |
| Ramp | 120s, uniform, after 4,096 active connections |
| p99 limit | 2 ms, read on each 5 s interval |
| Idle connections | kept for at least 30 s |
| CPU | cpuset `0-31,64-95` (32 cores, both threads) |
| Memory cap | 128 GiB (`CONN5M_MEM_LIMIT`), a server above it is OOM-killed |
| Window | 130s |
| Runs | 1, after a 30 s warm-up at the offered rate on the floor of the fleet; repeating the two-minute ramp would not say more |
| Load generator | [gcannon](/docs/load-generators/h1/gcannon/) 0.10.0 or later |

## Scoring

```
score = 100 x min(1, ramp_reached / 2,000,000)
```

How many connections the ramp opened before the active ones' p99 went over 2 ms. A server that opened all two million scores 100; one that closed idle connections after 30 seconds and held its active p99 all the way scores 100 as well, and the Peak open and Closed columns show how it got there. Computed by [`scripts/latency_score.py`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/latency_score.py); the board computes the same. Reference-only: measured and shown, part of no composite.

Subscribe by adding `connections-ramp-h1` to `tests` in your `meta.json`.
