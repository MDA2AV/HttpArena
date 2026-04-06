---
title: Scripts Reference
weight: -1
---

All scripts live in the `scripts/` directory and are meant to be run from the repository root.

{{< cards >}}
  {{< card link="validate" title="validate.sh" subtitle="Run the correctness validation suite against a framework's endpoints." icon="check-circle" >}}
  {{< card link="run" title="run.sh" subtitle="Run a framework container interactively for manual testing and endpoint development." icon="play" >}}
  {{< card link="benchmark" title="benchmark.sh" subtitle="Run benchmarks across test profiles with system tuning and result collection." icon="lightning-bolt" >}}
  {{< card link="benchmark-lite" title="benchmark-lite.sh" subtitle="Lightweight benchmarks for any machine with Docker — no CPU pinning, containerized load generators." icon="desktop-computer" >}}
  {{< card link="compare" title="compare.sh" subtitle="Compare benchmark results against the published leaderboard on main." icon="scale" >}}
  {{< card link="archive" title="archive.sh" subtitle="Snapshot current results as named rounds and manage archived benchmarks." icon="archive" >}}
{{< /cards >}}
