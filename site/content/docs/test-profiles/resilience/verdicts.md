---
title: Verdicts & Scores
seo_title: "Resilience: Verdicts and the Results File"
description: "How each resilience attack is judged — survived, degraded, hung, crashed or oom-killed — from the container's OOM state, a per-second liveness probe and cgroup peak RSS, plus the per-entry results file a run writes."
weight: 2
---

Each attack targets a resource, and that choice decides how a failure shows up. The **memory** attacks give the cleanest verdict (OOM-kill → exit 137) and `chunk-size-overflow` aims for a **crash**; the **CPU** attacks don't OOM, so they surface as `hung` or `degraded` through the liveness probe instead.

## The verdict

For each attack the runner records a verdict from the server-side signal, plus peak RSS (vs. the idle baseline), the share of liveness probes that failed *during* the attack, and how long the server took to serve again *after* it:

| Verdict | Meaning | Pass |
|---|---|---|
| `survived` | kept answering throughout, no OOM, memory stayed bounded | ✓ |
| `degraded` | stopped answering under load but recovered afterwards | ✓ |
| `hung` | still running but stopped answering and never recovered | ✗ |
| `crashed` | the process died without being OOM-killed (panic/segfault) | ✗ |
| `oom-killed` | the container ran out of its memory box | ✗ |

A liveness probe — a cheap `GET` on port 8080 — runs every second during the attack; recovery is measured by the same probe after the attack client stops. OOM is read straight from the container (`State.OOMKilled` / exit 137), and peak RSS from the cgroup's `memory.peak`.

## The results file

A run writes `results/resilience/<entry>.json` (and, with `--save`, `site/data/resilience/<entry>.json`), keyed by the entry **directory** rather than the display name:

```json
{
  "framework": "aspnet-minimal",
  "dir": "aspnet-minimal",
  "passed": 4,
  "total": 4,
  "attacks": {
    "slow-body": {
      "verdict": "survived",
      "passed": true,
      "resource": "memory",
      "peak_mem_mb": 71.2,
      "baseline_mem_mb": 68.9,
      "mem_limit_mb": 4096,
      "liveness_fail_pct": 0.0,
      "recovery_s": 0.0,
      "oom_killed": false,
      "client": { "established": 1000, "reaped": 1000, "open_at_end": 0 }
    }
  }
}
```

`passed` is the number of attacks the entry survived or only degraded under. The verdicts are not yet shown on the board or folded into the composite score — the suite records them for now, the way the TLS hardening checks did before they earned a badge.
