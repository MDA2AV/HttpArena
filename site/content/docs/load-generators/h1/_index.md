---
title: HTTP/1.1
seo_title: "HTTP/1.1 Load Generation"
description: "The load generators behind the HTTP/1.1 profiles: gcannon for most workloads, wrk for URI-rotating static file tests, and zrk for the fixed-rate Latency-1M profile."
---

{{< cards >}}
  {{< card link="gcannon" title="gcannon" subtitle="Custom io_uring-based load generator for baseline, JSON, upload, and other tests." icon="lightning-bolt" >}}
  {{< card link="wrk" title="wrk" subtitle="Multi-threaded HTTP benchmark tool used for the static file serving test with Lua rotation." icon="lightning-bolt" >}}
  {{< card link="zrk" title="zrk" subtitle="Constant-throughput generator that holds a fixed offered rate, with coordinated-omission correction. Drives Latency-1M." icon="lightning-bolt" >}}
{{< /cards >}}
