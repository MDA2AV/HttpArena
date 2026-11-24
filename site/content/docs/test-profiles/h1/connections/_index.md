---
title: Connections
seo_title: "Held Connections: CON-1M, CON-1M-TLS and CON-5M"
description: "Holds a million keep-alive connections, a million TLS 1.3 sessions or five million connections open at once, with requests paced across them, and scores what carrying them costs the server: CPU per request, memory, p50 and p99 latency."
---

Three profiles hold a fleet of keep-alive connections open at once, every connection sending one request every four seconds. The other profiles keep at most 32,000 connections busy; these keep a million, or five million, mostly idle, the way a chat, push or IoT gateway does. What separates entries is what the waiting costs: the memory each connection keeps, the CPU a request carries while the rest of the fleet sits in the poll set, and how long a request takes when it comes.

| Profile | On the board | Fleet | Rate | Load generator | Scored |
|---|---|---|---|---|---|
| `connections-1m` | CON-1M | 1,000,000 | 250,000 req/s | zrk 3.0.2, one process per address | Yes |
| `connections-1m-tls` | CON-1M-TLS | 1,000,000 over TLS 1.3 | 250,000 req/s | gcannon | Yes |
| `connections-5m` | CON-5M | 5,000,000 | 1,250,000 req/s | gcannon | No - and by allowlist only |

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="What the listener must allow, how the load is run, what is measured, and how it is scored." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for these test profiles." icon="check-circle" >}}
{{< /cards >}}
