---
title: Echo Pipelined (WebSocket)
---

Measures WebSocket echo throughput with pipelining. Each connection upgrades via HTTP/1.1, then sends 16 messages back-to-back before waiting for the echoes.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
