---
title: h2load
seo_title: "h2load: HTTP/2 Load Generator"
description: "h2load from the nghttp2 project drives every HTTP/2 profile in HttpArena, with configurable concurrent streams per connection."
---

[h2load](https://nghttp2.org/documentation/h2load-howto.html) is part of the nghttp2 project and drives every HTTP/2 profile: `baseline-h2`, `static-h2`, `baseline-h2c`, `json-h2c`, `unary-grpc`, `unary-grpc-tls`, `gateway-64` and `production-stack`. It supports HTTP/2 multiplexing with configurable concurrent streams per connection.

## Installation

```bash
sudo apt install nghttp2-client
```

## How it's used

For `baseline-h2`:

```bash
h2load https://localhost:8443/baseline2?a=1&b=1 -c 256 -m 100 -t 64 -D 5s
```

| Flag | Description | Value |
|------|-------------|-------|
| `-c` | Number of connections | per profile, e.g. 256 or 1,024 |
| `-m` | Max concurrent streams per connection | 100 for baseline and gRPC, 32 for the multi-URI profiles, 16 for production-stack reads |
| `-t` | Threads | 64 (`H2THREADS`) |
| `-D` | Duration | 5s |
| `-i` | URI list file, rotated per request | multi-URI profiles (`static-h2`, `json-h2c`, `gateway-64`, `production-stack`) |
| `-p h2c` | Cleartext HTTP/2 with prior knowledge | `baseline-h2c`, `json-h2c` |

## Why h2load?

gcannon is HTTP/1.1 only (by design - it uses raw request templates and io_uring for maximum throughput). h2load handles TLS negotiation, ALPN, HPACK header compression, and HTTP/2 stream multiplexing natively.
