---
title: Unary (gRPC)
seo_title: "Unary gRPC Benchmark"
description: "Measures unary gRPC call throughput over HTTP/2, cleartext and TLS, using a simple GetSum remote procedure call."
---

Measures unary gRPC call throughput using a simple `GetSum` RPC - over cleartext HTTP/2 (h2c) in `unary-grpc` and over HTTP/2 + TLS in `unary-grpc-tls`.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
