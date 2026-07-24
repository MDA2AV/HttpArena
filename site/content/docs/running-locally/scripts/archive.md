---
title: archive.sh
weight: 5
---

Manage benchmark result archives (rounds). Snapshots current results as a named round, lists archived rounds, or deletes a round.

```bash
./scripts/archive.sh create <name>
./scripts/archive.sh list
./scripts/archive.sh delete <id>
```

## Commands

### create

Archives all current benchmark results as a named round.

```bash
./scripts/archive.sh create "Round 1 - March 2026"
```

What it does:

1. Bundles all `site/data/*.json` files into a single round file at `site/data/rounds/<id>.json`
2. Records hardware info (CPU, cores, RAM, governor), OS, kernel, Docker version, and git commit
3. Reads system info from `site/data/current.json` if available (written by `benchmark.sh --save`)
4. Updates the round index at `site/data/rounds/index.json`
5. **Clears `results/`** and resets site data files to start a fresh round

### list

Lists all archived rounds with their ID, name, date, and file size.

```bash
./scripts/archive.sh list
```

Example output:

```
  # 1  Round 1 - March 2026                    2026-03-15  (1248KB)
  # 2  Round 2 - Pre-optimization baseline      2026-03-20  (1305KB)
```

### delete

Deletes an archived round by ID.

```bash
./scripts/archive.sh delete 1
```

Removes the round's data file and its entry from the index.
