---
title: Frameworks
seo_title: "Framework Entry Rules and Maturity Tiers"
description: "How framework entries are grouped into the Flagship, Emerging and Experimental tiers, and what each tier requires of a submission."
weight: 1
---

Framework entries are servers you write application code against. There is exactly one requirement:

> **The entry must implement HTTP itself** - parse the request line, headers and body, frame the response, and handle keep-alive, chunked bodies and fragmented reads correctly. It must pass the validation suite on its own, not by leaning on something in front of it.

That is the whole bar. **Routing, middleware, a plugin ecosystem and a template engine are not required.** A runtime's own HTTP server qualifies, and so does a minimal one, as long as applications are genuinely written and deployed on it.

How much the server does for you is not ignored - it is scored rather than gated. Routing, middleware, whether the request arrives already made - path parameters, query parameters, a body buffered or streamed - and whether the response is built for you are the four [completeness](/docs/scoring/completeness/) axes, and each one the entry leaves to you takes 2.5% off its composite. A thin server and a batteries-included framework compete in the same tier; the difference between them shows up in that factor and in the throughput they buy with it.

The three tiers grade one thing: **how proven the entry is in production.** Not ecosystem size, not feature count, not how many profiles it covers. Pick your best fit and it may be adjusted on review. Set it with `meta.json.type`.

- **Flagship** - proven in production. Real applications are built on it and operated on it at scale, and it is actively maintained. Whether it hands you a router and a middleware stack or a bare request callback makes no difference here.
- **Emerging** - a genuine, working server that is not yet production-proven: young, niche, or without real deployments to point to.
- **Experimental** - very new work that has not proved itself yet. Ranked alongside frameworks, but hidden by default on the leaderboard (opt-in via the type filter).

All three are scored in the same framework normalization pool and can be combined on the leaderboard.

## Completeness

Framework entries also declare **`completeness`** in `meta.json`: which of routing, middleware, the request it hands you and the response it builds the server does for you. Each one it leaves to you costs 2.5% of the whole composite, so a framework that does all four keeps its full score and one that does none keeps 90% of it. It is the counterweight to the open door above: a server can enter the framework tiers with nothing but an HTTP parser, but it competes there carrying the score of one.

What counts as done on each axis, how to declare it, and how the multiplier is computed are on the [Completeness](/docs/scoring/completeness/) page. Engine and infrastructure entries are not graded on it.

## Mode

Every framework entry also declares a **mode** in `meta.json.mode` - how strictly it follows the implementation rules. The same framework can be submitted in either mode; tuned entries are marked with a ring on the leaderboard and ranked alongside standard ones.

{{< cards >}}
  {{< card link="standard" title="Standard" subtitle="Default, production-style usage: documented framework APIs, production settings, and standard libraries." icon="shield-check" >}}
  {{< card link="tuned" title="Tuned" subtitle="Non-default configs, experimental flags, and custom optimizations allowed." icon="adjustments" >}}
{{< /cards >}}
