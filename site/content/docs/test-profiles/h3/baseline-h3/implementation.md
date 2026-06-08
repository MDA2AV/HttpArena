---
title: Implementation Guidelines
---
{{< type-rules production="Must use the framework native QUIC/HTTP3 support with default configuration." tuned="May tune QUIC parameters, congestion control, and UDP buffer sizes." engine="No specific rules. Ranked separately from frameworks." >}}


The HTTP/3 Baseline profile tests raw throughput over QUIC, the UDP-based transport protocol that powers HTTP/3.

**Connections:** 64

## How it works

1. The load generator ([h2load-h3](/docs/load-generators/h3/h2load-h3/)) connects to the server over HTTP/3 (QUIC) on port 8443
2. Sends `GET /baseline2?a=1&b=1` over 64 connections, each multiplexing 64 streams, across 64 worker threads
3. The server parses query parameters and returns the sum

## What it measures

- **QUIC transport performance** - UDP-based connection handling
- **HTTP/3 framing overhead** - compared to HTTP/1.1 and HTTP/2
- **TLS 1.3 integration** - QUIC mandates encryption
- **Framework QUIC implementation quality** - varies significantly across frameworks

## Expected request/response

```
GET /baseline2?a=1&b=1 HTTP/3
```

```
HTTP/3 200 OK
Content-Type: text/plain

2
```

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /baseline2?a=1&b=1` |
| Connections | 64 |
| Streams per connection | 64 (`-m 64`) |
| Threads | 64 (`H3THREADS`) |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | h2load-h3 (`--alpn-list=h3`) |
| Port | 8443 (TLS + QUIC) |

## Notes

- HTTP/3 support is not universal - only frameworks with native QUIC support participate
- HTTP/3 throughput is typically 4–6× lower than HTTP/2 on the same framework. This reflects the inherent CPU cost of QUIC (per-packet AEAD, no kernel TLS offload, userspace packet processing) - see the [h2load-h3 load generator docs](/docs/load-generators/h3/h2load-h3/) for details
