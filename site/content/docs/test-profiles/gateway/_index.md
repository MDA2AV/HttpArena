---
weight: 3
title: Gateway
---

Gateway test profiles benchmark multi-service deployments - proxy + server, with optional auth sidecars, caches, and databases. Unlike isolated tests that measure a single framework container, gateway tests measure the **end-to-end throughput of the entire stack** as a unit.

All gateway tests use Docker Compose for orchestration, pin services to specific CPU cores via `cpuset`, and give entries full control over their architecture within a fixed 64-CPU budget.

{{< cards >}}
  {{< card link="gateway-h2" title="Gateway H2" subtitle="Two-service proxy + server stack over HTTP/2 + TLS. Mixed workload: static 30%, JSON 35%, baseline 20%, async-db 15%." icon="server" >}}
  {{< card link="gateway-h3" title="Gateway H3" subtitle="Same two-service stack as Gateway H2 but with HTTP/3 + QUIC at the edge." icon="lightning-bolt" >}}
  {{< card link="production-stack" title="Production Stack H2" subtitle="Four-service CRUD API: edge + Redis + JWT auth sidecar + server. 10K-item cache-aside, JWT verified every request, concurrent reads + writes." icon="shield-check" >}}
{{< /cards >}}
