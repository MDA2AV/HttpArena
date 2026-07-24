---
title: Implementation Rules
seo_title: "Implementation Rules by Entry Type"
description: "Every entry declares a type in meta.json. Learn which rules apply to framework, engine and experimental entries, and how each is ranked."
weight: 5
---

Every entry declares a **type** in `meta.json` - what it is and how it is ranked. Framework entries (Flagship / Emerging / Experimental) additionally declare a **mode** (Standard or Tuned).

{{< cards >}}
  {{< card link="frameworks" title="Frameworks" subtitle="Flagship, Emerging and Experimental tiers - run in Standard or Tuned mode." icon="collection" >}}
  {{< card link="engine" title="Engine" subtitle="Bare-metal HTTP implementations (raw sockets, custom parser). Ranked separately." icon="lightning-bolt" >}}
{{< /cards >}}
