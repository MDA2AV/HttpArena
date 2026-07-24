---
title: Hardware & Topology
toc: true
weight: 5
---

The reference hardware for HttpArena results is a single-socket AMD Threadripper PRO 3995WX workstation. Every benchmark run uses the same machine, so numbers are directly comparable framework-to-framework. This page explains the CPU topology - NUMA, cache hierarchy, SMT - and how the benchmark harness pins resources against it.

## Processor

| Spec | Value |
|---|---|
| Model | AMD Ryzen Threadripper PRO 3995WX |
| Architecture | Zen 2 |
| Physical cores | 64 |
| Logical threads | 128 (SMT2) |
| Sockets | 1 |
| Base / boost clock | 2.7 GHz / 4.2 GHz |
| TDP | 280 W |
| Memory channels | 8 × DDR4-3200 |
| Aggregate DRAM bandwidth | ~205 GB/s |
| Total L3 | 256 MB (16 × 16 MB) |
| Total L2 | 32 MB (64 × 512 KB) |
| Total L1d / L1i | 2 MB each (64 × 32 KB) |

## NUMA layout

Confirmed with `numactl --hardware`:

```
available: 1 nodes (0)
node 0 cpus: 0-127
node 0 size: 257 GB
node distances:
node   0
  0:  10
```

**One NUMA node**, all 128 logical threads, all DRAM channels. This is **NPS1** mode (Nodes Per Socket = 1), configured in BIOS. All memory is symmetrically accessible to every core with identical reported latency, so the kernel scheduler has full placement freedom and software doesn't need NUMA policies.

### Could NPS4 help?

No, and it could hurt. NPS4 would split the chip into 4 NUMA nodes (16 cores + 2 DRAM channels each), surfacing physical proximity asymmetries to the kernel. That's useful for *shared-nothing* workloads - multiple independent DBs, per-node JVMs, etc. HttpArena's server workloads are the opposite: heavily *shared mutable state* (thread-pool queues, `IMemoryCache`, Npgsql multiplexer state, Postgres shared buffers). Under NPS4 that shared state gets a "home node" and cross-node access becomes measurably slower. Also, at our throughput (~1 KB memory traffic per request × 350K rps ≈ 350 MB/s) we use **0.2%** of aggregate memory bandwidth - the resource NPS partitions isn't one we're constrained on.

## Cache hierarchy

| Level | Size | Shared by |
|---|---|---|
| L1i + L1d | 32 KB each | One physical core (plus its SMT sibling) |
| L2 | 512 KB | One physical core (plus its SMT sibling) |
| **L3** | **16 MB** | **One CCX - 4 physical cores / 8 threads** |

Zen 2 arranges cores into **CCXs** (core complexes) of 4 physical cores. Each CCX has its own exclusive L3 slice. Physical chiplets on the 3995WX contain 2 CCXs each, and there are 8 chiplets → **16 CCXs total**, 16 MB L3 per CCX.

Within a CCX, L3 access is ~40 cycles. Crossing CCXs (Infinity Fabric) is ~110 cycles. So **CCX boundaries are the real locality boundaries** on this chip, more so than NUMA.

### CCX-to-CPU mapping

Verified from `/sys/devices/system/cpu/cpuN/cache/index3/shared_cpu_list`:

| CCX | Physical cores (and SMT siblings) |
|---:|---|
| 0 | 0–3, 64–67 |
| 1 | 4–7, 68–71 |
| 2 | 8–11, 72–75 |
| 3 | 12–15, 76–79 |
| 4 | 16–19, 80–83 |
| 5 | 20–23, 84–87 |
| 6 | 24–27, 88–91 |
| 7 | 28–31, 92–95 |
| 8 | 32–35, 96–99 |
| 9 | 36–39, 100–103 |
| 10 | 40–43, 104–107 |
| 11 | 44–47, 108–111 |
| 12 | 48–51, 112–115 |
| 13 | 52–55, 116–119 |
| 14 | 56–59, 120–123 |
| 15 | 60–63, 124–127 |

## SMT (Simultaneous Multithreading)

Each physical core has two hardware threads. The sibling of CPU `N` is CPU `N+64`:

