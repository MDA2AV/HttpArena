---
title: Composite Score
---

The composite score combines results from multiple test profiles into a single number that reflects overall framework performance. Each profile is normalized to a 0–100 scale, then **summed** across all scored profiles. An optional memory toggle adds a 0–50 bonus per profile for memory-efficient frameworks on top of their raw-throughput score.

## How it works

### Step 1: Average RPS per profile

For each framework and profile, compute the average RPS across all connection counts. This rewards frameworks that scale well across concurrency levels rather than just their peak.

### Step 2: Normalize per profile

For each profile, normalize against the best-performing framework:

```
rpsScore = (framework_avg_rps / best_avg_rps) × 100
```

This produces a 0–100 value where the top framework scores 100.

**Exception: JSON Compressed.** The `json-comp` profile applies a compression-ratio gain before normalization so frameworks that ship smaller response bodies are rewarded directly. Instead of averaging raw rps, `avgRps` is first scaled by `(minBpr / myBpr)²` where `myBpr = avgBw / avgRps` and `minBpr` is the smallest bytes-per-response across the field. Doubling the response size quarters the score. See the [JSON Compressed implementation](/docs/test-profiles/h1/isolated/json-compressed/implementation/#scoring) for the full formula and rationale.

### Step 3: Sum across scored profiles

The final composite score is the **sum** of per-profile scores across all **scored** profiles:

```
composite = sum(scored_profile_scores)
```

Summing instead of averaging means the composite scales with the number of scored profiles: a framework that places well in many profiles separates cleanly from one that only wins a single profile. A perfect-across-the-board framework earns 100 points per profile, so with the current 26 scored profiles for production/tuned entries the raw-throughput ceiling is ~2,600, rising to ~3,900 when the memory-efficiency toggle is on (each profile adds up to 50 more points). Engine and infrastructure entries are scored on smaller subsets and have correspondingly lower ceilings.

Frameworks that don't participate in a scored profile receive 0 for that profile, which lowers their composite by the full 100-point ceiling of that profile.

## Scored vs reference-only profiles

Not all profiles count toward the composite score. Profiles marked as **scored** contribute to the composite. Reference-only profiles (marked with **\***) are displayed for comparison but do not affect the ranking.

### H/1.1 Isolated

| Profile | Scored | Workload |
|---|---|---|
| Baseline | Yes | Mixed GET/POST with query parsing |
| Pipelined | Yes | 16 requests batched per connection |
| Short-lived | Yes | Connections closed after 10 requests |
| JSON | Yes | Dataset processing and serialization |
| JSON Compressed | Yes | JSON with `Accept-Encoding: gzip, br` and multiplier `?m=N` |
| JSON TLS | Yes | JSON workload over HTTP/1.1 + TLS on port 8081 |
| Upload | Yes | 20 MB body ingestion, return byte count |
| Static | Yes | 20 static files served over HTTP/1.1 |
| Async DB | Yes | Async Postgres query with connection pooling |
| CRUD | Yes | Realistic REST API against Postgres: cached reads (75%), updates (15%), list (5%), upsert create (5%). Cache-aside with 200ms TTL (in-process or Redis sidecar) |
| TCP Frag | No (*) | Baseline with MTU 69 — TCP fragmentation stress |

### H/1.1 Workload

| Profile | Scored | Workload |
|---|---|---|
| API-4 | Yes | Baseline + JSON + async-db on 4 CPUs |
| API-16 | Yes | Baseline + JSON + async-db on 16 CPUs |

### H/2

| Profile | Scored | Workload |
|---|---|---|
| Baseline | Yes | Query parsing over TLS with multiplexed streams |
| Static | Yes | 20 static files served over TLS with multiplexed streams |
| Baseline h2c | Yes | Query parsing over cleartext h2 on port 8082 (prior-knowledge, anti-cheat rejects dual-serving HTTP/1.1) |
| JSON h2c | Yes | JSON serialization workload over cleartext h2 on port 8082 |

### H/3

| Profile | Scored | Workload |
|---|---|---|
| Baseline | Yes | Query parsing over QUIC (UDP) with TLS 1.3 |
| Static | Yes | 20 static files served over QUIC (UDP) with TLS 1.3 |

### Gateway

| Profile | Scored | Workload |
|---|---|---|
| Gateway H2 | Yes | Two-service proxy + server stack over HTTP/2 + TLS, mixed workload (static 30%, JSON 35%, baseline 20%, async-db 15%), 64-CPU budget |
| Gateway H3 | Yes | Same two-service stack over HTTP/3 + QUIC at the edge |
| Production Stack H2 | Yes | Four-service CRUD API (edge + Redis + JWT auth + server) with 10K-item cache-aside, JWT verified every request, concurrent reads + writes |

### gRPC

| Profile | Scored | Workload |
|---|---|---|
| Unary | Yes | gRPC unary call over cleartext HTTP/2 |
| Unary TLS | Yes | gRPC unary call over TLS |

### WebSocket

| Profile | Scored | Workload |
|---|---|---|
| Echo | Yes | WebSocket echo throughput |

TCP Frag and Noisy are reference-only — shown for comparison but not counted in the composite score.

## Memory efficiency bonus

An optional toggle rewards memory efficiency with an **additive** bonus per profile. It never scales down the raw-throughput score — it only adds on top of it, up to +50 points for the most memory-efficient framework in that profile.

This uses an **efficiency ratio** (`rps / memoryMB`), not absolute memory usage. A framework that is fast *and* lean gets the largest bonus; a framework that uses little memory only because it is slow earns less, because its rps is in the numerator of the ratio.

CPU efficiency was intentionally dropped: a framework that leaves CPU on the table already scores worse on RPS, so penalizing it a second time for "low efficiency" double-counted the same signal and flattened the throughput differentiation that the benchmark exists to measure.

### How the memory bonus is computed

For each profile, compute the efficiency ratio for every framework:

```
memEfficiency = sqrt(rps) / memoryMB
```

Why `sqrt(rps)` instead of `rps`? A plain `rps / MB` ratio double-counts throughput: high-rps frameworks would win both `rpsScore` *and* `memScore` because `rps` dominates the ratio. Taking the square root dampens rps to log-scale — it still matters (a dead framework shouldn't win "efficiency"), but memory can now actually move the needle.

Normalize against the best efficiency in that profile:

```
memScore = (framework_memEff / best_memEff) × 100
```

Add half of it on top of the RPS score:

```
profileScore = rpsScore + 0.5 × memScore
```

With the toggle on, per-profile scores range 0–150 (up to 100 from throughput, up to 50 from memory efficiency). Frameworks with no memory data keep their plain `rpsScore`.

### Example

| Framework | RPS | Mem (MB) | sqrt(rps)/MB |
|---|---|---|---|
| A | 500,000 | 50 | 14.14 |
| B | 100,000 | 20 | 15.81 |

- RPS scores: A = 100, B = 20
- Memory efficiency scores: A = 89.4, B = 100 (best)

With the memory toggle on:
- A: `100 + 0.5 × 89.4 = 144.7`
- B: `20 + 0.5 × 100 = 70.0`

B actually wins the memory term despite A's 5× throughput advantage, because `sqrt(rps)` only gives A a √5 ≈ 2.24× boost in the numerator — not enough to beat B's 2.5× memory savings. A still wins overall thanks to its raw throughput lead, but B's lean memory footprint is now rewarded meaningfully instead of being drowned out.

## Type-specific scoring

Types are scored **separately** — each has its own composite ranking and normalization pool. The scored profiles differ by type:

- **Frameworks** (Production + Tuned) are scored on all scored profiles across H/1.1, H/2, H/3, gRPC, and WebSocket.
- **Infrastructure** (nginx, h2o, and similar proxies/servers) are scored only on Baseline, Pipelined, Short-lived, and Static — the profiles that don't require executing application logic. Other profiles (JSON, async-db, etc.) may be displayed as reference data but do not count toward the infrastructure composite.
- **Engines** are scored on a reduced set: Baseline, Pipelined, Short-lived, API-4, H/2 (both), H/3 (both), gRPC (both), and WebSocket, since most engines don't implement the heavier endpoints (JSON, upload).

The Type filter on the composite leaderboard switches between these rankings. Production and Tuned can be combined (they share the framework normalization pool); Infrastructure and Engine are each exclusive.

## Why this approach

- **Sum across profiles** — larger numbers separate strong all-rounders from frameworks that only win a single profile; a framework that covers 15 profiles at 80% crushes one that wins one profile at 100%
- **Normalization** — each profile contributes equally regardless of absolute RPS scale (baseline at 1M vs JSON at 200K), and is capped at 100 points per profile
- **Additive memory bonus** — memory-efficient frameworks earn up to +50 per profile on top of their RPS score; slow frameworks can't game the bonus because `rps` is in the efficiency numerator
- **Average across connections** — each framework is scored on its average RPS across all connection counts, rewarding consistent scaling
