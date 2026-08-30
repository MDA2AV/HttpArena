---
title: Pipelined (16x)
seo_title: "HTTP Pipelining Benchmark (16x)"
description: "Sixteen requests are sent back to back per connection before any response is read, isolating raw I/O throughput from application logic."
---

16 HTTP requests are sent back-to-back on each connection before waiting for responses, isolating raw I/O throughput from application logic.

**This test is reference-only - it does not contribute to the composite score.** HTTP/1.1 pipelining is disabled in modern browsers and unsupported by mainstream proxies and CDNs, so the profile is kept as a middleware-efficiency indicator rather than a ranked benchmark (see issue #1058). Results appear on the board as a faded column.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
