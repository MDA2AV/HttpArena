---
title: Host profiles
seo_title: "Host Profiles: Benchmarking on Other Machines"
description: "Run the benchmark driver on a laptop, a Raspberry Pi or any machine other than the bench host: what a host profile changes, the profiles that ship, and how to write your own."
weight: 3
---

The defaults in `benchmark.sh` describe the reference bench host: 64 cores, native load generators, the server pinned to one half of the CPU and the generators to the other, thousands of connections. On any other machine, those numbers are wrong. A **host profile** adapts the driver to the machine it runs on.

```bash
HOST_PROFILE=lite ./scripts/benchmark.sh actix
HOST_PROFILE=rpi  ./scripts/benchmark.sh actix baseline --save
```

Without `HOST_PROFILE`, nothing changes and the bench-host defaults apply.

## What a host profile is

A shell file, `scripts/lib/hosts/<name>.sh`, that `benchmark.sh` sources after the profile table (`scripts/lib/profiles.sh`) and before the load-generator adapters. It can therefore change anything the driver reads:

- **Profiles** - connection counts and the server's `cpu_limit` per profile, and through `PROFILE_ORDER` which profiles run at all.
- **Load generators** - `LOADGEN_DOCKER`, `GCANNON_CPUS`, `THREADS` / `ASYNC_THREADS` / `H2THREADS` / `H3THREADS`, fixed rates such as `ZRK_RATE_LATENCY_10K`.
- **Run behaviour** - `READY_TIMEOUT`, `FAIL_FAST`, `SKIP_H3_LOADGEN` (see [Configuration](../configuration/#host-profiles)).

Every host profile also gets its own results directory. `--save` writes to `results-hosts/<name>/` (container logs under `results-hosts/<name>/_logs/`) instead of `results/`, and the site data is not rebuilt: numbers from a laptop or a Pi never mix with the published leaderboard. `results-hosts/` is git-ignored.

Only profiles in the host's `PROFILE_ORDER` can run. Naming another one on the command line fails before anything is built, rather than running it with bench-host settings the machine cannot provide.

## Shipped profiles

| | `lite` | `rpi` |
|---|---|---|
| Meant for | Laptops, CI runners, quick local checks | Raspberry Pi 4 (4x Cortex-A72, 4 GB, arm64) |
| Load generators | Docker | Docker (arm64 images; h2load-h3 is not built) |
| Server CPUs | Not pinned - shares every core | `0-1` |
| Generator CPUs | Every core | `2-3` |
| Generator threads | `nproc / 2` (or `--load-threads N`) | 2 |
| Connections | One count per profile, mostly 512 | Scaled down, mostly 64-256 |
| Profiles | 13 - see [benchmark-lite.sh](../scripts/benchmark-lite/#profile-set) | 17 - h1, TLS, h2, h2c, gRPC, WebSocket, `latency-10k`, `async` |
| Readiness timeout | 30 s | 120 s, and a framework stops at its first profile that does not come up |
| Results | `results-hosts/lite/` | `results-hosts/rpi/` |

`lite` has its own wrapper, [`benchmark-lite.sh`](../scripts/benchmark-lite/), which also runs every enabled framework when none is named.

Results from different host profiles are comparable within one machine only. `lite` does not pin anything, so server and load generator compete for the same cores; use it to compare frameworks or two builds of one framework, not to reproduce leaderboard numbers.

## Writing your own

Copy the closest shipped profile to `scripts/lib/hosts/<name>.sh` and adjust. The usual shape:

```bash
# scripts/lib/hosts/mybox.sh — 8-core desktop.

LOADGEN_DOCKER=true

SERVER_CPUS="0-3"
GCANNON_CPUS="4-7"
export GCANNON_CPUS

THREADS=4
ASYNC_THREADS=4
H2THREADS=4
H3THREADS=4

# pipeline | req_per_conn | cpu_limit | connections | endpoint
PROFILES[baseline]="1|0|$SERVER_CPUS|512|"
PROFILES[json-comp]="1|0|$SERVER_CPUS|512|json-compressed"
PROFILES[baseline-h2]="1|0|$SERVER_CPUS|128|h2"

PROFILE_ORDER=(baseline json-comp baseline-h2)
```

Two rules:

- **Override entries, do not replace the table.** A framework's `meta.json` may subscribe to profiles your host skips, and the driver rejects subscriptions to profiles it does not know. Assign `PROFILES[<name>]=...` for the profiles you run and leave the rest alone; `PROFILE_ORDER` decides what actually runs.
- **Give every profile in `PROFILE_ORDER` a `cpu_limit` that exists on the machine** (or leave it blank for no pinning). The bench-host values (`0-31,64-95`) fail on smaller CPUs.

The profile format and the tool each endpoint uses are described in [Configuration](../configuration/#profile-definitions).
