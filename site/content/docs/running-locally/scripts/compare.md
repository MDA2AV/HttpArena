---
title: compare.sh
weight: 4
---

Compare a framework's benchmark results against the published leaderboard data on the main branch. Outputs a Markdown table with deltas, suitable for PR comments.

```bash
./scripts/compare.sh <framework> [profile]
```

## Options

| Parameter | Description |
|-----------|-------------|
| `<framework>` | Name of the framework to compare |
| `[profile]` | Optional - compare only this test profile |

## What it does

1. Reads new results from `results/<profile>/<connections>/<framework>.json`
2. Reads published leaderboard data from `site/data/<profile>-<connections>.json`
3. Matches the framework by its `display_name` from `meta.json`
4. Outputs a Markdown table for each profile with columns per connection count

## Metrics compared

For each profile and connection count, the table shows:

| Metric | Direction | Description |
|--------|-----------|-------------|
| **RPS** | Higher is better | Requests per second |
| **p99** | Lower is better | 99th percentile latency |
| **CPU** | Lower is better | CPU utilization percentage |
| **Memory** | Lower is better | Memory usage |

Each value includes a percentage delta against the main branch. New frameworks with no prior data show `NEW` instead of a delta.

## Example output

```markdown
### baseline

| Metric | 512c |  | 4096c |  |
|--------|------|--|-------|--|
| **RPS** | 1.30M | +2.1% | 1.37M | -0.5% |
| **p99** | 2.00ms | ~0% | 33.80ms | +1.2% |
| **CPU** | 6530% | ~0% | 6274% | -0.3% |
| **Memory** | 408MB | ~0% | 922MB | +0.8% |
```

## CI usage

The `benchmark-pr.yml` workflow calls this script automatically after benchmarking a PR branch, and posts the comparison table as a PR comment.
