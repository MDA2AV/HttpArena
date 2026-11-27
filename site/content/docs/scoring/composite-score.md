---
title: Composite Score
seo_title: "Composite Score Methodology"
description: "The composite score explained: per-profile normalization, the weights, the weighted sum across scored profiles, the compression adjustment and the memory bonus."
---

The composite score combines results from multiple test profiles into a single number that reflects overall framework performance. Each profile is normalized to a 0–1,000 scale, multiplied by its [weight](#weights), then **summed** across the scored profiles of one protocol family - HTTP/1.1, HTTP/2, HTTP/3, Gateway, gRPC or WebSocket. Each family has its own composite, and the board shows one at a time - or five of them side by side in the [overall composite](#overall-composite), which adds them up. An optional memory toggle adds a 0–500 bonus per profile for memory-efficient frameworks on top of their raw-throughput score.

## How it works

### Step 1: Average RPS per profile

For each framework and profile, compute the average RPS across the profile's scored connection counts. This rewards frameworks that scale well across concurrency levels rather than just their peak.

### Step 2: Normalize per profile

For each profile, normalize against the best-performing framework:

```
rpsScore = (framework_avg_rps / best_avg_rps) × 1000
```

This produces a 0–1,000 value where the top framework scores 1,000.

The scale is 1,000 rather than 100 for resolution, not for meaning. Nothing about the ranking depends on it: every score moves by the same factor. But summing two dozen profiles that each round to a whole number out of 100 put clusters of entries on identical totals, and the extra digit separates them at no cost.

**Exception: JSON Compressed.** The `json-comp` profile applies a compression-ratio gain before normalization so frameworks that ship smaller response bodies are rewarded directly. Instead of averaging raw rps, `avgRps` is first scaled by `(minBpr / myBpr)²` where `myBpr = avgBw / avgRps` and `minBpr` is the smallest bytes-per-response across the field. Doubling the response size quarters the score. See the [JSON Compressed implementation](/docs/test-profiles/h1/json-compressed/implementation/#scoring) for the full formula and rationale.

**Normalized against the whole field, not the current view.** The 1,000-point reference for each profile is the best result in the full field, regardless of what the leaderboard is currently filtering to. Filtering by language, hiding tuned entries or searching for a name changes which rows are *displayed*; it does not change any score. Without this, filtering to a single language re-based every profile on the best entry of that language, and because each profile's leader moved by a different factor, the summed ranking could reorder, showing one framework above another only while the filter was applied.

Framework types remain separate: engine entries are scored on their own subset of profiles, so an engine result never sets the reference for a framework entry.

The **Rescale to selection** toggle opts back into the other behaviour, normalizing against only the frameworks currently shown. That is the more useful view when the question is how a subset compares against itself, for example ranking the Ruby entries against each other rather than against the field.

**Exception: the fixed-rate profiles.** [Latency-1M](/docs/test-profiles/h1/latency-1m/implementation/#scoring), [Latency-10K](/docs/test-profiles/h1/latency-10k/implementation/#scoring) and [8Gbit](/docs/test-profiles/h1/8gbit/implementation/#scoring) pin their request rate, so every entry that holds the rate delivers the same one and normalizing on rps would score all of them 1,000. Each contributes its own 0–100 score instead, built from CPU, mean latency and the p99 tail, and that score is normalized against the leading score in the field - so the leader of one of these columns is worth 1,000, exactly like the leader of an rps column. Latency-1M and Latency-10K differ only in the rate offered - a saturating 1M req/s against a near-idle 10K - so they are scored separately and read separately, and share the weight of one profile in the composite ([weights](#weights)).

### Step 3: Sum across scored profiles

The final composite score is the **sum** of per-profile scores across the family's **scored** profiles, each multiplied by its weight:

```
composite = sum(weight × scored_profile_score)
```

#### Weights

Every profile has a weight, shown on its column header in each view of the board - the Old View, the Rack and the Aisle - and beside the connection counts on its own view:

- **1** for a scored profile: its 0–1,000 counts in full.
- **0** for a profile that is not scored for the entry's type: a reference column adds nothing.
- **A share of 1** for the profiles of a group. Some profiles measure one thing twice, so the scored profiles of a group share the weight of one profile between them and count as one test:

| Group | Profiles | Weight each |
|---|---|---|
| Held connections | CON-1M, CON-1M-TLS | 0.5 |
| Fixed-rate latency | Latency-1M, Latency-10K | 0.5 |
| JSON | JSON Compressed, JSON TLS | 0.5 |

A type that scores only one profile of a group gives that one the whole 1: engine and infrastructure entries are not scored on JSON Compressed, so JSON TLS weighs 1 for them.

Summing instead of averaging means the composite scales with the number of scored profiles: a framework that places well in many profiles separates cleanly from one that only wins a single profile. A perfect-across-the-board framework earns 1,000 points times the weight of each profile. On the HTTP/1.1 board, framework entries are scored on 10 profiles whose weights add up to 7, so the raw-throughput ceiling there is 7,000, rising to 10,500 when the memory-efficiency toggle is on (each profile adds up to 500 more points, times its weight). Engine entries are scored on a smaller subset whose weights also add up to 7, and infrastructure entries on five profiles of weight 1.

Frameworks that don't participate in a scored profile receive 0 for that profile, which lowers their composite by that profile's full ceiling: 1,000 points times its weight.

The finished sum is then cut by the entry's [completeness factor](../completeness/): 2.5% for each of routing, middleware, the request it hands you and the response it builds that the framework leaves to you, so an entry that does all four keeps its full score and one that does none keeps 90% of it. It is applied once to the total rather than per profile, and only to framework entries; engine, infrastructure and unassessed entries score ×1.00. It is also not applied on the WebSocket and gRPC boards, which do not measure the HTTP request-to-response path the four axes are about.

## Overall composite

The **Overall** view, first under Composite on the board, adds the family composites together:

```
overall = H/1.1 + H/2 + H/3 + gRPC + WebSocket
```

Each family is scored exactly as its own board scores it - its own scored profiles for the entry's type, their weights, its own leaders, the completeness factor where that board applies it - and nothing is re-weighted on top: each family composite weighs 1. Every scored profile is worth its weight times 1,000 to its leader there and here, so a family counts for what its weights add up to: for framework entries that is 7 on HTTP/1.1 (ten profiles, three pairs of them at half weight), 4 on HTTP/2, 2 on HTTP/3, 2 on gRPC and 3 on WebSocket. A family an entry does not serve adds nothing, so the overall rewards breadth as well as speed.

Each family gets a column with the entry's score on that board and the place it holds there. A type with no scored profile in a family has no column for it: infrastructure entries are scored on no gRPC or WebSocket profile.

Gateway is left out. Its profiles rank a whole stack - an edge proxy, a cache, an auth service - put in front of the entry, which is a different question from how the entry's own server does.

## Scored vs reference-only profiles

Not all profiles count toward the composite score. Profiles marked as **scored** contribute to the composite. Reference-only profiles (marked with **\***) are displayed for comparison but do not affect the ranking.

The tables below show whether a profile counts for framework entries. Engines and infrastructure are scored on their own sets, listed under [Type-specific scoring](#type-specific-scoring). Every scored profile outside HTTP/1.1 weighs 1; the HTTP/1.1 table gives each profile's [weight](#weights) for framework entries.

### H/1.1

| Profile | Scored | Weight | Workload |
|---|---|---|---|
| Baseline | Yes | 1 | Mixed GET/POST with query parsing |
| Pipelined | No (*) | 0 | 16 requests batched per connection. Reference-only - a raw I/O and middleware-efficiency indicator; HTTP/1.1 pipelining is disabled in modern browsers and proxies, so it no longer counts toward the composite ranking |
| Short-lived | Yes | 1 | Connections closed after 10 requests |
| Async Delay | Yes | 1 | `GET /delay/10` over 32,000 held connections - what the framework does while a request waits |
| Latency-10K | Yes | 0.5 | Fixed 10K req/s; scored on CPU cost and latency (0-100 score, see above) |
| Latency-1M | Yes | 0.5 | Fixed 1M req/s; scored on CPU cost and latency (0-100 score, see above) |
| CON-1M | Yes | 0.5 | One million held connections at a fixed 250K req/s; scored on CPU per request, memory, p50 and p99 ([held-connection score](/docs/test-profiles/h1/connections/implementation/#scoring)) |
| CON-1M-TLS | Yes | 0.5 | The same over TLS 1.3 |
| CON-5M | No (*) | 0 | Five million held connections at 1.25M req/s. Reference-only, and run only for the entries on the allowlist |
| JSON Compressed | Yes | 0.5 | JSON with `Accept-Encoding: gzip, br` and multiplier `?m=N` |
| JSON TLS | Yes | 0.5 | JSON workload over HTTP/1.1 + TLS on port 8081 |
| 8Gbit | Yes | 1 | 10 KB echoed over TLS at a fixed 50K req/s; scored on CPU cost and latency (0-100 score, see above) |
| Static TLS | No (*) | 0 | 20 static files over HTTP/1.1 + TLS. Reference-only for frameworks and engines, scored for infrastructure |

### H/2

| Profile | Scored | Workload |
|---|---|---|
| Baseline | Yes | Query parsing over TLS with multiplexed streams |
| Static | Yes | 20 static files served over TLS with multiplexed streams |
| Baseline h2c | Yes | Query parsing over cleartext h2 on port 8082 (prior-knowledge) |
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
| Echo Pipelined | Yes | Batched WebSocket echo throughput |
| Echo Short-lived | Yes | WebSocket echo with each connection closed after 10 messages |

### Database

| Profile | Scored | Workload |
|---|---|---|
| Async DB | Yes | Async Postgres query with connection pooling |
| Fortunes | Yes | DB query + HTML template render |

Async DB and Fortunes rank on their own board and count toward no other composite. The database and its driver dominate them far more than the framework does: a framework's `async-db` number mostly reports which Postgres driver its language has, which rules them out of a ranking of HTTP paths and is what this board ranks instead.

Pipelined and Static TLS are the reference-only profiles for framework entries - shown on the board as faded columns for comparison, but not counted in the composite score.

## Memory efficiency bonus

An optional toggle rewards memory efficiency with an **additive** bonus per profile. It never scales down the raw-throughput score - it only adds on top of it, up to +500 points for the most memory-efficient framework in that profile.

This uses an **efficiency ratio** (`rps / memoryMB`), not absolute memory usage. A framework that is fast *and* lean gets the largest bonus; a framework that uses little memory only because it is slow earns less, because its rps is in the numerator of the ratio.

CPU efficiency was intentionally dropped: a framework that leaves CPU on the table already scores worse on RPS, so penalizing it a second time for "low efficiency" double-counted the same signal and flattened the throughput differentiation that the benchmark exists to measure.

### How the memory bonus is computed

For each profile, compute the efficiency ratio for every framework:

```
memEfficiency = sqrt(rps) / memoryMB
```

Why `sqrt(rps)` instead of `rps`? A plain `rps / MB` ratio double-counts throughput: high-rps frameworks would win both `rpsScore` *and* `memScore` because `rps` dominates the ratio. Taking the square root dampens rps to log-scale - it still matters (a dead framework shouldn't win "efficiency"), but memory can now actually move the needle.

Normalize against the best efficiency in that profile:

```
memScore = (framework_memEff / best_memEff) × 1000
```

Add half of it on top of the RPS score:

```
profileScore = rpsScore + 0.5 × memScore
```

With the toggle on, per-profile scores range 0–1,500 (up to 1,000 from throughput, up to 500 from memory efficiency), and the composite takes each times its weight. Frameworks with no memory data keep their plain `rpsScore`.

### Example

| Framework | RPS | Mem (MB) | sqrt(rps)/MB |
|---|---|---|---|
| A | 500,000 | 50 | 14.14 |
| B | 100,000 | 20 | 15.81 |

- RPS scores: A = 1,000, B = 200
- Memory efficiency scores: A = 894, B = 1,000 (best)

With the memory toggle on:
- A: `1000 + 0.5 × 894 = 1447`
- B: `200 + 0.5 × 1000 = 700`

B actually wins the memory term despite A's 5× throughput advantage, because `sqrt(rps)` only gives A a √5 ≈ 2.24× boost in the numerator - not enough to beat B's 2.5× memory savings. A still wins overall thanks to its raw throughput lead, but B's lean memory footprint is now rewarded meaningfully instead of being drowned out.

## Type-specific scoring

Types are scored **separately** - each has its own composite ranking and normalization pool. The scored profiles differ by type:

- **Frameworks** (Flagship, Emerging and Experimental, in either Standard or Tuned mode) are scored on every profile marked *Yes* above, across H/1.1, H/2, H/3, Gateway, gRPC, WebSocket and Database.
- **Engines** are scored on the same set minus JSON Compressed and JSON h2c (so JSON TLS weighs 1 for them, the whole of its group), since most engines don't implement compression negotiation or a JSON pipeline over h2c: Baseline, Short-lived, Async Delay, Latency-10K, Latency-1M, JSON TLS, 8Gbit, H/2 Baseline, Static and Baseline h2c, H/3 (both), gRPC (both), the gateway profiles, WebSocket, and Async DB and Fortunes.
- **Infrastructure** (nginx, Caddy, h2o and similar proxies / static-file servers) is scored on the nine profiles a server can answer without an application framework behind it: Baseline, Pipelined, Short-lived, JSON TLS, Static TLS, and Baseline and Static over both H/2 and H/3. Everything else may be displayed as reference data but does not count.

Note that the infrastructure set is not a subset of the framework set. Pipelined is reference-only for frameworks and engines - it measures batching more than framework throughput - but for a proxy that behaviour is exactly what is being compared, so it counts there and only there. Static TLS works the same way: serving files is the job of a static-file server, so it counts for infrastructure only.

The Type filter on the composite leaderboard switches between these rankings. Flagship, Emerging and Experimental can be combined (they share the framework normalization pool); Engine and Infrastructure are each exclusive. Experimental is hidden by default and shown only when selected. Tuned entries (a `mode`, not a type) are shown within whichever framework types are selected, marked with a ring.

## Why this approach

- **Sum across profiles** - larger numbers separate strong all-rounders from frameworks that only win a single profile; a framework that covers 15 profiles at 80% crushes one that wins one profile at 100%
- **Normalization** - each profile contributes equally regardless of absolute RPS scale (baseline at 1M vs JSON at 200K), and is capped at 1,000 points per profile, times its weight
- **Weights** - two profiles that measure one thing share the weight of one, so holding a million connections, CPU and tails at a pinned rate, and JSON each count once rather than twice
- **Additive memory bonus** - memory-efficient frameworks earn up to +500 per profile on top of their RPS score; slow frameworks can't game the bonus because `rps` is in the efficiency numerator
- **Average across connections** - each framework is scored on its average RPS across all connection counts, rewarding consistent scaling
