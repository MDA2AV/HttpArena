---
title: Implementation Guidelines
seo_title: "HTTP/2 Cleartext Baseline Benchmark (h2c): Implementation Guide"
description: "Endpoint contract, request and response shapes, and the anti-cheat constraints a framework must satisfy for the HTTP/2 cleartext baseline benchmark."
---
{{< type-rules standard="Must use the framework standard HTTP/2 cleartext (h2c) configuration. No custom ALPN settings or TLS cipher tuning (TLS isn't used on this port)." tuned="May tune HTTP/2 stream limits, window sizes, and connection parameters." engine="No specific rules. Ranked separately from frameworks." >}}

Same `/baseline2?a=…&b=…` sum endpoint as the HTTP/2-TLS baseline, served as HTTP/2 **cleartext** - no TLS, h2 framing from the first byte. This matches the deployment pattern behind TLS-terminating load balancers (ALB → backend, nginx → app server) and inside service meshes where mTLS is handled by sidecars.

**Port:** 8082
**Connections:** 256, 1,024, 4,096
**Concurrent streams per connection:** 100
**Negotiation:** prior-knowledge (`h2load -p h2c`)

## Workload

`GET /baseline2?a=1&b=1` sent over HTTP/2 cleartext. h2load opens multiple connections, each multiplexing up to 100 concurrent streams. The first bytes on every connection are the h2 preface - there is no HTTP/1.1 Upgrade dance and no ALPN (no TLS).

## What it measures

- HTTP/2 framing + HPACK + multiplexing *without* TLS overhead
- Protocol implementation cost in isolation - the delta against `baseline-h2` is roughly the TLS cost

## Dual-serving h1 on the same port is allowed

Port 8082 may also answer HTTP/1.1. The benchmark cannot pick it up: `h2load -p h2c` writes the HTTP/2 connection preface as the first bytes of every connection and never sends an HTTP/1.1 request, so the h1 path is unreachable during a measured run. Validation asserts the same way, with `curl --http2-prior-knowledge`.

This is what RFC 9113 expects of a cleartext listener - distinguish the h2 preface from an HTTP/1.1 request line and serve each accordingly - and what nginx (1.25.1+), Apache (`Protocols h2c http/1.1`) and h2o all do. The harness itself relies on it: the gRPC profiles run cleartext HTTP/2 against port 8080, the same listener that serves the HTTP/1.1 baseline.

## Expected request/response

```
GET /baseline2?a=1&b=1 HTTP/2
```

```
HTTP/2 200 OK
Content-Type: text/plain

2
```

## How it differs from baseline-h2

| | Baseline (h2) | Baseline (h2c) |
|---|---|---|
| Protocol | HTTP/2 over TLS | HTTP/2 cleartext |
| Port | 8443 | 8082 |
| Negotiation | ALPN (`h2`) | prior-knowledge |
| TLS | required | not used |
| Real-world match | edge-facing servers | backend / service-to-service |

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /baseline2?a=1&b=1` |
| Connections | 256, 1,024, 4,096 |
| Streams per connection | 100 (`-m 100`) |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | h2load with `-p h2c` |
