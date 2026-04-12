---
title: Load Generators
toc: false
weight: 3
---

HttpArena uses three load generators, one per protocol version.

{{< cards >}}
  {{< card link="h1" title="HTTP/1.1" subtitle="gcannon (io_uring) for most tests, wrk for static file serving." icon="lightning-bolt" >}}
  {{< card link="h2" title="HTTP/2" subtitle="h2load — nghttp2's load generator with TLS and stream multiplexing." icon="globe-alt" >}}
  {{< card link="h3" title="HTTP/3" subtitle="oha — HTTP load generator with QUIC support for HTTP/3 benchmarks." icon="globe-alt" >}}
{{< /cards >}}
