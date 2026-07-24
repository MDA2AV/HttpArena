---
title: Pipelined (16x)
seo_title: "HTTP Pipelining Benchmark (16x)"
description: "Sixteen requests are sent back to back per connection before any response is read, isolating raw I/O throughput from application logic."
---

16 HTTP requests are sent back-to-back on each connection before waiting for responses, isolating raw I/O throughput from application logic.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
