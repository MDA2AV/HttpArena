---
title: Implementation Rules
weight: 5
---

Every entry has a **type** (what it is) and, for frameworks, a **mode** (how it is run). Set both in `meta.json`.

## Type

- **Flagship** - a mature framework backed by an active development team, with a solid ecosystem (libraries, middleware, tooling) and an established community around it. Full-featured, and covers a complete test category (e.g. all HTTP/1.1 profiles).
- **Emerging** - a genuine framework that does not yet meet the full flagship bar: newer, more minimal, or only partial coverage.
- **Engine** - a bare-metal HTTP implementation (raw sockets, custom parser, low-level I/O). Not a framework; ranked separately.
- **Infrastructure** - a reverse proxy or static-file server (nginx, h2o) used without an application framework layer.

Flagship vs Emerging reflects maturity, not how the code is written - pick your best fit and it may be adjusted on review.

## Mode

Framework entries (flagship and emerging) declare how they are run. The same framework can be submitted in either mode; tuned entries are marked with a ring on the leaderboard and ranked alongside standard ones.

{{< cards >}}
  {{< card link="production" title="Standard" subtitle="Default, production-style usage: documented framework APIs, production settings, and standard libraries." icon="shield-check" >}}
  {{< card link="tuned" title="Tuned" subtitle="Non-default configs, experimental flags, and custom optimizations allowed." icon="adjustments" >}}
{{< /cards >}}

## Ranked separately

{{< cards >}}
  {{< card link="engine" title="Engine" subtitle="Bare-metal HTTP implementations. No restrictions, ranked separately." icon="lightning-bolt" >}}
  {{< card link="infrastructure" title="Infrastructure" subtitle="Reverse proxies and static-file servers (nginx, h2o)." icon="server" >}}
{{< /cards >}}
