---
title: Rendezvous
seo_title: "Rendezvous Benchmark: Cross-Connection Interaction"
description: "Two connections meet on a key: each request waits for the other and is answered with its value, measuring what crossing between workers costs a server."
---

Two connections meet on a key. Neither gets an answer until both have arrived, and each is answered with the other's value.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected behaviour, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
