---
title: Implementation Guidelines
seo_title: "Rendezvous Benchmark: Implementation Guide"
description: "Endpoint contract, pairing rules, and the constraints a framework must satisfy for the rendezvous benchmark."
---
{{< type-rules standard="Must park the request with the framework's own async primitives and answer through its normal response path. The pairing lives in the server's own processes, with no broker or database." tuned="May use sharded maps, lock-free structures, custom wakeups or direct socket writes, as long as the contract holds. The pairing still lives in the server's own processes." engine="The pairing lives in the server's own processes, with no broker or database." >}}


The Rendezvous profile measures what it costs a server to get something from one connection to another. A request cannot be answered until another connection's request for the same key arrives, so no response can be produced from one request alone.

This is scored on the Interaction board only, and counts toward no other composite.

**Connections:** 4,096

## How it works

```
GET /rendezvous/{key}?v={value} HTTP/1.1
```

1. The first request for a key waits, and is not answered yet.
2. The second request for that key completes both: each is answered `200` with the other's `value` as the body.
3. The key is free again, and a later pair may use it.

| Part | Contract |
|---|---|
| `key` | Opaque, `[A-Za-z0-9-]`, up to 64 characters |
| `v` | Opaque, `[A-Za-z0-9]`, 1 to 32 characters. Returned verbatim, so don't parse it as a number |
| Response | `200`, `Content-Type: text/plain`, body is the other request's `v` |

A key never has more than two requests on it at once. A request waits until its partner arrives or its client leaves, with no deadline of its own.

## What it measures

- **The crossing.** With one worker per core, the two sides usually sit on different workers, so every exchange has to hand something between them: a queue, a wakeup, a lock, a copy or a message to another process.
- **Shared state under contention.** All 4,096 connections go through whatever holds the waiting requests.
- **Parked requests.** Up to half of the connections can be waiting on a partner at once, so what a waiting request costs counts too.

## Why a server can't arrange its own pairs

The generator is `wrk` with `requests/rendezvous.lua`. Each thread gives every two consecutive requests the same key, and a connection only holds one request at a time, so the two go out on whichever connections are free. A server can't move a pair onto the same worker, because it only learns which two connections are paired once they have both sent. Keys are never reused between runs.

## Multi-process servers

The two sides of a key usually land on different processes when a server forks one per core, so the pairing has to work across them. IPC or shared memory are fine. An external service is not: Redis or a database in the path would measure that service instead.

## Blocking servers

A server with a fixed pool of blocking workers deadlocks here if the pool is smaller than the number of waiting requests: every worker holds a request waiting for a partner, and no worker is free to read the partner. Such a server can leave this profile out of `meta.json.tests`.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /rendezvous/{key}?v={value}` |
| Connections | 4,096 |
| Pipeline | 1 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | wrk + `requests/rendezvous.lua` |
