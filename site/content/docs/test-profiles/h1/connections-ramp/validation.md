---
title: Validation
seo_title: "CON-RAMP Benchmark: Validation Checks"
description: "How correctness is established for CON-RAMP, and the listener checks that are specific to it."
---

The profile drives `GET /baseline11?a=1&b=2`, the baseline endpoint unchanged, so an entry subscribed to `connections-ramp-h1` is run through the full [baseline validation suite](../../baseline/validation): the arithmetic, the `Content-Type`, the randomized-input anti-cheat, the TCP fragmentation checks, and the exhaustive per-byte fragmentation sweep.

## A listener on every address

One client address can hold only about 64.5K connections to one server address and port, so the ramp's two million are spread over `127.0.0.1` to `127.0.0.64`. The check is the one the [held-connection profiles](../../connections/validation/#a-listener-on-every-address) use, at both ends of the wider range those take:

| check | request | expected |
|---|---|---|
| GET /baseline11 on 127.0.0.2 | `GET http://127.0.0.2:8080/baseline11?a=13&b=42` | `55` |
| GET /baseline11 on 127.0.0.160 | `GET http://127.0.0.160:8080/baseline11?a=13&b=42` | `55` |

To pass, listen on `0.0.0.0` or `[::]` (an IPv6 wildcard listener accepts IPv4 connections too, unless it sets `IPV6_V6ONLY`). The benchmark repeats the probe on `127.0.0.2` and `127.0.0.64` before it launches anything, and a server that fails it gets an empty row with the reason rather than millions of connect errors.

## Idle connections are kept

95% of the fleet is idle after its first request, and a server that closes such a connection within a few seconds never holds more than a few percent of it. So the check opens 32 connections, sends one request on each, leaves them alone for 29 seconds and sends a second request on the same connections. Both have to be answered correctly, and a connection the server closed in the meantime fails with how long it lasted.

| check | what it does | expected |
|---|---|---|
| idle connections kept for 30 seconds | 32 connections: one `GET /baseline11`, 29 s idle, a second `GET /baseline11` on the same connection | `200` and the right sum both times, none closed in between |

The 29 rather than 30 seconds is a second of slack for timers that are coarse. Keep-alive timeouts are set on the server: the default is 5 seconds in actix-web and node:http, for example, which fails. The check takes half a minute, and only entries subscribed to `connections-ramp-h1` run it. `python3 scripts/validate-keepalive.py localhost 8080` runs it on its own.

## What the run checks

- **Opened, not just offered.** gcannon counts each connection it opens and each idle one the server closes, so Reached, Peak open and Closed are what happened.
- **Idle connections are kept.** The run is held to the same 30 seconds as the check above: an interval in which the server has closed idle connections younger than that (29, for coarse timers) ends the ramp.
- **`rate_ratio`** is published with the row, and an interval under 90% of the offered rate counts against the ramp whatever its p99.
- **CPU from outside.** As on the other fixed-rate profiles, the harness reads the CPU from the container's cgroup rather than taking it from anything inside the container, over the window only.
