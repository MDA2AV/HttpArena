---
title: Validation
seo_title: "Server-Streaming gRPC Benchmark — Validation Checks"
description: "The correctness checks validate.sh runs against the server-streaming gRPC benchmark before a framework's results are accepted."
---

The following checks are executed by `validate.sh` for every framework subscribed to the `stream-grpc` or `stream-grpc-tls` tests.

`validate.sh` builds the gRPC frames itself rather than shelling out to a gRPC client, so **server reflection is not required**. Reply frames arrive concatenated in the response body and are decoded frame by frame.

## Readiness

gRPC servers speak HTTP/2 and never answer the plaintext HTTP/1.1 probe used for most frameworks. For gRPC subscribers the readiness probe is a prior-knowledge h2c request to port 8080 (or an ALPN-h2 TLS request to 8443 for the `-tls` variant). Any HTTP response counts as ready — a bare `GET` to a gRPC server correctly returns `415`.

## Server-streaming response shape

Calls `BenchmarkService/StreamSum` with randomized `a` and `b` (100–999) and a randomized `count` (3–10), over h2c on port 8080 (`stream-grpc`) or h2 + TLS on port 8443 (`stream-grpc-tls`). Verifies:

- The response is delivered over **HTTP/2**
- `grpc-status` is `0`
- Exactly `count` `SumReply` messages are received
- The `i`-th message carries `result = a + b + i`, in order

## Anti-cheat: the sequence, not just the count

Because each reply must carry `a + b + i` rather than a constant, a server that emits `count` copies of one precomputed reply — skipping the per-message work this profile exists to measure — is rejected. That case is reported explicitly ("all N frames carried X"). Randomizing `count` as well as the operands means neither the message count nor the payload can be special-cased.

## Benchmark-depth stream

Repeats the call with `count: 5000` — the depth the benchmark actually drives — and verifies all 5,000 replies arrive with the correct sequence. Catches frameworks that silently truncate long streams or drop trailing messages under HTTP/2 flow control, which a short stream would not reveal.

## Frame-level strictness

Every frame is decoded from raw wire bytes: the 5-byte header (compression flag + big-endian length) must be well formed and its length prefix must match the payload delivered. Trailing bytes after the last complete frame, a truncated frame, or a wrong protobuf field tag are each reported.
