---
title: Upload (20 MB)
seo_title: "Large Upload Benchmark (20 MB)"
description: "Measures large request body ingestion: the client posts a 20 MB payload and the server returns a checksum of what it received."
---

Measures how efficiently a framework handles large request body ingestion. Each request sends a 20 MB binary payload and the server returns the byte count.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
