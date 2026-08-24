---
weight: 4
title: gRPC
seo_title: "gRPC Test Profiles"
description: "gRPC benchmark profiles measuring Protocol Buffers over HTTP/2, in both cleartext (h2c) and TLS variants."
---

gRPC test profiles measure framework performance using Protocol Buffers over HTTP/2. The server listens on **port 8080** (h2c) and **port 8443** (h2 TLS) and implements the `BenchmarkService` defined in `benchmark.proto`.

{{< cards >}}
  {{< card link="unary" title="Unary" subtitle="Single unary RPC throughput - GetSum request/response over h2c and h2 TLS." icon="globe-alt" >}}
{{< /cards >}}
