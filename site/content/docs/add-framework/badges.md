---
title: README Badge
seo_title: "HttpArena README Badge — publish your framework's rank"
description: "Add a live HttpArena rank badge to your project's README: one URL per protocol family, updated every time the leaderboard is republished."
weight: 5
---

Once your framework has results on the board, it gets a badge for every protocol
family it scored in. The badge reports where the entry ranks, and it re-renders
itself each time the leaderboard is republished — you paste it once.

> **HTTP Arena H/1.1** · `#6 of 71`

## Paste it

```md
[![HTTP Arena](https://img.shields.io/endpoint?url=https://www.http-arena.com/badge/actix/h1.json)](https://www.http-arena.com/#type=emerging,flagship&tuned=1)
```

Replace `actix` with your entry and `h1` with the family you want. The exact
line for your framework, already assembled and deep-linked to the right view of
the board, is in [`/badge/index.json`](https://www.http-arena.com/badge/index.json)
under `markdown`.

## Families

| Family | `<family>` | What the composite covers |
|---|---|---|
| HTTP/1.1 | `h1` | Connection, Workload, Database and Multi-endpoint profiles |
| HTTP/2 | `h2` | the HTTP/2 profiles |
| HTTP/3 | `h3` | the HTTP/3 profiles |
| Gateway | `gw` | reverse-proxy and production-stack profiles |
| gRPC | `grpc` | unary and streaming, plaintext and TLS |
| WebSocket | `ws` | the echo profiles |

`<framework>` is your entry's board name, lowercased, with anything outside
`A-Z a-z 0-9 . _ -` replaced by `-`. It is the same name as your file under
`site/data/results/`, so `aspnet-minimal + nginx` becomes
`aspnet-minimal-nginx`.

## What the colours mean

The two halves are read separately. The **right** half is placement — gold for
first, then shading down by how far into the field the entry sits. The **left**
half is the tier it competed in, in the same four colours the board uses for the
type swatch beside every framework name:

| | Tier | Ranked against |
|---|---|---|
| 🟩 | `flagship` | flagship + emerging, as one field |
| 🟦 | `emerging` | flagship + emerging, as one field |
| 🟧 | `experimental` | other experimental entries |
| 🟥 | `engine` | other engines, on the profiles engines are scored on |

The tier is also in [`/badge/index.json`](https://www.http-arena.com/badge/index.json)
as `type`, next to each entry's ranks.

## What the number means

The rank comes from the [composite score](/docs/scoring/composite-score/) for
that family — the same sum of normalized per-profile scores the board shows,
computed the same way, at the board's default settings. Following the badge
lands you on the field it was measured against — the whole league for that
family, not your entry on its own, so `#6 of 83` has the other 82 next to it.

**You are ranked inside your own tier.** `flagship` and `emerging` entries rank
together as one field, because that is the board's default view. `engine`
entries rank among engines, over the smaller profile subset engines are scored
on. Keeping the tiers apart is what stops a framework's 100 from being set by an
engine's result, or the reverse.

**A badge only exists where you scored.** No result in a family means no badge
for that family. A family where your tier holds a single entry publishes
nothing — a rank is worth showing once there was somebody to beat.

## Freshness

The endpoints are regenerated whenever the site deploys. After that, GitHub
serves README images through its Camo proxy, which caches them, so a changed
rank can take a few hours to appear on GitHub itself.

## Styling

The endpoints are plain [shields.io](https://shields.io) documents, so shields'
own options work — append `&style=flat-square`, `&logo=rust`, `&labelColor=…` to
the `img.shields.io` URL.
