# FrankenPHP + TrueAsync Performance Tuning Notes

Summary of a profiling session on `/baseline11` under `wrk -t8 -c256`.
Environment: 16 vCPU, Docker Desktop WSL2, Go 1.26.0, PHP 8.6.0-dev (release build, ZTS, `--enable-embed=shared`).

## Headline numbers

| Configuration | req/sec | vs default |
|---|---:|---:|
| `GOGC=100`, `WORKERS=GOMAXPROCS=16` (default) | 76 086 | — |
| `GOGC=1000`, `WORKERS=16` | 154 702 | +103% |
| `GOGC=1000`, `WORKERS=8`, `GOMAXPROCS=32` | **224 993** | **+196%** |

All on the same lightweight `/baseline11` handler.

## Findings

### 1. `GOGC=1000` is a universal win (+46% alone)

Default `GOGC=100` triggers GC roughly every 10 ms at 150k+ rps. With a tiny live set and
high allocation churn per request (a typical HTTP handler), letting the heap grow 11× before
collecting cuts GC frequency ~10× and removes almost all stop-the-world futex wakes.

- `GOGC=500` → +35% throughput
- `GOGC=1000` → **+46%** (sweet spot)
- `GOGC=2000` → lower throughput but slightly lower average latency
- `GOGC=off` + `GOMEMLIMIT=4GiB` → ~= GOGC=500, no additional win

Memory cost is a few hundred MB RSS — negligible on a benchmark box.

### 2. The dominant bottleneck is Go scheduler churn on cgo returns

`runtime.stopm` + `runtime.futex` account for **37 %** of CPU at `W=16, P=16` — more than
the PHP VM and I/O combined. Root cause: every cgo call (PHP execution) detaches the M from
its P via `handoffp`. On return, the M must re-acquire a P. When many cgo calls run
concurrently, all P's are hot → M parks via `stopm` → futex sleep → futex wake → re-acquire
P. The pattern repeats millions of times per second.

Profile (perf sampling, 10 s at 99 Hz):

```
 15.54 %  runtime.futex       ← stopm/startm pairs
  8.95 %  runtime.usleep      ← scheduler idle
  3.47 %  epoll_pwait         ← libuv per-worker reactor
  6.22 %  libphp.so           ← actual PHP execution
```

Go 1.26 already ships a 30 % cgo call overhead reduction + Green Tea GC — we are on 1.26, so
these wins are already baked in. The remaining cost is architectural.

### 3. **`GOMAXPROCS ≈ numCPU + W`** heals the scheduler

Over-provisioning P beyond physical core count dramatically reduces `stopm` pressure: when
an M returns from cgo it almost always finds a free P. The surplus M's get time-sliced by
the kernel, which is cheaper than Go's `stopm`/`sched.lock` path for this workload.

Measured optima on 16 vCPU:

| W   | Optimal P | Peak rps |
|----:|----------:|---------:|
| 2   | 16–32     | 186k    |
| **8** | **32** | **225k** ← overall best |
| 16  | 48        | 165k    |
| 32  | 64        | 161k    |
| 64  | 96        | 155k    |

Formula: **optimal P ≈ W + numCPU**, with diminishing returns above that (scheduler starts
paying mgmt cost on the larger idle-P pool).

### 4. Optimal `W` depends on handler workload profile

CPU-bound handlers (`/baseline11`, `/json`) peak at `W ≈ numCPU/4 … numCPU/2`.
I/O-bound handlers (`/db` with SQLite) keep scaling up to `W = numCPU+` — more workers mean
more parallel blocking on I/O.

Measured on 16 vCPU with GOGC=1000:

| W | baseline11 | json | db (SQLite) |
|---|---:|---:|---:|
| 1 | 204k | 198k | 12k |
| 2 | **242k** | **215k** | 17k |
| 4 | 242k | 194k | 20k |
| 8 | 187k | 139k | 31k |
| 16 | 76k | 70k | **53k** |

**Bottom line:** `num = GOMAXPROCS` is a good *safe* default because real applications
usually have at least one I/O call per request; the bench's `/baseline11` is a corner case.

### 5. CPU pinning with `taskset` hurts, not helps

Splitting 16 cores between `wrk` (0–7) and server (8–15) via `taskset` dropped throughput
by **−53%**. Linux CFS shares CPUs between wrk and frankenphp more efficiently than manual
partitioning when they live on the same host.

### 6. epoll_pwait scales linearly with W

Each async worker has its own `uv_loop_t` and its own eventfd for Go → PHP notifications.
At `W=16` we get 16 separate epoll objects; `epoll_pwait` rises to ~18% of CPU — but **only
under W over-provisioning**, where workers are chronically under-loaded and frequently hit
the slow reactor path. With correct `W` sizing the slow path is rarely reached.

## Recommended settings

### Default for cgo-heavy FrankenPHP deployments

```
GOGC=1000
GOMAXPROCS = 2 × num_cpu           # rule of thumb: numCPU + W
```

In `Caddyfile`:
```
worker {
    file /app/worker.php
    num  $WORKERS                   # see table above; 0 = GOMAXPROCS
    async
    buffer_size 1
}
```

### Quick copy-paste

For a 16-core box running a typical Laravel-like workload:
```bash
GOGC=1000 GOMAXPROCS=32 WORKERS=16 frankenphp run -c Caddyfile
```

For a pure lightweight microbenchmark (`/baseline11`, `/json`):
```bash
GOGC=1000 GOMAXPROCS=32 WORKERS=8 frankenphp run -c Caddyfile
```

## Open questions we did NOT measure

- Does `P ≈ 2 × numCPU` still hold on 64-core HttpArena hardware, or does the formula need
  adjustment? Needs measurement.
- `/db` and `/json` with `P={16,32,48,64}` — might shift the optimum `W` for I/O-heavy
  handlers.
- Green Tea GC impact isolated from `GOGC=1000` — both ship together in Go 1.26, effect is
  intertwined.

## References

- Go issue [#21827](https://github.com/golang/go/issues/21827): "big performance penalty
  with runtime.LockOSThread" (cgo/stopm interaction, open since 2017).
- Go 1.26 release notes: 30 % cgo overhead reduction via removal of per-P syscall state.
