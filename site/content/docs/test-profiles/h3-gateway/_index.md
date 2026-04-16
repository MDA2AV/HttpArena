---
weight: 4
title: H/3 Gateway
---

Same two-service proxy-plus-server shape as [H/2 Gateway](../h2-gateway/), but with HTTP/3 over QUIC at the edge instead of HTTP/2 over TCP. The load generator speaks QUIC to the proxy; the proxy terminates TLS+h3, serves `/static/*` directly from disk, and forwards dynamic endpoints to the application server over the entry's choice of internal protocol.

The test measures the combined efficiency of a production h3-capable proxy (Caddy, nginx with QUIC, Envoy, HAProxy, h2o) paired with an application backend under a realistic mixed workload. HTTP/3 happens entirely at the edge — the backend is still plain h1/h2 internally, same as in H/2 Gateway.

{{< cards >}}
  {{< card link="gateway-h3" title="Gateway-H3" subtitle="Two-service Docker Compose stack over HTTP/3 + QUIC. Proxy serves static, server serves dynamic. Same 20-URI mix as Gateway-64, same 64-CPU budget, different edge protocol." icon="lightning-bolt" >}}
{{< /cards >}}
