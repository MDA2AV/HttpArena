---
title: Completeness
seo_title: "Completeness Factor"
description: "The completeness factor: routing, middleware, request and response. Each one a framework leaves to you costs 2.5% of its composite score."
weight: 3
---

Throughput is only half of what a framework is worth. A server that hands you nothing but a request callback will usually beat one that routes, hands you a parsed body and builds the response for you - and it should, because it is doing less. Ranking on speed alone quietly rewards giving the developer less.

The **completeness factor** is the counterweight. It asks four yes/no questions about the path from an arriving request to a finished response, and each one an entry answers *no* takes **2.5% off its composite score**:

```
  all four done     →  ×1.000
  one missing       →  ×0.975
  two missing       →  ×0.950
  three missing     →  ×0.925
  all four missing  →  ×0.900
```

There is no bonus half. Doing the work a framework exists to do is the baseline, not a credit - the factor is there so a bare request callback cannot out-rank a real framework on throughput it only has because it does less. The best any entry can do is lose nothing.

## The four

| Axis | Counts as done when |
|---|---|
| **Routing** | The framework matches method and path for you, with path parameters - you register handlers, you do not branch on `req.url` yourself. |
| **Middleware** | There is a composable pipeline around the handler: ordered, able to run before and after it, scoped to the app or to a route, able to short-circuit with a response. |
| **Request** | The request arrives already made - path parameters, query parameters and headers read straight off it, and a body you can take **buffered or as a stream**, parsed as JSON or a form, without assembling it from raw chunks. |
| **Response** | The response is declared rather than assembled - status, headers and body together in one call, JSON serialized for you, a file or a stream usable as a body. |

Each axis is all-or-nothing. A server that gives you path parameters and a query string but makes you collect the body out of `onData` callbacks has not done the **Request** axis: the handler still cannot ask for what it needs and get it.

**Nothing outside that path is graded:** not templating, ORM or database integration, DI containers, background jobs, CLI tooling, ecosystem size, popularity or documentation. Those matter when you choose a framework, but they are not the surface this benchmark exercises, and a server that ships none of them can still hand you a first-class request.

## Declaring it

Framework entries declare the axes they *do not* do in `meta.json`. An axis you leave out reads as done, so a single `false` is the whole declaration for an entry that only lacks one:

```json
"completeness": {
  "middleware": false
}
```

An entry that omits the field entirely is unassessed and scores ×1.00 - unassessed is not the same as missing everything. Propose the values in your PR with a sentence of justification; they may be adjusted on review, and they mean the same thing in every language.

Two rules decide the values:

- **Grade what the entry uses, not what the framework ships.** A benchmark implementation that bypasses its framework's router to hand-roll a faster path has no routing. This is the same principle as [Standard mode](/docs/add-framework/implementation-rules/frameworks/standard/) - it just becomes a declaration instead of a review argument.
- **Grade the surface you write against.** A server that embeds a fast C++ core but exposes only `onData`/`onAborted` for bodies is graded on the callbacks, not the core.
- **Middleware is the one axis read off the surface rather than the run.** A benchmark has no cross-cutting concern to install, so no entry would ever score it if it were read off the handler. It counts as done when the server the entry is written against gives the author a pipeline to put one in - not when this particular handler happens to use it. The other three axes are exercised by every entry on every request, so they are graded on the code.

**Only framework tiers are graded.** Engine and infrastructure entries implement none of the four - a raw-socket server has no router, a reverse proxy has no handler to run middleware around - and that is exactly why grading them is pointless rather than generous. Every one of them would take the same ×0.90, so nothing about their order would change, and they are never ranked against frameworks in the first place: each league is normalized against itself. Their factor is fixed at ×1.00 and their rows say nothing about completeness.

## Not on the WebSocket and gRPC boards

The four axes are the path from an arriving HTTP request to a finished response. Two families are not measuring that path, so the factor does not apply on them at all:

- **WebSocket.** There is no route to match, no body to hand over and no response to build. The handshake happened once; everything the profile measures after it is frames on an open socket.
- **gRPC.** A call has all four - it is dispatched, the request arrives deserialized, the response is serialized back - but the stub generated from the `.proto` does them, not the framework. Grading the framework for them would be crediting protoc.

On those two boards every entry scores ×1.00, including the ones that also serve HTTP and carry a real factor on the HTTP/1.1, HTTP/2, HTTP/3 and Gateway boards. It is the board that is exempt, not the entry.

An entry that runs **only** WebSocket or gRPC profiles does not declare the field at all - there is no board on which it would ever be applied, and a grade nothing reads is a claim about an HTTP path the entry does not have.

## Why a multiplier on the total

Completeness is a property of the entry, not of a workload. It does not change per profile the way throughput or memory does, so it is applied once, to the finished sum, rather than folded into each profile's 0-100 score. It lands after the memory-efficiency bonus, on whatever total the current toggles produce.

It is also the only part of the composite that is not read off a benchmark, so the board never hides it. A graded entry shows its adjusted score with the points it cost beside it:

```
416 (-22)     scored 438 on throughput, no routing and no middleware took 22 off
```

Only rows that lost something carry a figure. An entry that does all four shows its score alone, and so does one that has not been assessed - most of the field loses nothing, so a `(0)` on all of them would bury the rows that did.

Hovering gives the full arithmetic either way: the raw sum, the multiplier, which axes were deducted, or that the entry has not been assessed yet. That is where the difference between a checked clean sheet and an unassessed entry is carried.

## What it does not do

The factor scales a score; it does not gate a tier. An entry that does none of the four is still a framework entry if it implements HTTP itself, and still ranks in the framework pool - it just needs a raw composite about 11% higher than a complete framework to finish level with it (×1.00 ÷ ×0.90).
