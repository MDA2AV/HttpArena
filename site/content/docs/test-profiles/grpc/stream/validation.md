---
title: Validation
seo_title: "Server-Streaming gRPC Benchmark — Validation Checks"
description: "The correctness checks validate.sh runs against the server-streaming gRPC benchmark before a framework's results are accepted."
---

The following checks are executed by `validate.sh` for every framework subscribed to the `stream-grpc` or `stream-grpc-tls` tests.

## Server-streaming response shape

Calls `BenchmarkService/StreamSum` with `{a: 13, b: 42, count: 10}` over h2c (or h2 TLS for the `stream-grpc-tls` variant) and verifies:

- The call completes with `OK` status (no `CANCELLED`, `UNAVAILABLE`, etc.)
- Exactly **10** `SumReply` messages are received
- Each `result` equals `13 + 42 + i` where `i` is the zero-based index of the message in the stream

## Large-count stream

Calls `StreamSum` with `count: 5000` and verifies the full stream is delivered without deadline exceeded and the final reply carries `result = 13 + 42 + 4999 = 5054`. Catches frameworks that silently truncate long streams or drop trailing messages under pressure.

## Empty stream (anti-cheat)

Calls `StreamSum` with `count: 0` and verifies the call completes with `OK` and **zero** messages delivered. Catches frameworks that hard-code a minimum message count.
