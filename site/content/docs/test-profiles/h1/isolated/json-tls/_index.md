---
title: JSON over TLS
---

Same workload as [JSON Processing](../json-processing/) - a dataset of 50 items serialized to JSON with a per-request multiplier - but transported over **HTTP/1.1 on top of TLS** through a dedicated port (8081). Measures how much of a framework's plaintext throughput survives TLS record framing, symmetric cipher work, and record-boundary scheduling.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, TLS port, ALPN requirements." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
