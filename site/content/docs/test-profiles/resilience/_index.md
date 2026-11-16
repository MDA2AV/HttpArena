---
title: Resilience
seo_title: "Resilience: Attacks Against a Capped Entry"
description: "Adversarial HTTP clients — slow-drip bodies, Slowloris headers, oversized chunks, HTTP/2 CONTINUATION floods — run against an entry in a fixed memory/CPU box to see whether it survives, sheds load, hangs, or is OOM-killed."
weight: 7
---

The resilience suite runs adversarial clients against an entry **in a fixed box** — by default 4 GiB of memory and 2 CPUs — and records what happens to the server, not how fast it is. The box is the instrument: an attack that exhausts memory OOM-kills the container, which is a signal we can read, instead of taking the host down. Nothing here is scored into the composite; it is a separate robustness read, the way the compliance columns are.

Every attack runs against a **fresh capped container** (a crash in one must not cost another its verdict), launched through the same path a benchmark uses — the real entry image, the real mounts — with the memory cap turned on. A connection the server **reaps** (closes on the client) is the *correct* defense: many reaped connections, with flat memory and a green liveness probe, mean the server defended itself.

The suite is **opt-in per entry** — the attacks are destructive and need the whole machine — and, once enabled, runs on the bench host as part of a benchmark. See [Running & Tuning](running) for how to opt an entry in and how to run it yourself.

{{< cards >}}
  {{< card link="attacks" title="The Attacks" subtitle="The 41 attacks across HTTP/1.1, HTTP/2, WebSocket and TLS — what each one exhausts and the CVE class it models." icon="shield" >}}
  {{< card link="verdicts" title="Verdicts & Scores" subtitle="survived / degraded / hung / crashed / oom-killed — how each is read from the container, and the per-entry results file a run writes." icon="check-circle" >}}
  {{< card link="running" title="Running & Tuning" subtitle="Opt an entry in, run the suite locally, and tune the box, CPU split, connection counts and per-attack sizes for any machine." icon="terminal" >}}
{{< /cards >}}
