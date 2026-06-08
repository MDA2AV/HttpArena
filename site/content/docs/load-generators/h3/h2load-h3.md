---
title: h2load-h3
---

[h2load](https://nghttp2.org/documentation/h2load-howto.html) is part of the nghttp2 project. HttpArena uses a custom build that links against [ngtcp2](https://github.com/ngtcp2/ngtcp2), [nghttp3](https://github.com/ngtcp2/nghttp3), and [quictls](https://github.com/quictls/openssl) to enable HTTP/3 (QUIC) support. This build is invoked as `h2load-h3` and drives both `baseline-h3` and `static-h3` profiles.

## Installation

The h2load binary shipped by Linux distributions does not include HTTP/3. HttpArena builds its own image:

```bash
docker build -f docker/h2load-h3.Dockerfile -t h2load-h3:local docker/
```

For native execution under `benchmark.sh`, the binary and runtime libraries are extracted from the image to `/opt/h2load-h3/` and a wrapper is installed at `/usr/local/bin/h2load-h3` that sets `LD_LIBRARY_PATH` and execs the binary.

## How it's used

```bash
h2load-h3 --alpn-list=h3 https://localhost:8443/baseline2?a=1&b=1 \
  -c 64 -m 64 -t 64 -D 5s
```

For multi-URI static file tests:

```bash
h2load-h3 --alpn-list=h3 -i requests/static-h2-uris.txt \
  -H "Accept-Encoding: br;q=1, gzip;q=0.8" \
  -c 64 -m 64 -t 64 -D 5s
```

| Flag | Description | Value |
|------|-------------|-------|
| `--alpn-list=h3` | Negotiate HTTP/3 over QUIC | - |
| `-c` | Number of QUIC connections | 64 |
| `-m` | Max concurrent streams per connection | 64 |
| `-t` | Worker threads | 64 |
| `-D` | Duration | 5s |
| `-i` | URI list file (multi-URL rotation) | - |

## Why h2load-h3 instead of oha?

The previous HTTP/3 driver (`oha`) topped out at ~85k req/s and could not saturate any framework - its single-threaded `quinn` client became the bottleneck before the server. h2load-h3 uses ngtcp2's multi-threaded worker model with `sendmmsg` / `recvmmsg` syscall batching, reaching ~580k req/s on the same hardware against the same server (Kestrel + msquic). Both ends are CPU-saturated at that point, which makes the result a fair measurement of the framework's QUIC stack rather than the load generator's.

## Why HTTP/3 results are still lower than HTTP/2

HTTP/3 carries an inherent CPU cost vs HTTP/2 that loopback benchmarks make particularly visible:

- Per-packet AEAD encryption with no kernel TLS offload
- All packet processing in userspace via msquic / ngtcp2
- More syscalls per request than TCP's buffered read/write paths
- Loopback at MTU 1500 - required for proper GSO/GRO behavior - gives no help from a real NIC

Expect a 4-6× gap between h3 and h2 numbers for the same framework. This reflects the state of the QUIC ecosystem in 2026, not a configuration issue.
