---
title: JSON Processing
seo_title: "JSON Processing: the /json endpoint contract"
description: "The /json/{count}?m=N endpoint shared by the JSON TLS, JSON Compressed and JSON h2c profiles - dataset load, derived fields and serialization. Not a profile of its own."
---

The `/json/{count}?m=N` endpoint contract, shared by every JSON profile on the board.

There is no longer a plaintext `json` profile of its own: [JSON TLS](../json-tls/) measures this
workload with the same seven `(count, m)` pairs over TLS, [JSON Compressed](../json-compressed/)
measures it under content negotiation, and [JSON h2c](../../../h2/json-h2c/) serves it over
cleartext h2. This page stays because all three are defined against the response shape below.

Measures how efficiently a framework handles a typical real-world API workload: loading data,
computing derived fields, and serializing a JSON response.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
