---
title: Implementation Guidelines
seo_title: "Echo-100K Benchmark: Implementation Guide"
description: "How the 100 KB TLS echo profile is run, what it measures, and the type-specific rules that apply to it."
---
{{< type-rules standard="Must read the request body through the framework's standard body API and write it back through the standard response API. Streaming is allowed and encouraged. What is not allowed is answering without reading: a response assembled from Content-Length, or a canned buffer of the right size, is not an echo." tuned="May stream, use vectored writes, reuse buffers, or hand the bytes back with zero copies. The body must still be the bytes that arrived - the profile is defined by what comes back, not by how it is moved." engine="Same as above. An engine is free to splice or reuse the receive buffer directly for the response; that is the point of the profile." infrastructure="A proxy may stream the body through to an origin and back, or echo it itself. Either way the bytes returned must be the bytes sent." >}}


Both directions at once. A 100 KB body is posted over TLS and must come back verbatim, so a single request exercises the read path, the write path, and the TLS record layer **in both directions**.

**Endpoint:** `POST /echo` · **Port:** `8081` (TLS) · **Body:** 100 KB · **Connections:** 512 · **Offered rate:** 50,000 req/s

## The contract

```
POST /echo HTTP/1.1
Content-Type: application/octet-stream
Content-Length: 102400

<102400 bytes>
```

The response is those bytes, unchanged:

```
HTTP/1.1 200 OK
Content-Length: 102400

<the same 102400 bytes>
```

The endpoint is deliberately named `/echo` rather than after the profile, so other profiles can drive it later at different sizes or framings without a second route to implement.

## Why 100 KB, and not 20 MB

The profile this replaces posted bodies of 500 KB to 20 MB and measured ingest alone. At that size it had stopped saying anything about frameworks:

| entry | rps @256c | ingest |
|---|---|---|
| humming-bird | 3,156 | 25.0 GB/s |
| vibe.d | 3,104 | 24.6 GB/s |
| actix | 3,062 | 24.3 GB/s |
| go-stdlib | 2,936 | 23.3 GB/s |

A **7% spread across 99 entries** spanning D, Rust, Go, Ruby and C++ - which is what it looks like when a benchmark is measuring `memcpy` and the loopback rather than the server.

100 KB in and 100 KB out is 200 KB per request, which leaves the box's bandwidth ceiling far enough away that per-request framework overhead is still visible. It is also large enough to force the things worth measuring: **around seven TLS records** (16 KB is the maximum record payload) and more than one socket buffer, so partial reads, multi-record handling and partial writes all happen on every request.

## Content-Length, not chunked

The benchmark sends `Content-Length`, which is what a real client sends for a body of known size. Chunked exists for bodies whose length is not known yet; at 100 KB it almost always is, so `Content-Length` is the realistic framing rather than merely the convenient one.

**Chunked is covered by [validation](../validation/) instead**, and it is not optional there: a 100 KB chunked body must be decoded and echoed byte-for-byte. An implementation that reads the body length from `Content-Length` rather than from the framing will pass the benchmark and fail validation.

## Paced, not open-loop

The other H1 profiles ask how fast a server can go. This one pins the offered rate at **50,000 req/s across 512 held connections** and asks what serving exactly that cost - CPU, memory and latency - so the variable between entries is cost rather than throughput. An entry that cannot hold the rate reports it in `rate_ratio` instead of quietly returning a smaller number that reads like a like-for-like result; a run whose `rate_ratio` is well under 1 was not offered the load the profile claims and is not comparable.

## What it measures

- **Copies.** A framework that buffers the whole body, then copies it into a response buffer, then copies that into the socket, pays three times. One that streams the bytes back as they arrive pays once.
- **Streaming versus buffering.** Memory per connection is flat for a streaming implementation and proportional to body size for a buffering one. At 4096 connections that is the difference between a few megabytes and several gigabytes.
- **The TLS record layer in both directions.** Encrypt and decrypt, on every request, at a size that spans several records. kTLS offload shows up here.
- **Partial writes.** 100 KB does not leave in one `write`. A handler that assumes it does will stall or corrupt under load.

## Anti-cheat

zrk posts **one constant body** - it takes a single `-b @FILE`, so unlike the wrk script this profile previously ran there is no rotation to make a canned reply wrong most of the time. A server that cached the first response, or that sized a reply from `Content-Length` without ever reading the body, would not be caught by the benchmark itself.

**The guard is therefore entirely in [validation](../validation/)**, which posts **random** bodies and compares them byte for byte, at 1 B, 1 KB and 100 KB, plus a 100 KB chunked body that cannot be sized from `Content-Length` at all, plus an empty one. Answering without reading is not penalised there, it fails.

That is a real trade for the paced measurement below, and worth stating plainly: the benchmark run no longer proves the bytes came back, validation does.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `POST /echo` |
| Port | 8081 (TLS, ALPN `http/1.1`) |
| Body | 100 KB (102,400 bytes), `application/octet-stream` |
| Framing | `Content-Length` both ways |
| Connections | 512 |
| Offered rate | 50,000 req/s (`ZRK_RATE_ECHO_100K`) |
| Duration | 5s |
| Runs | 3, best kept |
| Load generator | [zrk](/docs/load-generators/h1/zrk/) — paced, `-m POST -b @<body>` |
| Metrics | rps, `rate_ratio`, latency (p50/p99/p99.9), response bandwidth, and ingest bandwidth as `rps × body size` |

wrk reports only the bytes it *read*, so its `Transfer/sec` is the download half of the echo. The ingest half is reconstructed in `benchmark.sh` from the request size, which is constant - without that the profile would report half the I/O it actually moves.

### Composite

**Reference-only for now**: measured, published and shown, but not contributing to the composite score. The profile this replaces was unscored too, and this one should be run board-wide before it decides anything.
