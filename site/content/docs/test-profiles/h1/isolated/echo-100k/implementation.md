---
title: Implementation Guidelines
seo_title: "Echo-100K Benchmark: Implementation Guide"
description: "How the 100 KB TLS echo profile is run, what it measures, and the type-specific rules that apply to it."
---
{{< type-rules standard="Must read the request body through the framework's standard body API and write it back through the standard response API. Streaming is allowed and encouraged. What is not allowed is answering without reading: a response assembled from Content-Length, or a canned buffer of the right size, is not an echo." tuned="May stream, use vectored writes, reuse buffers, or hand the bytes back with zero copies. The body must still be the bytes that arrived - the profile is defined by what comes back, not by how it is moved." engine="Same as above. An engine is free to splice or reuse the receive buffer directly for the response; that is the point of the profile." infrastructure="A proxy may stream the body through to an origin and back, or echo it itself. Either way the bytes returned must be the bytes sent." >}}


Both directions at once. A 100 KB body is posted over TLS and must come back verbatim, so a single request exercises the read path, the write path, and the TLS record layer **in both directions**.

**Endpoint:** `POST /echo` · **Port:** `8081` (TLS) · **Body:** 100 KB · **Connections:** 32, 256 · **Duration:** 5s

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

The benchmark sends `Content-Length`. That is a property of the load generator rather than a preference: wrk frames the request body itself and always emits `Content-Length`, and setting `Transfer-Encoding` as well produces a request carrying both, which [RFC 9112 §6.1](https://www.rfc-editor.org/rfc/rfc9112#section-6.1) makes an error - wrk rejects it outright.

**Chunked is covered by [validation](../validation/) instead**, and it is not optional there: a 100 KB chunked body must be decoded and echoed byte-for-byte. An implementation that reads the body length from `Content-Length` rather than from the framing will pass the benchmark and fail validation.

## What it measures

- **Copies.** A framework that buffers the whole body, then copies it into a response buffer, then copies that into the socket, pays three times. One that streams the bytes back as they arrive pays once.
- **Streaming versus buffering.** Memory per connection is flat for a streaming implementation and proportional to body size for a buffering one. At 256 connections that is the difference between a few megabytes and a few hundred.
- **The TLS record layer in both directions.** Encrypt and decrypt, on every request, at a size that spans several records. kTLS offload shows up here.
- **Partial writes.** 100 KB does not leave in one `write`. A handler that assumes it does will stall or corrupt under load.

## Anti-cheat

The load generator rotates **eight distinct 100 KB bodies** rather than sending one repeatedly. With a single constant body a server could return a canned buffer of the right size without ever reading the request, and the measurement would not notice; rotating makes that answer wrong seven times out of eight.

Validation goes further and sends **random** bodies, comparing byte for byte. Answering without reading is not merely penalised, it fails.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `POST /echo` |
| Port | 8081 (TLS, ALPN `http/1.1`) |
| Body | 100 KB (102,400 bytes), `application/octet-stream` |
| Framing | `Content-Length` both ways |
| Connections | 32, 256 |
| Duration | 5s |
| Runs | 3, best kept |
| Load generator | [wrk](/docs/load-generators/h1/wrk/) with `requests/echo-100k-rotate.lua` |
| Metrics | rps, response bandwidth, and ingest bandwidth as `rps × 102400` |

wrk reports only the bytes it *read*, so its `Transfer/sec` is the download half of the echo. The ingest half is reconstructed in `benchmark.sh` from the request size, which is constant - without that the profile would report half the I/O it actually moves.

### Composite

**Reference-only for now**: measured, published and shown, but not contributing to the composite score. The profile this replaces was unscored too, and this one should be run board-wide before it decides anything.
