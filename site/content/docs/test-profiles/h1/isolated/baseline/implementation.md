---
title: Implementation Guidelines
seo_title: "Baseline Throughput Benchmark: Implementation Guide"
description: "Endpoint contract, request and response shapes, and the anti-cheat constraints a framework must satisfy for the HTTP/1.1 baseline throughput benchmark."
---
{{< type-rules standard="Must use the framework standard HTTP server with default configuration. No custom TCP tuning, no experimental flags, no worker count beyond framework defaults." tuned="May adjust worker counts, thread pools, TCP socket options, and use framework-specific performance flags. Custom buffer sizes allowed." engine="No specific rules. Ranked separately from frameworks." infrastructure="Configuration is free - worker counts, buffer sizes, event-loop and socket tuning are all allowed. The endpoint must be answered by a module or handler loaded into the server itself, not proxied to an application process behind it - an upstream app makes it a gateway entry, not an infrastructure one." >}}


The primary throughput benchmark. Each connection sends one request at a time over persistent keep-alive connections.

**Connections:** 512, 4,096
**CPU limit:** 64 threads (container pinned to cores 0-31, 64-95 via `--cpuset-cpus`)

## Workload

A mix of three request types, rotated across connections:

- `GET /baseline11?a=13&b=42` - query parameter parsing, response: sum of values
- `POST /baseline11?a=13&b=42` with Content-Length body - query params + body parsing
- `POST /baseline11?a=13&b=42` with chunked Transfer-Encoding body - chunked decoding

This exercises the full HTTP handling path: request line parsing, header parsing, query string extraction, body reading (both Content-Length and chunked), integer arithmetic, and response serialization.

## Expected request/response

GET - sum of query parameters:

```
GET /baseline11?a=13&b=42 HTTP/1.1
```

```
HTTP/1.1 200 OK
Content-Type: text/plain

55
```

POST with body - sum of query parameters + body:

```
POST /baseline11?a=13&b=42 HTTP/1.1
Content-Type: text/plain
Content-Length: 2

20
```

```
HTTP/1.1 200 OK
Content-Type: text/plain

75
```

## What it measures

- Raw request throughput under ideal conditions
- Full HTTP parsing pipeline performance
- Keep-alive connection handling efficiency
- How frameworks scale with increasing connection counts
