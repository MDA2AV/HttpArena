---
title: Load Generators
seo_title: "Load Generators"
description: "HttpArena drives each transport with a purpose-built load generator. An overview of gcannon, wrk, zrk, h2load and h2load-h3, and when each is used."
toc: false
weight: 3
---

HttpArena uses a different load generator for each transport / workload.

{{< cards >}}
  {{< card link="h1" title="HTTP/1.1" subtitle="gcannon (io_uring) for most tests, wrk for static file serving, zrk for the fixed-rate Latency-1M profile." icon="lightning-bolt" >}}
  {{< card link="h2" title="HTTP/2" subtitle="h2load - nghttp2's load generator with TLS and stream multiplexing." icon="globe-alt" >}}
  {{< card link="h3" title="HTTP/3" subtitle="h2load-h3 - nghttp2 + ngtcp2 for QUIC-based HTTP/3 benchmarks." icon="globe-alt" >}}
  {{< card link="ws" title="WebSocket" subtitle="gcannon --ws - io_uring WebSocket echo driver reusing the HTTP/1.1 engine with a frame-aware send/recv loop." icon="globe-alt" >}}
{{< /cards >}}
