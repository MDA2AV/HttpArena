---
title: Knowledge Base
seo_title: "HttpArena Knowledge Base: HTTP Server Benchmark Methodology"
description: "How the HttpArena benchmarks work: what each test profile measures, how the load generators drive traffic, and how results are scored."
toc: false
---

Learn how HttpArena benchmarks work, what each test profile measures, and how the load generators drive traffic.

{{< cards >}}
  {{< card link="load-generators" title="Load Generators" subtitle="How gcannon (HTTP/1.1) and h2load (HTTP/2) drive traffic for the benchmark suite." icon="chip" >}}
  {{< card link="hardware" title="Hardware & Topology" subtitle="Reference machine: Threadripper PRO 3995WX. NUMA, cache, SMT, and how the harness pins resources." icon="cog" >}}
  {{< card link="scoring" title="Scoring" subtitle="How the composite score is computed: normalization, arithmetic mean, and participation penalties." icon="chart-bar" >}}
  {{< card link="running-locally" title="Running Locally" subtitle="Set up and run the full benchmark suite on your own machine with Docker and gcannon." icon="terminal" >}}
  {{< card link="add-framework" title="Add a Framework" subtitle="Step-by-step guide to adding your framework: endpoints, Dockerfile, metadata, and PR." icon="plus-circle" >}}
{{< /cards >}}
