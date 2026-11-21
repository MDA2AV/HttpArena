---
weight: 1
title: H/1.1
seo_title: "HTTP/1.1 Test Profiles"
description: "Single-endpoint HTTP/1.1 benchmarks, each isolating one dimension: throughput, JSON, TLS echo, static files, concurrency, CPU cost and database access."
---

Every HTTP/1.1 profile measures one thing at a time, so a number can be attributed to a single part of the framework rather than to a mix.

{{< cards >}}
  {{< card link="baseline" title="Baseline" subtitle="Primary throughput benchmark with persistent keep-alive connections and mixed GET/POST workload." icon="lightning-bolt" >}}
  {{< card link="short-lived" title="Short-lived Connection" subtitle="Connections closed after 10 requests, measuring TCP handshake and connection setup overhead." icon="refresh" >}}
  {{< card link="json-compressed" title="JSON Compressed" subtitle="The /json workload with Accept-Encoding: gzip, br and a multiplier parameter - measures serialization plus compression throughput." icon="document-text" >}}
  {{< card link="json-tls" title="JSON over TLS" subtitle="The /json workload over HTTP/1.1 + TLS on port 8081 - measures the cost of encryption on top of serialization." icon="lock-closed" >}}
  {{< card link="8gbit" title="8Gbit (10 KB echo)" subtitle="Posts 10 KB over TLS at a fixed rate and requires it back verbatim - the only profile that loads ingest and egress at once." icon="cloud-upload" >}}
  {{< card link="async" title="Async Delay" subtitle="A 10ms wait named in the route, at 32K held connections - measures what the framework does while a request waits." icon="clock" >}}
  {{< card link="latency-10k" title="Latency-10K" subtitle="Latency-1M's setup at a near-idle 10K req/s; the metric is the CPU and latency of a server with almost nothing to do." icon="chip" >}}
  {{< card link="latency-1m" title="Latency-1M" subtitle="One million req/s offered at a fixed rate; the metric is the CPU each framework spends to serve it, read exactly from its cgroup." icon="chip" >}}
  {{< card link="connections" title="Connections (CON-1M, CON-1M-TLS, CON-5M)" subtitle="A million keep-alive connections held at once, a million over TLS 1.3, or five million (by allowlist), with requests paced across them - scored on CPU per request, memory, p50 and p99." icon="globe" >}}
  {{< card link="async-database" title="Async Database (Postgres)" subtitle="Async Postgres range query over 100K rows, connection pooling, and JSON serialization. Ranked on the Database board, with its own CPU split." icon="database" >}}
  {{< card link="static-tls" title="Static Files over TLS" subtitle="20 static files served over HTTP/1.1 + TLS on port 8081. Reference-only for frameworks and engines, scored for infrastructure." icon="lock-closed" >}}
  {{< card link="pipelined" title="Pipelined (16x) *" subtitle="16 requests sent back-to-back per connection, testing raw I/O and pipeline batching. Reference-only - not part of the composite score." icon="fast-forward" >}}
  {{< card link="fortunes" title="Fortunes (Templates)" subtitle="DB query + HTML template rendering with auto-escape. Ranked on the Database board, with its own CPU split." icon="document-text" >}}
  {{< card link="tls" title="TLS Hardening (opt-in)" subtitle="Not a benchmark: certificate rotation, SNI, resumption and a vulnerability scan on a dedicated TLS listener. Passing earns the gold TLS badge." icon="shield-check" >}}
{{< /cards >}}
