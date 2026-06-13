---
title: Infrastructure
weight: 3
---

Infrastructure entries (`type: infrastructure`) are reverse proxies and static-file servers - nginx, h2o, Caddy and the like - run without an application framework layer. Like engines, they are not frameworks and are ranked separately.

## What qualifies

- Reverse proxies terminating TLS and forwarding upstream (nginx, Caddy, h2o)
- Standalone static-file servers
- Edge servers used purely as a proxy in front of an application

## Rules

- Must implement the endpoint spec correctly and pass the validation suite
- No restrictions on configuration
- Ranked separately from framework entries (flagship and emerging)
- Participates in the static-file and protocol tests where applicable
