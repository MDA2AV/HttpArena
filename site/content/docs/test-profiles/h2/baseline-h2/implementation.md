---
title: Implementation Guidelines
seo_title: "HTTP/2 Baseline Benchmark (TLS) — Implementation Guide"
description: "Endpoint contract, request and response shapes, and the anti-cheat constraints a framework must satisfy for the HTTP/2 TLS baseline benchmark."
---
{{< type-rules standard="Must use the framework standard HTTP/2 + TLS configuration. No custom ALPN settings or TLS cipher tuning." tuned="May optimize TLS settings, HTTP/2 stream limits, window sizes, and connection parameters." engine="No specific rules. Ranked separately from frameworks." infrastructure="Configuration is free - worker counts, buffer sizes, event-loop and socket tuning are all allowed. ALPN, stream limits, window sizes and cipher selection are all fair game. HTTP/2 must be the server's own implementation: the endpoint may be a loaded module, the protocol may not be. The endpoint must be answered by a module or handler loaded into the server itself, not proxied to an application process behind it - an upstream app makes it a gateway entry, not an infrastructure one." >}}


Same workload as the HTTP/1.1 baseline - query parameter parsing and sum computation - but over encrypted HTTP/2 connections using TLS and ALPN negotiation.

**Connections:** 256, 1,024
**Concurrent streams per connection:** 100

## Workload

`GET /baseline2?a=1&b=1` sent over HTTP/2 with TLS. The load generator ([h2load](https://nghttp2.org/documentation/h2load-howto.html)) opens multiple connections, each multiplexing up to 100 concurrent streams.

## What it measures

- HTTP/2 multiplexing efficiency
- TLS handshake and encryption overhead
- How frameworks handle many concurrent streams per connection
- HPACK header compression performance

## Expected request/response

```
GET /baseline2?a=1&b=1 HTTP/2
```

```
HTTP/2 200 OK
Content-Type: text/plain

2
```

## How it differs from baseline

| | Baseline (HTTP/1.1) | Baseline (HTTP/2) |
|---|---|---|
| Protocol | HTTP/1.1 plaintext | HTTP/2 over TLS |
| Connections | 512 - 4,096 | 256 - 1,024 |
| Requests per connection | 1 at a time | 100 concurrent streams |
| Load generator | gcannon | h2load |
| Port | 8080 | 8443 |

HTTP/2 uses far fewer connections because each connection multiplexes many streams. The lower connection counts reflect real-world HTTP/2 usage patterns.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /baseline2?a=1&b=1` |
| Connections | 256, 1,024 |
| Streams per connection | 100 (`-m 100`) |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | h2load |
