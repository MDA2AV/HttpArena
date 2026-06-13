---
title: Engine
weight: 2
---

Engine entries (`type: engine`) are bare-metal HTTP implementations - raw sockets, custom parsers, low-level I/O. They are not frameworks and are ranked separately. (Reverse proxies and static-file servers like nginx and h2o are classified as [Infrastructure](../infrastructure/), not Engine.)

## What qualifies as an engine

- Raw TCP socket servers with custom HTTP parsing
- Minimal HTTP libraries without routing or middleware
- Direct io_uring or epoll implementations

## Rules

- Must implement the endpoint spec correctly
- Must pass the validation suite
- No restrictions on implementation approach
- Ranked separately from framework entries (flagship and emerging)
- Only participates in connection-level tests (baseline, pipelined, limited-conn) and protocol tests (H2, H3, gRPC, WebSocket) by default
