---
title: Archiving Rounds
seo_title: "Archiving Benchmark Rounds"
description: "Snapshot the current results as a named round so previous benchmark generations stay browsable on the leaderboard."
weight: 4
---

Snapshot current benchmark results as named rounds that users can browse on the leaderboard.

## Overview

You can archive the current benchmark results as a named snapshot. On the leaderboard, users can switch between archived rounds and the current ongoing results.

## Creating a snapshot

```bash
./scripts/archive.sh create "Round 1 - March 2026"
```

When you create a snapshot, it bundles all current result data from `site/data/results/*.json` into a single `site/data/rounds/<id>.json` file. After re-running `scripts/gen_new_leaderboard_data.py`, the round selector will appear on the leaderboard page letting users switch between "Current" and any archived rounds.

## Listing archived rounds

```bash
./scripts/archive.sh list
```

## Deleting an archived round

```bash
./scripts/archive.sh delete 1
```
