---
title: Resilience
seo_title: "Resilience: Attacks Against a Capped Entry"
description: "Adversarial HTTP clients — slow-drip bodies, Slowloris headers, oversized chunks, HTTP/2 CONTINUATION floods — run against an entry in a fixed memory/CPU box to see whether it survives, sheds load, hangs, or is OOM-killed."
weight: 7
---

The resilience suite runs adversarial clients against an entry **in a fixed box** — by default 8 GiB of memory and 2 CPUs — and records what happens to the server, not how fast it is. The box is the instrument: an attack that exhausts memory OOM-kills the container, which is a signal we can read, instead of taking the host down. It is **opt-in per entry** and runs as part of a benchmark (see [Opting in](#opting-in)). Nothing here is scored into the composite; it is a separate robustness read, the way the compliance columns are.

Every attack runs against a **fresh capped container** (a crash in one must not cost another its verdict), launched through the same path a benchmark uses — the real entry image, the real mounts — with the memory cap turned on.

## The attacks

| Attack | Exhausts | What it does | What a hardened server does |
|---|---|---|---|
| `slow-body` | memory | `POST /echo` with a large declared `Content-Length`, body dripped one byte per second, never finishing | reaps the connection on a body-read-rate timeout |
| `slow-headers` | connections | an unfinished request whose header block keeps growing, never terminated (Slowloris) | reaps it on a header-read timeout or a header-size cap |
| `huge-chunk` | memory | `Transfer-Encoding: chunked` announcing a `0x7fffffffffffffff`-byte chunk | rejects the chunk size instead of pre-allocating it |
| `continuation-flood` | memory | an HTTP/2 header block spread over an endless stream of `CONTINUATION` frames with no `END_HEADERS` ([CVE-2024-27316](https://nvd.nist.gov/vuln/detail/CVE-2024-27316)) | caps the header-block size and sends `GOAWAY` |

The H1 attacks run against any entry. `continuation-flood` runs only when the entry subscribes to an HTTP/2 profile (`baseline-h2`, `static-h2`, `baseline-h2c` or `json-h2c`); it uses the h2c listener on port 8082.

A connection the server **reaps** (closes on the client) is the *correct* defense — a timeout fired, a cap held. Many reaped connections with flat server memory means the server defended itself; growing memory or an OOM-kill means it did not.

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

## Opting in

The suite is **off by default** — the attacks are destructive and need the whole machine. An entry opts in with one flag in its `meta.json`:

```json
"resilience": true
```

On a PR, a full `/benchmark` (no `-t`) then runs the suite for that entry **right after its benchmark**, on the self-hosted bench runner, and `--save` commits the verdicts to `site/data/resilience/<entry>.json` alongside the benchmark results. It rides the benchmark's slot on purpose: the bench host runs one job at a time, so the suite never competes with another run for CPU, memory or ports — contention that would corrupt a verdict. An entry without the flag is skipped.

## Running it locally

```bash
./scripts/resilience.sh aspnet-minimal         # opted-in entry: verdicts in results/resilience/<entry>.json
./scripts/resilience.sh aspnet-minimal --save  # and in site/data/resilience/<entry>.json
./scripts/resilience.sh some-entry slow-body   # name attacks to force a run on an entry that hasn't opted in
```

`<entry>` is the directory under `frameworks/`, not the display name — entries that share a display name each keep their own file, the way `site/data/spec/<entry>.json` does. Without the flag and without a named attack, the runner is a no-op.

The box and the run are env-overridable: `RES_MEM` (default `8g`), `RES_CPUSET` (`0-1`), `RES_DURATION` (`45`s), `RES_CONNS` (`1000`), `RES_BODY_SIZE` (10 MiB), `RES_RECOVERY` (`15`s). The attack client runs on the load-generator cores so it never steals CPU from the deliberately CPU-starved server.

## The scores

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
      "mem_limit_mb": 8192,
      "liveness_fail_pct": 0.0,
      "recovery_s": 0.0,
      "oom_killed": false,
      "client": { "established": 1000, "reaped": 1000, "open_at_end": 0 }
    }
  }
}
```

`passed` is the number of attacks the entry survived or only degraded under. The verdicts are not yet shown on the board or folded into the composite score — the suite records them for now, the way the TLS hardening checks did before they earned a badge.
