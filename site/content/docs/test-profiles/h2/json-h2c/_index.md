---
title: JSON (H2c)
seo_title: "JSON over HTTP/2 Cleartext Benchmark"
description: "The JSON processing workload served over HTTP/2 cleartext, measuring serialization throughput without TLS overhead."
---

The [`/json`](../../h1/isolated/json-tls/) workload transported over HTTP/2 cleartext on port 8082 - measures JSON serialization throughput under multiplexed h2c streams without TLS overhead.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
