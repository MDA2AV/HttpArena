---
title: Connections Ramp
seo_title: "CON-RAMP: a Ramp to Two Million Mostly Idle Connections"
description: "Opens connections evenly over two minutes up to two million, 95% of them idle, and measures how many the server takes before the p99 of the active ones goes over 2 ms."
---

Two million connections are opened over two minutes, evenly, and 95% of them go quiet after one request: the way users connect to a service and then mostly do nothing. The other 5% keep a fixed 100,000 req/s going the whole time. The score is how far the ramp got before those active connections' p99 went over 2 ms.

What the server does with the quiet connections is part of the question. Holding them costs memory, closing them costs nothing more than noticing; a keep-alive timeout, or any policy that closes what is idle, is a legitimate answer and the profile reports what it closed. What it must not do is let the active traffic suffer for it.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="What the listener must allow, how the load is run, what is measured, and how it is scored." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
