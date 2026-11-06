---
weight: 6
title: Interaction
seo_title: "Interaction Test Profiles"
description: "Benchmarks where connections depend on each other: no request can be answered from that request alone, so work has to cross between workers."
---

Every other profile answers a request from that request alone. That suits a design with one event loop per core and nothing shared, where connections never need each other, and it is why those designs lead most boards.

Plenty of real services don't work like that. A chat server, a game server or a matching engine has to get a message from one connection to another, and the two usually sit on different workers. Interaction profiles measure what that crossing costs, so they rank on a board of their own and count toward no other composite.

{{< cards >}}
  {{< card link="rendezvous" title="Rendezvous" subtitle="Two connections meet on a key. Neither gets an answer until both have arrived, and each is answered with the other's value." icon="switch-horizontal" >}}
{{< /cards >}}
