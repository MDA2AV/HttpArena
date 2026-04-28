---
title: Load Generators
toc: false
weight: 3
---

HttpArena uses a different load generator for each transport / workload.

{{< cards >}}
  {{< card link="h1" title="HTTP/1.1" subtitle="gcannon (io_uring) for most tests, wrk for static file serving." icon="lightning-bolt" >}}
  {{< card link="h2" title="HTTP/2" subtitle="h2load — nghttp2's load generator with TLS and stream multiplexing." icon="globe-alt" >}}
  {{< card link="h3" title="HTTP/3" subtitle="h2load-h3 — nghttp2 + ngtcp2 for QUIC-based HTTP/3 benchmarks." icon="globe-alt" >}}
  {{< card link="grpc" title="gRPC" subtitle="ghz — proto-aware gRPC load tester for streaming and unary RPCs." icon="globe-alt" >}}
  {{< card link="ws" title="WebSocket" subtitle="gcannon --ws — io_uring WebSocket echo driver reusing the HTTP/1.1 engine with a frame-aware send/recv loop." icon="globe-alt" >}}
{{< /cards >}}
