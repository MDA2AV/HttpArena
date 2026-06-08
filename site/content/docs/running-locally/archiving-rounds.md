---
title: Archiving Rounds
weight: 4
---

Snapshot current benchmark results as named rounds that users can browse on the leaderboard.

## Overview

You can archive the current benchmark results as a named snapshot. On the leaderboard, users can switch between archived rounds and the current ongoing results.

## Creating a snapshot

```bash
./scripts/archive.sh create "Round 1 - March 2026"
```

When you create a snapshot, it bundles all current result data from `site/data/*.json` into a single `site/data/rounds/<id>.json` file. After rebuilding Hugo, the round selector will appear on the leaderboard page letting users switch between "Current" and any archived rounds.

## Listing archived rounds

```bash
./scripts/archive.sh list
```

## Deleting an archived round

```bash
./scripts/archive.sh delete 1
```
