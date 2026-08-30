---
title: Latency-10K
seo_title: "Latency-10K: CPU Cost at a Near-Idle 10K Requests per Second"
description: "Offers a fixed 10,000 requests per second on the same hardware as Latency-1M, and measures the CPU and latency a server spends while nearly idle."
---

[Latency-1M](../latency-1m/) asks what a server costs at a load only the fastest entries carry. This asks what the same server costs when it is doing almost nothing - which is where most services spend most of their life.

Everything is identical to Latency-1M except the offered rate: same cores, same connections, same endpoint, same duration. Only the rate moves, by two orders of magnitude, so the two numbers are directly comparable and the gap between them is the standing cost a busy machine amortises away.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Endpoint specification, expected request/response format, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