```
cpu0  → 0,64
cpu1  → 1,65
...
cpu63 → 63,127
```

Verified from `/sys/devices/system/cpu/cpuN/topology/thread_siblings_list`.

**Why this matters for pinning:** SMT siblings share L1, L2, execution units, and decode bandwidth. When you cpuset-pin a consumer, always include both threads of a pair - splitting an SMT pair across two different consumers creates pathological cache thrashing. When the harness assigns, say, `0,64` to Redis and `1-31,65-95` to the server, both sides get coherent pairs.

SMT2 roughly yields +30% throughput on our workload over single-thread-per-core - useful for latency-bound async handlers where one logical thread is usually idle waiting on I/O while its sibling can execute.

## How HttpArena pins against this topology

Most profiles use a 64-thread server cpuset: `0-31,64-95`. That's **32 physical cores** spanning **CCX 0–7** (8 CCXs = 128 MB L3 budget). The load generator (gcannon) gets `32-63,96-127` - symmetric split, CCX 8–15. One half of the chip drives the test, the other half serves it. Same NUMA node either way.

For profiles that need a sidecar (Postgres, Redis), the harness reshuffles:

**crud profile** (uses Redis):

| consumer | phys | threads | cpuset | L3 reach |
|---|---:|---:|---|---|
| Redis | 1 | 2 | `0,64` | CCX 0 (shared with 3 server cores) |
| Server | 31 | 62 | `1-31,65-95` | CCX 0–7 (112 MB L3 exclusive + 16 MB shared with Redis) |
| Gcannon | 32 | 64 | `32-63,96-127` | CCX 8–15 (128 MB L3) |
| Postgres | unpinned | - | - | kernel-scheduled, typically lands on server CCXs for request-path L3 locality |

Redis sharing a CCX with a few server cores is *beneficial* - data the server just wrote to Redis (on cache miss) stays in the shared L3 when it reads back (on hit). Moving Redis to a non-server CCX would introduce a ~70-cycle inter-CCX coherence hop per read.

**production-stack profile** (explicit multi-service pinning):

| Service | cpuset |
|---|---|
| edge (nginx) | `4-15,68-79` (12 phys) |
| authsvc (JWT verifier) | `16-19,80-83` (4 phys) |
| Redis (cache) | `15,79` (1 phys) |
| Postgres (unpinned) | - |
| server (framework) | `0-3,20-31,64-67,84-95` (16 phys) |
| gcannon | `32-63,96-127` (32 phys) |

This split is empirically tuned - see the CHANGELOG entry for 2026-04-16 for the calibration history and why an edge-heavy allocation works at the given rps.

## Kernel tuning applied per run

`scripts/lib/system.sh` runs before each benchmark:

- CPU governor → `performance` (no DVFS ramp delays)
- `net.core.somaxconn` → 65535 (accept queue)
- `net.ipv4.tcp_max_syn_backlog` → 65535
- `net.core.netdev_max_backlog` → 65535
- `net.ipv4.ip_local_port_range` → `1024 65535` (avoid ephemeral port exhaustion under `-r` reconnect storms)
- `net.ipv4.tcp_tw_reuse` → 1
- `net.ipv4.tcp_max_tw_buckets` → 131072
- `net.core.rmem_max` / `wmem_max` → 7.5 MB (UDP buffer for QUIC)
- Loopback MTU → 1500 (realistic Ethernet; the default 65536 hides kernel segmentation cost)
- Docker daemon restart to pick up the new limits

Post-run `system_restore` reverts governor and loopback MTU to defaults.

## Practical takeaways

1. **CCXs are the locality unit, not NUMA nodes.** Pin consumers to contiguous 4-core groups when you can; avoid splitting a CCX across two consumers unless you explicitly want them to share L3 (like Redis + server).
2. **Keep SMT pairs together.** Every cpuset in the harness respects `(N, N+64)` pairing - preserved automatically if you specify cpusets like `a-b,(a+64)-(b+64)`.
3. **NUMA is a non-issue on this chip.** Don't waste time with `numactl --membind` or NPS subdivision.
4. **Memory bandwidth is 99.8% idle** at our rps. Memory-side optimizations only help workloads with much higher per-request data movement (analytics, streaming) than REST-API-style request handling.
