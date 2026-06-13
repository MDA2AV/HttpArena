---
title: Frameworks
weight: 1
---

Framework entries are real web frameworks, grouped into three maturity tiers. The tier reflects maturity, not how the code is written - pick your best fit and it may be adjusted on review. Set it with `meta.json.type`.

- **Flagship** - a mature framework backed by an active development team, with a solid ecosystem (libraries, middleware, tooling) and an established community around it. Full-featured, and covers a complete test category (e.g. all HTTP/1.1 profiles).
- **Emerging** - a genuine framework that does not yet meet the full flagship bar: newer, more minimal, or only partial coverage.
- **Experimental** - very new work that has not proved itself yet. Ranked alongside frameworks, but hidden by default on the leaderboard (opt-in via the type filter).

All three are scored in the same framework normalization pool and can be combined on the leaderboard.

## Mode

Every framework entry also declares a **mode** in `meta.json.mode` - how strictly it follows the implementation rules. The same framework can be submitted in either mode; tuned entries are marked with a ring on the leaderboard and ranked alongside standard ones.

{{< cards >}}
  {{< card link="standard" title="Standard" subtitle="Default, production-style usage: documented framework APIs, production settings, and standard libraries." icon="shield-check" >}}
  {{< card link="tuned" title="Tuned" subtitle="Non-default configs, experimental flags, and custom optimizations allowed." icon="adjustments" >}}
{{< /cards >}}
