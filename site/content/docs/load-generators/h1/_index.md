---
title: HTTP/1.1
seo_title: "HTTP/1.1 Load Generation"
description: "The load generators behind the HTTP/1.1 profiles: gcannon for most workloads and wrk for URI-rotating static file tests."
---

{{< cards >}}
  {{< card link="gcannon" title="gcannon" subtitle="Custom io_uring-based load generator for baseline, JSON, upload, and other tests." icon="lightning-bolt" >}}
  {{< card link="wrk" title="wrk" subtitle="Multi-threaded HTTP benchmark tool used for the static file serving test with Lua rotation." icon="lightning-bolt" >}}
{{< /cards >}}
