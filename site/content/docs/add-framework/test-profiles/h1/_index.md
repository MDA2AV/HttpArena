---
title: HTTP/1.1
---

HTTP/1.1 test profiles measure framework performance over plain TCP connections with keep-alive, pipelining, and various workloads.

{{< cards >}}
  {{< card link="baseline" title="Baseline" subtitle="Primary throughput benchmark with persistent keep-alive connections and mixed GET/POST workload." icon="lightning-bolt" >}}
  {{< card link="short-lived" title="Short-lived Connection" subtitle="Connections closed after 10 requests, measuring TCP handshake and connection setup overhead." icon="refresh" >}}
  {{< card link="json-processing" title="JSON Processing" subtitle="Loads a dataset, computes derived fields, and serializes a JSON response — testing real-world API workloads." icon="document-text" >}}
  {{< card link="upload" title="Upload (20 MB)" subtitle="Sends a 20 MB binary payload, server returns byte count. Measures body ingestion throughput." icon="cloud-upload" >}}
  {{< card link="compression" title="Compression" subtitle="Serves a 1 MB JSON response with gzip compression. Only frameworks with built-in gzip support." icon="archive" >}}
  {{< card link="noisy" title="Noisy (Resilience)" subtitle="Valid baseline requests interleaved with malformed noise. Only 2xx responses count — measures throughput under adversarial traffic." icon="exclamation" >}}
  {{< card link="database" title="Database Query" subtitle="SQLite range query over 100K rows, result parsing, and JSON serialization. Used within the mixed workload profile." icon="database" >}}
  {{< card link="mixed" title="Mixed Workload" subtitle="Realistic mix of baseline, JSON, DB, upload, and compression. Weighted scoring rewards heavy endpoint throughput." icon="collection" >}}
  {{< card link="pipelined" title="Pipelined (16x)" subtitle="16 requests sent back-to-back per connection, testing raw I/O and pipeline batching." icon="fast-forward" >}}
{{< /cards >}}
