---
title: Infrastructure
seo_title: "Infrastructure Entry Rules"
description: "Rules for infrastructure entries: reverse proxies and static-file servers such as nginx, Caddy and h2o, run without an application framework layer and ranked separately."
weight: 3
---

Infrastructure entries (`type: infrastructure`) are reverse proxies and static-file servers - nginx, Caddy, h2o and the like - run without an application framework layer. Like engines, they are not frameworks and are ranked separately.

## What qualifies

- Reverse proxies terminating TLS and forwarding upstream (nginx, Caddy, h2o)
- Standalone static-file servers
- Edge servers used purely as a proxy in front of an application

Something that embeds one of these servers but ships application code on top of it is a framework entry, not an infrastructure one - `openresty`, `ngx-php` and `frankenphp` are ranked with the frameworks.

## Rules

- Must implement the endpoint spec correctly and pass the validation suite
- No restrictions on configuration
- Ranked separately from framework entries: its own composite, its own normalization pool
- A handler module written specifically for the benchmark is allowed - that is how a server without an application layer answers `/baseline11` and `/json/{count}` at all - but it must be a module loaded by the server, not a replacement for it

## Scored profiles

Infrastructure is scored on the nine profiles a server can answer without an application framework behind it:

| Category | Profiles |
|---|---|
| Connection | Baseline, Pipelined, Short-lived |
| Workload | JSON TLS, Static TLS |
| HTTP/2 | Baseline, Static |
| HTTP/3 | Baseline, Static |

Everything else - async, the latency profiles, 8gbit, the database profiles, h2c, gRPC, WebSocket and the gateway stacks - is displayed as reference data where an entry has it, but does not count toward the infrastructure composite.

Pipelined and Static TLS are scored here and nowhere else. Pipelined stopped counting for frameworks in [#1058](https://github.com/MDA2AV/HttpArena/pull/1058) because it measures batching behaviour more than framework throughput; for a proxy that behaviour *is* the thing being compared, so it stays in. Static TLS is reference-only for frameworks and engines, but serving files is exactly what a static-file server is for.
