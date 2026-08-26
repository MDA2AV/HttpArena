---
title: Echo Short-lived (WebSocket)
seo_title: "Short-lived WebSocket Connection Benchmark"
description: "Measures WebSocket upgrade cost: each connection is closed after 10 echo messages, so the handshake is paid continuously rather than amortized."
---

Measures the cost of the WebSocket upgrade itself. Each connection performs the HTTP/1.1 upgrade, exchanges 10 messages, then closes and is replaced by a new one, so the handshake is paid continuously instead of being amortized over a long-lived session.

This is the WebSocket counterpart to the HTTP/1.1 [Short-lived Connection](../../h1/isolated/short-lived/) profile.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
