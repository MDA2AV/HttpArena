---
title: Validation
seo_title: "Unary gRPC Benchmark: Validation Checks"
description: "The correctness checks validate.sh runs against the unary gRPC benchmark before a framework's results are accepted."
---

The following checks are executed by `validate.sh` for every framework subscribed to the `unary-grpc` or `unary-grpc-tls` tests.

`validate.sh` builds the gRPC frames itself rather than shelling out to a gRPC client, so **server reflection is not required**. A framework that only registers `BenchmarkService` without a reflection service still validates.

## Readiness

gRPC servers speak HTTP/2 and never answer the plaintext HTTP/1.1 probe used for most frameworks. For gRPC subscribers the readiness probe is a prior-knowledge h2c request to port 8080 (or an ALPN-h2 TLS request to 8443 for the `-tls` variant). Any HTTP response counts as ready, and a bare `GET` to a gRPC server correctly returns `415`.

## GetSum over HTTP/2

Sends `BenchmarkService/GetSum` as a unary call with `content-type: application/grpc` and `te: trailers`, over h2c on port 8080 (`unary-grpc`) or h2 + TLS on port 8443 (`unary-grpc-tls`). Verifies:

- The response is delivered over **HTTP/2** (`%{http_version}` must report `2`)
- `grpc-status` is `0`. A non-zero status fails the check and its `grpc-message` is reported
- The `SumReply` frame decodes to `result = a + b`

## Anti-cheat: randomized operands

Each call uses freshly randomized `a` and `b` (100–999), and the check runs **twice with independent pairs**. A server returning a canned reply passes a single fixed input but cannot satisfy two random pairs, so hardcoded responses are rejected.

## Frame-level strictness

The reply is decoded from the raw wire bytes: the 5-byte gRPC frame header (compression flag + big-endian length) must be well formed, the length prefix must match the payload actually delivered, and the protobuf body must carry field 1 as a varint. Truncated frames, a set compression flag, or a wrong field tag are each reported with the offending bytes.
