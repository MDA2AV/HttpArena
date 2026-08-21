---
title: Implementation Rules
seo_title: "Implementation Rules by Entry Type"
description: "Every entry declares a type in meta.json. Learn which rules apply to framework, engine, infrastructure and experimental entries, and how each is ranked."
weight: 5
---

Every entry declares a **type** in `meta.json` - what it is and how it is ranked. The split is about what the entry *is*, not how featureful it is: a server applications are written against is a framework entry however thin, and the framework tiers then grade how production-proven it is. Framework entries (Flagship / Emerging / Experimental) additionally declare a **mode** (Standard or Tuned).

{{< cards >}}
  {{< card link="frameworks" title="Frameworks" subtitle="Servers you write application code against, tiered by how production-proven they are. Run in Standard or Tuned mode." icon="collection" >}}
  {{< card link="engine" title="Engine" subtitle="HTTP implementations applications are not written against (raw sockets, custom parsers, WSGI/ASGI hosts). Ranked separately." icon="lightning-bolt" >}}
  {{< card link="infrastructure" title="Infrastructure" subtitle="Reverse proxies and static-file servers (nginx, Caddy, h2o) without an app framework layer." icon="server" >}}
{{< /cards >}}
