---
title: Validation
seo_title: "Held-Connection Benchmarks (CON-1M, CON-1M-TLS, CON-5M): Validation Checks"
description: "How correctness is established for the held-connection profiles CON-1M, CON-1M-TLS and CON-5M, and the listener checks that are specific to them."
---

The profiles drive `GET /baseline11?a=1&b=2`, the baseline endpoint unchanged, so an entry subscribed to `connections-1m`, `connections-1m-tls` or `connections-5m` is run through the full [baseline validation suite](../baseline/validation): the arithmetic, the `Content-Type`, the randomized-input anti-cheat, the TCP fragmentation checks, and the exhaustive per-byte fragmentation sweep.

## A listener on every address

One client address can hold only about 64.5K connections to one server address and port, so the fleet is spread over loopback addresses: CON-1M's million over `127.0.0.1` to `127.0.0.32`, CON-5M's five million over `127.0.0.1` to `127.0.0.160`. A server bound to `127.0.0.1` or `localhost` passes every baseline check and refuses all but the first of those addresses, so for an entry subscribed to `connections-1m` or `connections-5m`, validation sends the baseline request to both ends of the wider range:

| check | request | expected |
|---|---|---|
| GET /baseline11 on 127.0.0.2 | `GET http://127.0.0.2:8080/baseline11?a=13&b=42` | `55` |
| GET /baseline11 on 127.0.0.160 | `GET http://127.0.0.160:8080/baseline11?a=13&b=42` | `55` |

To pass, listen on `0.0.0.0` or `[::]` (an IPv6 wildcard listener accepts IPv4 connections too, unless it sets `IPV6_V6ONLY`). The benchmark repeats the probe before it launches anything, and a server that fails it gets an empty row with the reason rather than millions of connect errors.

## Over TLS

CON-1M-TLS (`connections-1m-tls`) spreads its million over `127.0.0.1` to `127.0.0.32` on the h1 TLS port, so both ends of that range are asked there, over TLS 1.3. The load generator offers no other version, so a server without it would fail every handshake of the run.

| check | request | expected |
|---|---|---|
| GET /baseline11 over TLS 1.3 on 127.0.0.2 | `GET https://127.0.0.2:8081/baseline11?a=13&b=42` (TLS 1.3, HTTP/1.1) | `55` |
| GET /baseline11 over TLS 1.3 on 127.0.0.32 | `GET https://127.0.0.32:8081/baseline11?a=13&b=42` (TLS 1.3, HTTP/1.1) | `55` |

## What the run checks

- **Held, not just offered.** On CON-5M and CON-1M-TLS gcannon counts the connections still open at the end of the window; on CON-1M the harness counts the server's established sockets on port 8080 after it. Either way, a server that dropped connections, or never accepted them, shows its real count in the Held column.
- **`rate_ratio`.** Achieved over offered in the window, published with the row. A connection that never opened sends nothing, so a fleet only partly held falls short here as well as in Held, and the score falls with it.
- **CPU from outside.** As on the other fixed-rate profiles, the harness reads the CPU from the container's cgroup rather than taking it from anything inside the container, over the window only.
