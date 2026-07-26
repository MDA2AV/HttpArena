---
title: Gateway H2
seo_title: "Gateway H2 Benchmark"
description: "A two-service proxy and server stack over HTTP/2 with TLS: the proxy serves static files from disk and forwards dynamic endpoints."
---

Two-service proxy + server stack over HTTP/2 + TLS. Proxy serves static files directly from disk, forwards dynamic endpoints (baseline, JSON, async-db) to the application server. 64 CPUs split freely between the two services.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Compose file layout, endpoint responsibilities, proxy-to-server protocol, CPU allocation." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="Checks executed by validate.sh against the running compose stack." icon="check-circle" >}}
{{< /cards >}}
