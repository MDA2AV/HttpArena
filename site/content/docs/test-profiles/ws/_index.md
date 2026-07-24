---
weight: 5
title: WebSocket
---

WebSocket test profiles measure framework performance for real-time bidirectional communication. The server listens on **port 8080** and accepts WebSocket upgrade requests.

{{< cards >}}
  {{< card link="echo" title="Echo" subtitle="WebSocket echo throughput - upgrade, send messages, receive echoes." icon="globe-alt" >}}
  {{< card link="echo-pipeline" title="Echo Pipelined (16x)" subtitle="WebSocket echo with 16 messages in flight per connection - measures frame batching and read-buffer draining." icon="fast-forward" >}}
  {{< card link="echo-limited" title="Echo Short-lived" subtitle="WebSocket echo with each connection closed after 10 messages - measures the cost of the upgrade handshake." icon="refresh" >}}
{{< /cards >}}
