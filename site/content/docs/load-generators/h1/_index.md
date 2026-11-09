---
title: HTTP/1.1
seo_title: "HTTP/1.1 Load Generation"
description: "The load generators behind the HTTP/1.1 profiles: gcannon for most workloads, wrk for the URI-rotating TLS profiles, and zrk for the fixed-rate profiles."
---

{{< cards >}}
  {{< card link="gcannon" title="gcannon" subtitle="Custom io_uring-based load generator for baseline, JSON compression, async, WebSocket and other tests." icon="lightning-bolt" >}}
  {{< card link="wrk" title="wrk" subtitle="Multi-threaded HTTP benchmark tool used with Lua rotation for static-tls and json-tls." icon="lightning-bolt" >}}
  {{< card link="zrk" title="zrk" subtitle="Constant-throughput generator that holds a fixed offered rate, with coordinated-omission correction. Drives the Latency profiles and 8Gbit." icon="lightning-bolt" >}}
{{< /cards >}}
