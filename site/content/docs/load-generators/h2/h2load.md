---
title: h2load
---

[h2load](https://nghttp2.org/documentation/h2load-howto.html) is part of the nghttp2 project and is used for the `baseline-h2` profile. It supports HTTP/2 multiplexing with configurable concurrent streams per connection.

## Installation

```bash
sudo apt install nghttp2-client
```

## How it's used

```bash
h2load https://localhost:8443/baseline2?a=1&b=1 -c 256 -m 100 -t 128 -D 5s
```

| Flag | Description | Value |
|------|-------------|-------|
| `-c` | Number of connections | 256 or 1,024 |
| `-m` | Max concurrent streams per connection | 100 |
| `-t` | Threads | 128 |
| `-D` | Duration | 5s |

## Why h2load?

gcannon is HTTP/1.1 only (by design - it uses raw request templates and io_uring for maximum throughput). h2load handles TLS negotiation, ALPN, HPACK header compression, and HTTP/2 stream multiplexing natively.
