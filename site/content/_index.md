---
title: HttpArena
layout: hextra-home
---

{{< hextra/hero-badge link="https://github.com/MDA2AV/HttpArena" >}}
  <span>Open Source</span>
  {{< icon name="arrow-circle-right" attributes="height=14" >}}
{{< /hextra/hero-badge >}}

<div class="hx-mt-6 hx-mb-6">
{{< hextra/hero-headline >}}
  HTTP Framework&nbsp;Benchmark Arena
{{< /hextra/hero-headline >}}
</div>

<div class="hx-mb-12">
{{< hextra/hero-subtitle >}}
  An open benchmarking platform that measures HTTP, gRPC, and WebSocket framework performance under realistic workloads using io_uring-based load generation. Add your framework, get results automatically.
{{< /hextra/hero-subtitle >}}
</div>

<div style="height:20px"></div>

<style>
.hextra-cards > a:first-child { background: rgba(22,163,74,0.08) !important; border-color: rgba(22,163,74,0.25) !important; }
.hextra-cards > a:first-child:hover { border-color: rgba(22,163,74,0.5) !important; background: rgba(22,163,74,0.12) !important; }
html.dark .hextra-cards > a:first-child { background: rgba(22,163,74,0.12) !important; border-color: rgba(22,163,74,0.3) !important; }
html.dark .hextra-cards > a:first-child:hover { background: rgba(22,163,74,0.18) !important; border-color: rgba(22,163,74,0.5) !important; }
</style>

{{< cards >}}
  {{< card link="leaderboard" title="Leaderboard" subtitle="See which frameworks handle the most requests per second, ranked by throughput." icon="chart-bar" >}}
  {{< card link="docs/running-locally" title="Run Locally" subtitle="Set up and run the full benchmark suite on your own machine with Docker and gcannon." icon="terminal" >}}
  {{< card link="docs/add-framework" title="Add a Framework" subtitle="Add your framework with a Dockerfile and open a PR. Three steps to join the arena." icon="plus-circle" >}}
{{< /cards >}}

<div style="height:3rem"></div>

