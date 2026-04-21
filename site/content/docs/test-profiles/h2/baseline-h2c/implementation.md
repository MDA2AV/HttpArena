---
title: Implementation Guidelines
---
{{< type-rules production="Must use the framework standard HTTP/2 cleartext (h2c) configuration. No custom ALPN settings or TLS cipher tuning (TLS isn't used on this port)." tuned="May tune HTTP/2 stream limits, window sizes, and connection parameters." engine="No specific rules. Ranked separately from frameworks." >}}

Same `/baseline2?a=…&b=…` sum endpoint as the HTTP/2-TLS baseline, served as HTTP/2 **cleartext** — no TLS, h2 framing from the first byte. This matches the deployment pattern behind TLS-terminating load balancers (ALB → backend, nginx → app server) and inside service meshes where mTLS is handled by sidecars.

**Port:** 8082
**Connections:** 256, 1,024
**Concurrent streams per connection:** 100
**Negotiation:** prior-knowledge (`h2load -p h2c`)

## Workload

`GET /baseline2?a=1&b=1` sent over HTTP/2 cleartext. h2load opens multiple connections, each multiplexing up to 100 concurrent streams. The first bytes on every connection are the h2 preface — there is no HTTP/1.1 Upgrade dance and no ALPN (no TLS).

## What it measures

- HTTP/2 framing + HPACK + multiplexing *without* TLS overhead
- Protocol implementation cost in isolation — the delta against `baseline-h2` is roughly the TLS cost
- How cleanly the framework refuses non-h2 traffic on a port declared h2c-only

## The port must be h2c-only

Validation explicitly checks that port 8082 refuses plain HTTP/1.1 requests. A server that dual-serves h1 and h2c on the same port would let the benchmark measure whichever protocol the client picked — useless for ranking. Frameworks that want to expose h1 too must do it on a **different** port.

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
| Connections | 256, 1,024 |
| Streams per connection | 100 (`-m 100`) |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | h2load with `-p h2c` |
