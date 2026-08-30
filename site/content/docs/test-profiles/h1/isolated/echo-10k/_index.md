---
title: Echo-10K
seo_title: "Echo-10K: 10 KB Echoed Over TLS, Both Directions at Once"
description: "Posts a 10 KB body over TLS at a fixed rate and requires it back verbatim, loading ingest and egress together rather than one at a time."
---

The only profile that loads **both directions at once**. A 10 KB body goes up over TLS, and the same 10 KB comes back - so every request moves 20 KB through the framework's read path, its write path, and the TLS record layer in both directions. The offered rate is held fixed, so what varies between entries is what serving it cost rather than how fast they went.

It replaces the old Upload profile, which measured ingest alone with bodies up to 20 MB and had stopped discriminating: a 7% spread across 99 entries, because at that size it was measuring memory bandwidth rather than anything a framework does.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