<style>
.tests-section { width: 100%; }
.tests-section h2 { text-align: left; font-size: 1.6rem; font-weight: 700; margin-bottom: 0.25rem; }
.tests-section .tests-sub { text-align: left; color: #64748b; font-size: 0.95rem; margin-bottom: 2rem; }
html.dark .tests-section .tests-sub { color: #94a3b8; }
.tests-proto { margin-bottom: 2rem; }
.tests-proto-label { font-size: 0.75rem; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; padding: 0.25rem 0.6rem; border-radius: 4px; display: inline-block; margin-bottom: 0.75rem; }
.tests-proto-h1 { background: rgba(59,130,246,0.1); color: #3b82f6; }
.tests-proto-h2 { background: rgba(234,179,8,0.1); color: #ca8a04; }
.tests-proto-h3 { background: rgba(34,197,94,0.1); color: #16a34a; }
html.dark .tests-proto-h1 { background: rgba(59,130,246,0.15); color: #60a5fa; }
html.dark .tests-proto-h2 { background: rgba(234,179,8,0.15); color: #fbbf24; }
html.dark .tests-proto-h3 { background: rgba(34,197,94,0.15); color: #4ade80; }
.tests-proto-grpc { background: rgba(124,58,237,0.1); color: #7c3aed; }
.tests-proto-ws { background: rgba(8,145,178,0.1); color: #0891b2; }
html.dark .tests-proto-grpc { background: rgba(124,58,237,0.15); color: #a78bfa; }
html.dark .tests-proto-ws { background: rgba(8,145,178,0.15); color: #22d3ee; }
.tests-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(15rem, 1fr)); gap: 0.75rem; }
.test-card { border: 1px solid #e2e8f0; border-radius: 8px; padding: 1rem 1.1rem; transition: all 0.15s ease; text-decoration: none !important; display: block; }
.test-card:hover { border-color: #94a3b8; box-shadow: 0 2px 8px rgba(0,0,0,0.06); transform: translateY(-1px); }
html.dark .test-card { border-color: #334155; }
html.dark .test-card:hover { border-color: #475569; box-shadow: 0 2px 8px rgba(0,0,0,0.3); }
.test-card-title { font-weight: 600; font-size: 0.9rem; color: #0f172a; margin-bottom: 0.3rem; }
html.dark .test-card-title { color: #f1f5f9; }
.test-card-desc { font-size: 0.78rem; color: #64748b; line-height: 1.4; }
html.dark .test-card-desc { color: #94a3b8; }
.test-card-endpoint { font-family: monospace; font-size: 0.7rem; color: #94a3b8; margin-top: 0.4rem; }
html.dark .test-card-endpoint { color: #64748b; }
</style>

<div class="tests-section">
<h2>22 Test Profiles Across H/1.1, H/2, H/3, gRPC and WebSocket</h2>
<p class="tests-sub">Every framework is tested under diverse, realistic workloads — from raw throughput to JSON processing, gRPC unary calls, and WebSocket echo.</p>

<div class="tests-proto">
<span class="tests-proto-label tests-proto-h1">H/1.1 Isolated</span>
<div class="tests-grid">
  <a class="test-card" href="docs/test-profiles/h1/isolated/baseline">
    <div class="test-card-title">Baseline</div>
    <div class="test-card-desc">Mixed GET/POST with keep-alive connections, query parsing, and chunked encoding.</div>
    <div class="test-card-endpoint">GET/POST /baseline11</div>
  </a>
  <a class="test-card" href="docs/test-profiles/h1/isolated/short-lived">
    <div class="test-card-title">Short-lived Connection</div>
    <div class="test-card-desc">Connections closed after 10 requests — measures TCP handshake overhead.</div>
    <div class="test-card-endpoint">GET/POST /baseline11 (10 req/conn)</div>
  </a>
  <a class="test-card" href="docs/test-profiles/h1/isolated/json-processing">
    <div class="test-card-title">JSON Processing</div>
    <div class="test-card-desc">Load dataset, compute derived fields, serialize ~10 KB JSON response.</div>
    <div class="test-card-endpoint">GET /json/{count}</div>
  </a>
  <a class="test-card" href="docs/test-profiles/h1/isolated/json-compressed">
    <div class="test-card-title">JSON Compressed</div>
    <div class="test-card-desc">Same JSON workload with <code>Accept-Encoding: gzip, br</code> — measures serialization + compression.</div>
    <div class="test-card-endpoint">GET /json/{count}?m=N</div>
  </a>
  <a class="test-card" href="docs/test-profiles/h1/isolated/upload">
    <div class="test-card-title">Upload (20 MB)</div>
    <div class="test-card-desc">Ingest a 20 MB binary payload and return its byte count.</div>
    <div class="test-card-endpoint">POST /upload</div>
  </a>
  <a class="test-card" href="docs/test-profiles/h1/isolated/async-database">
    <div class="test-card-title">Async Database (Postgres)</div>
    <div class="test-card-desc">Async Postgres query over 100K rows — tests event loop scheduling, connection pooling, and async driver efficiency.</div>
    <div class="test-card-endpoint">GET /async-db?limit=N</div>
  </a>
  <a class="test-card" href="docs/test-profiles/h1/isolated/static">
    <div class="test-card-title">Static Files</div>
    <div class="test-card-desc">Round-robin across 20 static files — CSS, JS, HTML, fonts, images.</div>
    <div class="test-card-endpoint">GET /static/*</div>
  </a>
  <a class="test-card" href="docs/test-profiles/h1/isolated/pipelined">
    <div class="test-card-title">Pipelined (16x)</div>
    <div class="test-card-desc">16 requests sent back-to-back per connection. Tests pipeline batching.</div>
    <div class="test-card-endpoint">GET /pipeline</div>
  </a>
</div>
</div>

<div class="tests-proto">
<span class="tests-proto-label tests-proto-h1">H/1.1 Workload</span>
<div class="tests-grid">
  <a class="test-card" href="docs/test-profiles/h1/workload/api-4">
    <div class="test-card-title">API-4</div>
    <div class="test-card-desc">Lighter workload (baseline, JSON, async-db) constrained to 4 CPUs and 16 GB memory — measures efficiency under limited resources.</div>
    <div class="test-card-endpoint">GET/POST mixed endpoints (4 CPU, 16 GB)</div>
  </a>
  <a class="test-card" href="docs/test-profiles/h1/workload/api-16">
    <div class="test-card-title">API-16</div>
    <div class="test-card-desc">Same API workload (baseline, JSON, async-db) with 16 CPUs and 32 GB memory — tests performance scaling.</div>
    <div class="test-card-endpoint">GET/POST API endpoints (16 CPU, 32 GB)</div>
  </a>
</div>
</div>

<div class="tests-proto">
<span class="tests-proto-label tests-proto-h2">H/2</span>
<div class="tests-grid">
  <a class="test-card" href="docs/test-profiles/h2/baseline-h2">
    <div class="test-card-title">Baseline</div>
    <div class="test-card-desc">Multiplexed HTTP/2 streams over TLS with 100 concurrent streams per connection.</div>
    <div class="test-card-endpoint">GET /baseline2 (h2)</div>
  </a>
  <a class="test-card" href="docs/test-profiles/h2/static-h2">
    <div class="test-card-title">Static Files</div>
    <div class="test-card-desc">Round-robin across 20 static files — CSS, JS, HTML, fonts, images.</div>
    <div class="test-card-endpoint">GET /static/* (h2)</div>
  </a>
</div>
</div>

<div class="tests-proto">
<span class="tests-proto-label tests-proto-h2">H/2 Gateway</span>
<div class="tests-grid">
  <a class="test-card" href="docs/test-profiles/h2-gateway/gateway-64">
    <div class="test-card-title">Gateway-64</div>
    <div class="test-card-desc">Reverse proxy + application server — mixed static, JSON, and async-db workload over HTTP/2 with TLS. 64 CPUs split between proxy and server.</div>
    <div class="test-card-endpoint">proxy:8443 → server (h2)</div>
  </a>
</div>
</div>

<div class="tests-proto">
<span class="tests-proto-label tests-proto-h3">H/3</span>
<div class="tests-grid">
  <a class="test-card" href="docs/test-profiles/h3/baseline-h3">
    <div class="test-card-title">Baseline</div>
    <div class="test-card-desc">HTTP/3 over QUIC — measures framework performance with UDP-based transport.</div>
    <div class="test-card-endpoint">GET /baseline2 (h3)</div>
  </a>
  <a class="test-card" href="docs/test-profiles/h3/static-h3">
    <div class="test-card-title">Static Files</div>
    <div class="test-card-desc">Multi-URI static file serving over QUIC with parallel streams.</div>
    <div class="test-card-endpoint">GET /static/* (h3)</div>
  </a>
</div>
</div>

<div class="tests-proto">
<span class="tests-proto-label tests-proto-grpc">gRPC</span>
<div class="tests-grid">
  <a class="test-card" href="docs/test-profiles/grpc/unary">
    <div class="test-card-title">Unary (h2c)</div>
    <div class="test-card-desc">Unary gRPC call over cleartext HTTP/2 — raw Protocol Buffers throughput without TLS overhead.</div>
    <div class="test-card-endpoint">BenchmarkService/GetSum (h2c)</div>
  </a>
  <a class="test-card" href="docs/test-profiles/grpc/unary">
    <div class="test-card-title">Unary (TLS)</div>
    <div class="test-card-desc">Same unary gRPC call over encrypted HTTP/2 with TLS 1.3.</div>
    <div class="test-card-endpoint">BenchmarkService/GetSum (TLS)</div>
  </a>
</div>
</div>

<div class="tests-proto">
<span class="tests-proto-label tests-proto-ws">WebSocket</span>
<div class="tests-grid">
  <a class="test-card" href="docs/test-profiles/ws/echo">
    <div class="test-card-title">Echo</div>
    <div class="test-card-desc">WebSocket echo throughput — upgrade, send pipelined text messages, receive echoes. Measures frame processing performance.</div>
    <div class="test-card-endpoint">WS /ws (echo)</div>
  </a>
</div>
</div>

</div>

