---
title: Baseline (H2c)
---

HTTP/2 cleartext on port 8082 — prior-knowledge framing, no TLS. Models the reverse-proxy-to-origin and service-to-service patterns where HTTP/2 runs inside the trust boundary without encryption.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
