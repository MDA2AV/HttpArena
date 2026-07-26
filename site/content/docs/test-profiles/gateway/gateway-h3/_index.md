---
title: Gateway-H3
seo_title: "Gateway H3 Benchmark"
description: "The HTTP/3 sibling of the Gateway H2 profile: QUIC at the edge, the same mixed workload and the same 64-CPU budget."
---

Proxy + server stack with HTTP/3 at the edge and a realistic mixed workload - static files served by the proxy from disk, dynamic endpoints forwarded to the application server.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Compose file layout, endpoint responsibilities, proxy-to-server protocol choices, CPU allocation." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="Checks executed by validate.sh against the running compose stack." icon="check-circle" >}}
{{< /cards >}}
