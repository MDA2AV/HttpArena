---
weight: 1
title: Isolated
---

Single-endpoint benchmarks that measure framework performance on one task at a time.

{{< cards >}}
  {{< card link="baseline" title="Baseline" subtitle="Primary throughput benchmark with persistent keep-alive connections and mixed GET/POST workload." icon="lightning-bolt" >}}
  {{< card link="short-lived" title="Short-lived Connection" subtitle="Connections closed after 10 requests, measuring TCP handshake and connection setup overhead." icon="refresh" >}}
  {{< card link="json-processing" title="JSON Processing" subtitle="Loads a dataset, computes derived fields, and serializes a JSON response — testing real-world API workloads." icon="document-text" >}}
  {{< card link="json-compressed" title="JSON Compressed" subtitle="Same JSON workload with Accept-Encoding: gzip, br and a multiplier parameter — measures serialization plus compression throughput." icon="document-text" >}}
  {{< card link="json-tls" title="JSON over TLS" subtitle="Same JSON workload transported over HTTP/1.1 + TLS on port 8081 — measures the cost of encryption on top of serialization." icon="lock-closed" >}}
  {{< card link="upload" title="Upload (20 MB)" subtitle="Sends a 20 MB binary payload, server returns byte count. Measures body ingestion throughput." icon="cloud-upload" >}}
  {{< card link="async-database" title="Async Database (Postgres)" subtitle="Async Postgres range query over 100K rows, connection pooling, and JSON serialization. Framework-only benchmark." icon="database" >}}
  {{< card link="static" title="Static Files" subtitle="Serves 20 static files — CSS, JS, HTML, fonts, images — over HTTP/1.1." icon="photograph" >}}
  {{< card link="pipelined" title="Pipelined (16x)" subtitle="16 requests sent back-to-back per connection, testing raw I/O and pipeline batching." icon="fast-forward" >}}
  {{< card link="crud" title="CRUD (REST API)" subtitle="Realistic REST API with paginated list, cached reads, create, and update against Postgres." icon="database" >}}
  {{< card link="fortunes" title="Fortunes (Templates) *" subtitle="DB query + HTML template rendering with auto-escape. Reference-only — measures template-engine throughput, not part of the composite score." icon="document-text" >}}
{{< /cards >}}
