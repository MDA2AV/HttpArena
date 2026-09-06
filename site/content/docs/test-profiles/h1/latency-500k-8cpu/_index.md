---
title: Latency-500K/8
seo_title: "Latency-500K/8: CPU Cost and Queueing at 500K req/s on Four Cores"
description: "Pins the offered load at 500,000 requests per second with the server confined to four cores and their SMT siblings, and measures the CPU it spends and the queue it builds to serve it."
---

Half a million requests per second, offered at a fixed rate to a server that has four cores and their SMT siblings to serve it with. Latency-1M gives every entry thirty-two cores at a load only the fastest can feel; this gives it eight logical CPUs at a load that keeps them busy, so what separates them is the cost of a request when the machine is actually busy, and the queue each one builds to keep up. Reference-only while the first entries are measured.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
