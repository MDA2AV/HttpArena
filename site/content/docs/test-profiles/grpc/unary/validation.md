---
title: Validation
seo_title: "Unary gRPC Benchmark — Validation Checks"
description: "The correctness checks validate.sh runs against the unary gRPC benchmark before a framework's results are accepted."
---

The gRPC unary profile does not have dedicated validation checks in `validate.sh`. Correctness is verified during the benchmark run itself:

- The load generator (h2load) sends pre-encoded protobuf `SumRequest{a=1, b=2}` frames and counts successful `2xx` responses with `grpc-status: 0`
- Failed responses (wrong protobuf encoding, missing trailers, non-zero grpc-status) are counted as errors and excluded from the RPS score

Frameworks subscribed to `unary-grpc` must correctly implement the `BenchmarkService/GetSum` RPC as defined in the proto definition. The benchmark runner validates this implicitly through successful response counting.
