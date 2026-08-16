---
title: Framework Matcher
seo_title: "Framework matcher: how the match score is computed"
description: "How /match/ turns the weights you set into a ranking: per-dimension scores from the same measurements as the composite, normalized inside the entry's own league."
weight: 10
---

The [matcher](/match/) answers a question the leaderboard does not: not "who is fastest", but "what fits what I am building". You set how much each thing matters, from 0 to 5, and the page ranks every entry against those weights.

Nothing new is measured. Every dimension is built from the same numbers the [composite score](composite-score) sums.

## The dimensions

| Kind | What the score is |
|---|---|
| Protocol | The family composite, as a percentage of the best in the field |
| Workload | The average of the normalized RPS over the profiles that workload covers |
| Cost | Best in the field divided by this entry's own value, so lower is better |

Memory and p99 are taken as measured. CPU is taken per request, not as a percentage: a server doing 1.3M requests per second at 6700% CPU is cheaper per request than one doing 100k at 700%, and scoring the raw percentage would reward the server that did the least work.

A cost is averaged over every profile the entry is scored on, so it describes the entry and not one lucky run.

## The match score

```
match = sum(weight × dimension) / sum(weight)
```

Only the dimensions you moved off zero count. The weights live in the URL, so a set of weights is a link you can send to somebody.

## The field

You pick one field to compare inside: frameworks, experimental entries, engines, or proxies and static file servers. They are separate competitions, scored on different profile sets, and a 100 in one is not a 100 in another, so the page never mixes them. Language and tuned entries are filters on top: they change who is listed, never what anybody scored.

A dimension the entry has no result for counts as zero. If you asked for HTTP/3 and an entry does not speak it, not having it is the answer.
