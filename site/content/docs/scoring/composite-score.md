---
title: Composite Score
---

The composite score combines results from multiple test profiles into a single number that reflects overall framework performance. It uses a normalized arithmetic mean with optional resource efficiency factors.

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

### Step 3: Arithmetic mean

The final composite score is the arithmetic mean of per-profile scores across all **scored** profiles:

```
composite = sum(scored_profile_scores) / number_of_scored_profiles
```

Frameworks that don't participate in a scored profile receive 0 for that profile, which lowers their composite proportionally.

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

### H/3

| Profile | Scored | Workload |
|---|---|---|
| Baseline | Yes | Query parsing over QUIC (UDP) with TLS 1.3 |
| Static | Yes | 20 static files served over QUIC (UDP) with TLS 1.3 |

### H/2 Gateway

| Profile | Scored | Workload |
|---|---|---|
| Gateway-64 | Yes | Two-service proxy + server stack (static / JSON / async-db / baseline mix) over HTTP/2 + TLS, 64-CPU budget split freely between proxy and server |

### H/3 Gateway

| Profile | Scored | Workload |
|---|---|---|
| Gateway-H3 | Yes | Same two-service stack as Gateway-64 but with HTTP/3 + QUIC at the edge, measuring h3 proxy termination efficiency at realistic connection counts |

### Production Stack

| Profile | Scored | Workload |
|---|---|---|
| Production Stack | Yes | Four-service CRUD API deployment (edge + Redis cache + JWT auth sidecar + framework server) with 10K-item working set. JWT HMAC-SHA256 verified on every `/api/*` request (no caching). Framework implements cache-aside with ≤1s TTL (cache strategy is the framework's choice). Concurrent reads + writes via split h2load. |

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

## Resource efficiency factors

Two optional toggles allow factoring in resource efficiency:

- **CPU efficiency** (1× weight) — measures requests per CPU percent (`rps / cpu%`)
- **Memory efficiency** (0.5× weight) — measures requests per megabyte (`rps / MB`)

These use **efficiency ratios**, not absolute resource usage. A framework that achieves high throughput with low resource consumption scores well. A framework that uses little CPU simply because it is slow does **not** benefit.

### How resource scores are computed

For each profile, compute the efficiency ratio for every framework:

```
cpuEfficiency = rps / cpu%
memEfficiency = rps / memoryMB
```

Normalize against the best efficiency in that profile:

```
cpuScore = (framework_cpuEff / best_cpuEff) × 100
memScore = (framework_memEff / best_memEff) × 100
```

Combine with the RPS score using configured weights:

```
profileScore = (rpsScore × 1 + cpuScore × wCpu + memScore × wMem) / totalWeight
```

Where `totalWeight = 1 + wCpu + wMem`. With both factors active, `totalWeight = 2.5`, so RPS counts 40%, CPU efficiency 40%, and memory efficiency 20%.

### Example

| Framework | RPS | CPU% | Mem (MB) | rps/cpu | rps/MB |
|---|---|---|---|---|---|
| A | 500,000 | 800% | 50 | 625 | 10,000 |
| B | 100,000 | 100% | 20 | 1,000 | 5,000 |

- RPS scores: A = 100, B = 20
- CPU efficiency scores: A = 62.5, B = 100 (B gets more throughput per CPU unit)
- Memory efficiency scores: A = 100, B = 50

With both factors on (`totalWeight = 2.5`):
- A: `(100 + 62.5 + 50) / 2.5 = 85.0`
- B: `(20 + 100 + 25) / 2.5 = 58.0`

Framework A still leads because its raw throughput advantage outweighs B's CPU efficiency, but the gap narrows from 5× to 1.5×.

## Engine-level implementations

Engines and frameworks are scored **separately** — each type has its own composite ranking and normalization pool. The scored profiles differ by type:

- **Frameworks** are scored on all scored profiles across H/1.1, H/2, H/3, gRPC, and WebSocket.
- **Engines** are scored on a reduced set: Baseline, Pipelined, Short-lived, API-4, H/2 (both), H/3 (both), gRPC (both), and WebSocket, since most engines don't implement the heavier endpoints (JSON, upload).

The Type filter on the composite leaderboard switches between the two rankings.

## Why this approach

- **Arithmetic mean** — straightforward averaging that doesn't over-penalize a single weak profile
- **Normalization** — each profile contributes equally regardless of absolute RPS scale (baseline at 1M vs JSON at 200K)
- **Efficiency ratios** — resource factors measure throughput per unit of resource, preventing slow frameworks from gaming the score by using fewer absolute resources
- **Average across connections** — each framework is scored on its average RPS across all connection counts, rewarding consistent scaling
