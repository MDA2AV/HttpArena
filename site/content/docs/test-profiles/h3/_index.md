---
weight: 3
title: H/3
seo_title: "HTTP/3 Test Profiles"
description: "HTTP/3 profiles measuring performance over QUIC. Only frameworks with native QUIC support take part."
---

H/3 test profiles measure framework performance over QUIC, the UDP-based transport protocol. Only frameworks with native QUIC support participate.

{{< cards >}}
  {{< card link="baseline-h3" title="Baseline" subtitle="Raw throughput over QUIC, testing HTTP/3 transport performance on frameworks with native QUIC support." icon="globe-alt" >}}
  {{< card link="static-h3" title="Static Files" subtitle="Serves 20 static files over HTTP/3 (QUIC), simulating browser asset loading over the newest protocol." icon="photograph" >}}
{{< /cards >}}
