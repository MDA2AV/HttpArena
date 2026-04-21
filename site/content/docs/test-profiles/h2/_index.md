---
weight: 2
title: H/2
---

H/2 test profiles measure framework performance under multiplexed streams. The TLS variants model edge-facing deployments; the cleartext (h2c) variants model reverse-proxy-to-origin and service-to-service deployments inside a trust boundary.

{{< cards >}}
  {{< card link="baseline-h2" title="Baseline (TLS)" subtitle="Same workload as baseline over encrypted HTTP/2 connections with TLS and stream multiplexing." icon="globe-alt" >}}
  {{< card link="static-h2" title="Static Files (TLS)" subtitle="Serves 20 static files of various types over HTTP/2 with multiplexed streams, simulating a browser page load." icon="photograph" >}}
  {{< card link="baseline-h2c" title="Baseline (h2c)" subtitle="Same /baseline2 endpoint over HTTP/2 cleartext on port 8082 — no TLS, prior-knowledge framing. Anti-cheat verifies the port refuses HTTP/1.1." icon="globe-alt" >}}
  {{< card link="json-h2c" title="JSON (h2c)" subtitle="JSON serialization workload over HTTP/2 cleartext on port 8082. Same 7 (count, m) rotation as the H/1 json profile." icon="code" >}}
{{< /cards >}}
