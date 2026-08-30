---
title: Implementation Guidelines
seo_title: "Echo-10K Benchmark: Implementation Guide"
description: "How the 10 KB TLS echo profile is run, what it measures, and the type-specific rules that apply to it."
---
{{< type-rules standard="Must read the request body through the framework's standard body API and write it back through the standard response API. Streaming is allowed and encouraged. What is not allowed is answering without reading: a response assembled from Content-Length, or a canned buffer of the right size, is not an echo." tuned="May stream, use vectored writes, reuse buffers, or hand the bytes back with zero copies. The body must still be the bytes that arrived - the profile is defined by what comes back, not by how it is moved." engine="Same as above. An engine is free to splice or reuse the receive buffer directly for the response; that is the point of the profile." infrastructure="A proxy may stream the body through to an origin and back, or echo it itself. Either way the bytes returned must be the bytes sent." >}}


Both directions at once. A 10 KB body is posted over TLS and must come back verbatim, so a single request exercises the read path, the write path, and the TLS record layer **in both directions**.

**Endpoint:** `POST /echo` · **Port:** `8081` (TLS) · **Body:** 10 KB · **Connections:** 512 · **Offered rate:** 50,000 req/s

## The contract

```
POST /echo HTTP/1.1
Content-Type: application/octet-stream
Content-Length: 10240

<10240 bytes>
```

The response is those bytes, unchanged:

```
HTTP/1.1 200 OK
Content-Length: 10240

<the same 10240 bytes>
```

The endpoint is deliberately named `/echo` rather than after the profile, so other profiles can drive it later at different sizes or framings without a second route to implement.

## Why 10 KB, and not 20 MB

The profile this replaces posted bodies of 500 KB to 20 MB and measured ingest alone. At that size it had stopped saying anything about frameworks:

| entry | rps @256c | ingest |
|---|---|---|
| humming-bird | 3,156 | 25.0 GB/s |
| vibe.d | 3,104 | 24.6 GB/s |
| actix | 3,062 | 24.3 GB/s |
| go-stdlib | 2,936 | 23.3 GB/s |

A **7% spread across 99 entries** spanning D, Rust, Go, Ruby and C++ - which is what it looks like when a benchmark is measuring `memcpy` and the loopback rather than the server.

10 KB in and 10 KB out is 20 KB per request. That is far enough below the box's bandwidth ceiling that what the column reports is per-request framework overhead rather than `memcpy` throughput, which is the failure the 20 MB profile fell into.

It is deliberately **one TLS record** (16 KB is the maximum record payload) and one socket write in each direction. This profile is not trying to exercise multi-record handling or partial writes - the body is small enough that a correct implementation does each side in a single pass, so what is left in the measurement is the cost of getting a request in and a response out, doubled.

## Content-Length, not chunked

The benchmark sends `Content-Length`, which is what a real client sends for a body of known size. Chunked exists for bodies whose length is not known yet; at this size it almost always is, so `Content-Length` is the realistic framing rather than merely the convenient one.

**Chunked is covered by [validation](../validation/) instead**, and it is not optional there: a chunked body must be decoded and echoed byte-for-byte, at 10 KB and at 100 KB. An implementation that reads the body length from `Content-Length` rather than from the framing will pass the benchmark and fail validation.

## Paced, not open-loop

The other H1 profiles ask how fast a server can go. This one pins the offered rate at **50,000 req/s across 512 held connections** and asks what serving exactly that cost - CPU, memory and latency - so the variable between entries is cost rather than throughput. An entry that cannot hold the rate reports it in `rate_ratio` instead of quietly returning a smaller number that reads like a like-for-like result; a run whose `rate_ratio` is well under 1 was not offered the load the profile claims and is not comparable.

## What it measures

- **Copies and allocations.** A framework that buffers the whole body, then copies it into a response buffer, then copies that into the socket, pays three times. One that streams the bytes back as they arrive pays once. A per-request allocation of this size shows up here as GC pressure on managed runtimes.
- **Streaming versus buffering.** Memory per connection is flat for a streaming implementation and proportional to body size for a buffering one.
- **The TLS record layer in both directions.** Encrypt and decrypt, on every request, at a size that spans several records. kTLS offload shows up here.
- **Cost per request, doubled.** Every request pays for a body read and a body write. At 10 KB neither side is bandwidth-bound, so the number is dominated by what the framework spends framing, allocating and moving one small body twice.

## Anti-cheat

zrk posts **one constant body** - it takes a single `-b @FILE`, so unlike the wrk script this profile previously ran there is no rotation to make a canned reply wrong most of the time. A server that cached the first response, or that sized a reply from `Content-Length` without ever reading the body, would not be caught by the benchmark itself.

**The guard is therefore entirely in [validation](../validation/)**, which posts **random** bodies and compares them byte for byte, at 1 B, 1 KB, 10 KB (the benchmark's own size) and 100 KB, plus a chunked body that cannot be sized from `Content-Length` at all, plus an empty one. Answering without reading is not penalised there, it fails.

That is a real trade for the paced measurement below, and worth stating plainly: the benchmark run no longer proves the bytes came back, validation does.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `POST /echo` |
| Port | 8081 (TLS, ALPN `http/1.1`) |
| Body | 10 KB (10,240 bytes), `application/octet-stream` |
| Framing | `Content-Length` both ways |
| Connections | 512 |
| Offered rate | 50,000 req/s (`ZRK_RATE_ECHO_10K`) |
| Duration | 5s |
| Runs | 3, best kept |
| Load generator | [zrk](/docs/load-generators/h1/zrk/) — paced, `-m POST -b @<body>` |
| Metrics | rps, `rate_ratio`, latency (p50/p99/p99.9), response bandwidth, and ingest bandwidth as `rps × body size` |

wrk reports only the bytes it *read*, so its `Transfer/sec` is the download half of the echo. The ingest half is reconstructed in `benchmark.sh` from the request size, which is constant - without that the profile would report half the I/O it actually moves.

### Composite

**Scored**, on the same basis as the two fixed-rate latency profiles rather than on requests per second - because the rate is pinned, every entry that holds it delivers the same rps, so throughput cannot separate them. What separates them is what holding it cost:

```
rateFactor = min(1, achieved_rps / 47,500)
quality    = 0.60 x cpuScore + 0.25 x p99Score + 0.15 x p999Score
score      = 100 x rateFactor x quality
```

Full credit at 47,500 req/s, which is 95% of the 50,000 offered - the generator never quite reaches its own target, so the threshold sits below it. `cpuScore` is a plain ratio of the best CPU-per-request to this entry's; the two tails use a decade scale, which keeps the field separable where a ratio would collapse to zero for everyone but the leader.

An entry that does not hold the rate is cut proportionally by `rateFactor`, so a run that was never offered the load it claims cannot score as though it were.

Scored by [`scripts/latency_score.py`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/latency_score.py); run `python3 scripts/latency_score.py --table --profile echo-10k` to score the published results.
