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
  {{< card link="json-compressed" title="JSON Compressed" subtitle="Same JSON workload with Accept-Encoding: gzip, br and a multiplier parameter - measures serialization plus compression throughput." icon="document-text" >}}
  {{< card link="json-tls" title="JSON over TLS" subtitle="Same JSON workload transported over HTTP/1.1 + TLS on port 8081 - measures the cost of encryption on top of serialization." icon="lock-closed" >}}
  {{< card link="8gbit" title="8Gbit (10 KB echo)" subtitle="Posts 10 KB over TLS at a fixed rate and requires it back verbatim - the only profile that loads ingest and egress at once." icon="cloud-upload" >}}
  {{< card link="async" title="Async Delay" subtitle="A 15ms wait named in the route, at 64K held connections - measures what the framework does while a request waits." icon="clock" >}}
  {{< card link="latency-10k" title="Latency-10K" subtitle="Latency-1M's setup at a near-idle 10K req/s; the metric is the CPU and latency of a server with almost nothing to do." icon="chip" >}}
  {{< card link="latency-1m" title="Latency-1M" subtitle="One million req/s offered at a fixed rate; the metric is the CPU each framework spends to serve it, read exactly from its cgroup." icon="chip" >}}
  {{< card link="async-database" title="Async Database (Postgres)" subtitle="Async Postgres range query over 100K rows, connection pooling, and JSON serialization. Framework-only benchmark." icon="database" >}}
  {{< card link="static-tls" title="Static Files over TLS" subtitle="Same 20-file static workload transported over HTTP/1.1 + TLS on port 8081 - measures the cost of encryption on bulk file serving." icon="lock-closed" >}}
  {{< card link="pipelined" title="Pipelined (16x) *" subtitle="16 requests sent back-to-back per connection, testing raw I/O and pipeline batching. Reference-only - not part of the composite score." icon="fast-forward" >}}
  {{< card link="fortunes" title="Fortunes (Templates) *" subtitle="DB query + HTML template rendering with auto-escape. Reference-only - measures template-engine throughput, not part of the composite score." icon="document-text" >}}
{{< /cards >}}
