---
title: Latency-1M
seo_title: "Latency-1M: CPU Cost at One Million Requests per Second"
description: "Pins the offered load at one million requests per second and measures the CPU each framework spends to serve it, read exactly from the container's cgroup."
---

One million requests per second, offered at a fixed rate to every entry that can take it. The rate is not the result. Everyone who finishes serves the same million. What separates them is what it cost.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
