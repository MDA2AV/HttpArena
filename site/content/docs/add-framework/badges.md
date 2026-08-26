---
title: README Badge
seo_title: "HttpArena README Badge: publish your framework's rank"
description: "Add a live HttpArena rank badge to your project's README: one URL per protocol family, updated every time the leaderboard is republished."
weight: 5
---

Once your framework has results on the board, it gets a badge for every protocol
family it scored in. The badge reports where the entry ranks, and it re-renders
itself each time the leaderboard is republished. You paste it once.

> **HTTP Arena H/1.1** · `#6 of 71`

## Paste it

```md
[![HTTP Arena](https://img.shields.io/endpoint?url=https://www.http-arena.com/badge/actix/h1.json)](https://www.http-arena.com/#type=emerging,flagship&tuned=0)
```

Replace `actix` with your entry and `h1` with the family you want. The exact
line for your framework, already assembled and deep-linked to the right view of
the board, is in [`/badge/index.json`](https://www.http-arena.com/badge/index.json)
under `scopes.<family>.default.markdown`.

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

## Ranked among your own language

Optional, and a second badge rather than a replacement. Append `-<language>` to
the family and the badge reads **`#1 of 6 (Rust)`**:

```md
[![HTTP Arena](https://img.shields.io/endpoint?url=https://www.http-arena.com/badge/actix/h1-rust.json)](https://www.http-arena.com/#type=emerging,flagship&tuned=0&lang=Rust)
```

The language segment is the board's own language name, lowercased, with `#`
spelled out as `sharp` and `++` as `pp`: `C#` → `csharp`, `C++` → `cpp`,
`TS` → `ts`, `JS` → `js`. Your ready-made line is in
[`/badge/index.json`](https://www.http-arena.com/badge/index.json) under
`scopes.<family>.byLanguage.markdown`.

## Counting tuned entries in

Also optional. The default field is **standard configurations only**, so the
number compares like for like: a stock server is never ranked against
someone else's hand-tuned build. Append `-with-tuned` to count tuned entries
as well:

```md
[![HTTP Arena](https://img.shields.io/endpoint?url=https://www.http-arena.com/badge/actix/h1-with-tuned.json)](https://www.http-arena.com/#type=emerging,flagship&tuned=1)
```

The suffixes combine, so the full set for one family is:

| File | Field |
|---|---|
| `h1.json` | standard entries |
| `h1-with-tuned.json` | standard + tuned |
| `h1-rust.json` | standard, one language |
| `h1-rust-with-tuned.json` | standard + tuned, one language |

Each is in [`/badge/index.json`](https://www.http-arena.com/badge/index.json)
under `scopes.<family>`, keyed `default`, `withTuned`, `byLanguage` and
`byLanguageWithTuned`.

**If your entry is itself tuned**, it has no place in the standard-only field,
so its default URL serves the tuned-inclusive ranking instead, and `h1.json`
and `h1-with-tuned.json` give it the same number. Nothing to change, and no URL
stops working.

This is a **filter, not a rescore**. Scores and order are identical to the
overall badge; only the field is narrowed, so the two can never disagree about
who is ahead of whom. The link opens the board filtered to that language with
`#lang=Rust`, an exact match unlike the search box, so the field on the page is
the field the badge claims.

## What the colours mean

The two halves are read separately. The **right** half is placement: gold for
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
that family: the same sum of normalized per-profile scores the board shows,
computed the same way, at the board's default settings. Following the badge
lands you on the field it was measured against, meaning the whole league for
that family rather than your entry on its own, so `#6 of 83` has the other 82
next to it.

**You are ranked inside your own tier.** `flagship` and `emerging` entries rank
together as one field, because that is the board's default view. `engine`
entries rank among engines, over the smaller profile subset engines are scored
on. Keeping the tiers apart is what stops a framework's 100 from being set by an
engine's result, or the reverse.

**A badge only exists where you scored.** No result in a family means no badge
for that family. A family where your tier holds a single entry publishes
nothing, because a rank is only worth showing once there was somebody to beat.

**The field is every row the board lists.** `#1 of 31` is the number you get
counting rows in that league on the linked page. That includes entries sitting
at 0 because nothing they ran counts for their tier. An engine whose only
HTTP/1.1 results are `json` (not scored for engines) and `pipelined`
(reference-only) still holds a place in the field. Those entries are counted,
but get no badge of their own: there is no placing to claim.

## Freshness

The endpoints are regenerated whenever the site deploys, including every time a
benchmark result is saved, since results live under `site/`. Two caches sit in
front of that:

| | Holds a stale rank for |
|---|---|
| shields.io | 5 minutes (`cacheSeconds`, at its floor) |
| GitHub Camo | a few hours |

So a new rank is visible almost immediately wherever the badge is embedded
directly, and takes a few hours to turn over inside a GitHub README. Nothing to
re-paste either way. To see the current value straight away, add any parameter
to the shields URL, such as `&style=flat-square`, which makes a fresh cache key.

## Styling

The endpoints are plain [shields.io](https://shields.io) documents, so shields'
own options work. Append `&style=flat-square`, `&logo=rust` or `&labelColor=…`
to the `img.shields.io` URL.
