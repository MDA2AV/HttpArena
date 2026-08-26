---
title: Async Delay
seo_title: "Async Delay Benchmark"
description: "Measures how a framework holds tens of thousands of in-flight requests that are each waiting on a timer, with the wait length parsed from the route."
---

Every request asks to be answered after a delay it names in its own path, and tens of thousands of them are in flight at once. What the profile measures is what the framework does while it waits.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
