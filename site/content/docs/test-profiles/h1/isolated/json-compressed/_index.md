---
title: JSON Compressed
---

Same workload as [JSON Processing](../json-processing/), but with HTTP content negotiation: the client advertises `Accept-Encoding: gzip, br` and the server must return a compressed response. Measures serialization plus compression throughput.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, compression rules, and multiplier parameter." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
