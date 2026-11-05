---
title: Achievements
seo_title: "Achievements: how gold, silver and bronze medals are awarded"
description: "Medals on the leaderboard: top three of a family composite, of a language and of a single test profile, always inside the entry's own league."
weight: 10
---

An achievement is a medal for a top three place: **gold** for first, **silver** for second, **bronze** for third. Medals are shown next to the name on the composite board, in the panel that opens when you click a row, and in full on every framework page.

Nothing is scored again to award them. A medal is a place in a field the site already publishes, so a medal, a rank badge and the table you are looking at always say the same thing.

## The three awards

| Award | Field |
|---|---|
| Family composite | The [composite score](composite-score) of one family: HTTP/1.1, HTTP/2, HTTP/3, Gateway, gRPC, WebSocket |
| Within its language | The same composite, counting only entries written in the same language |
| Test profile | One profile, on the average RPS over its scored connection counts |

## The field a medal is taken in

Every field is the entry's own league. Frameworks, engines and reverse proxies are three separate competitions, and a framework never places against an engine.

A profile only awards a medal to an entry that is scored on it. Reference-only profiles, Pipelined and Fortunes, award nothing to frameworks, and an engine holds no medal on a profile outside the engine set.

Tuned entries follow the badge rule: a standard entry is placed in the field without tuned entries, a tuned entry in the field with them. It is always the smallest published field the entry belongs to.

## When a place is not a medal

A field needs at least three entries, and somebody has to be beaten. So gold and silver need a field of three, bronze needs four, and last place is never a medal. The field size is written next to every medal, `1 of 71`, so you can always see what was won.

Medals are not filtered by what you are looking at. Changing the league filter or the language filter changes who is listed, never who holds a medal.
