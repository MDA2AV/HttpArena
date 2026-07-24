---
title: Implementation Rules
weight: 5
---

Every entry declares a **type** in `meta.json` - what it is and how it is ranked. Framework entries (Flagship / Emerging / Experimental) additionally declare a **mode** (Standard or Tuned).

{{< cards >}}
  {{< card link="frameworks" title="Frameworks" subtitle="Flagship, Emerging and Experimental tiers - run in Standard or Tuned mode." icon="collection" >}}
  {{< card link="engine" title="Engine" subtitle="Bare-metal HTTP implementations (raw sockets, custom parser). Ranked separately." icon="lightning-bolt" >}}
  {{< card link="infrastructure" title="Infrastructure" subtitle="Reverse proxies and static-file servers (nginx, h2o) without an app framework layer." icon="server" >}}
{{< /cards >}}
