---
title: Static Files (HTTP/1.1 + TLS)
seo_title: "Static File Serving Benchmark (HTTP/1.1 + TLS)"
description: "Serves twenty static files of mixed type and size over HTTP/1.1 + TLS, approximating a realistic page load over an encrypted connection."
---

Serves 20 static files of various types and sizes over HTTP/1.1 + TLS on port 8081, simulating a realistic page load over an encrypted connection.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
