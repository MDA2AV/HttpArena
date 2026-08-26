---
title: Efficiency (CPU at fixed load)
seo_title: "CPU Efficiency Benchmark at Fixed Throughput"
description: "Holds the request rate fixed at 500,000 req/s and measures the CPU each framework spends to serve it, read exactly from the container's cgroup."
---

Every other profile here asks how fast a framework can go. Real servers spend almost all of their life nowhere near that. This one asks the question from the other end: at a load everybody can carry, who carries it cheaply.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
