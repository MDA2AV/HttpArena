---
title: Assets-16
---

Serves static files and JSON with conditional gzip compression, constrained to 16 CPUs and 32 GB memory. Same workload as [Assets-4](../assets-4) but with more resources to measure scaling behavior.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, compression rules, and resource constraints." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
