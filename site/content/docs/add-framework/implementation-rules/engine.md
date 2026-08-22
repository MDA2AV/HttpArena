---
title: Engine
seo_title: "Engine Entry Rules"
description: "Rules for engine entries: HTTP implementations applications are not written against - raw sockets, low-level I/O and protocol hosts - ranked separately from frameworks."
weight: 2
---

Engine entries (`type: engine`) are HTTP implementations that applications are not written against - raw sockets, custom parsers, low-level I/O, built to show what a transport or a technique can do rather than to host application code. They are not frameworks and are ranked separately. (Reverse proxies and static-file servers like nginx and h2o are classified as [Infrastructure](../infrastructure/), not Engine.)

## What qualifies as an engine

- Raw TCP socket servers with custom HTTP parsing
- Direct io_uring or epoll implementations
- Application-server hosts, where your code is written against a protocol interface rather than the server's own API - a WSGI or ASGI server, a Rack handler

## What does not

A server whose own API is the surface applications are written and deployed on is a **framework** entry, however thin it is. A runtime's built-in HTTP server - `node:http`, `Deno.serve`, `Bun.serve`, Go's `net/http` - is a framework entry, and so is a low-level server library that people ship services on directly.

Having no router, no middleware stack and no ecosystem does not make something an engine - see [Frameworks](../frameworks/).

## Rules

- Must implement the endpoint spec correctly
- Must pass the validation suite
- No restrictions on implementation approach, with one exception: on the static profiles, file contents may be served from memory only through the engine's own static file handling, not a cache assembled in the entry, and that cache must follow the disk - replacing a file must change the next response
- Ranked separately from framework entries (flagship and emerging)
- Only participates in connection-level tests (baseline, pipelined, limited-conn) and protocol tests (H2, H3, gRPC, WebSocket) by default
