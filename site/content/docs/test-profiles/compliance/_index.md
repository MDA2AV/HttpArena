---
title: Compliance
seo_title: "Protocol Compliance: The /spec Route"
description: "The /spec route the protocol-compliance suites run against, and the compliance score shown beside the H/1.1, H/2, H/3 and WebSocket results. Nothing here is measured or ranked."
weight: 6
---

Every entry gets a protocol-compliance score per protocol, shown in its own column on the H/1.1, H/2, H/3 and WebSocket boards. It is a score, not a gate: nothing here blocks an entry, and the compliance columns are never part of the composite.

| Column | Suite | Runs against |
|---|---|---|
| H/1.1 | [Http11Probe](https://www.http-probe.com/), pointed at HttpArena's routes | `/spec` on port 8080 |
| H/2 | [h2spec](https://github.com/summerwind/h2spec) | `/spec` on port 8443 (TLS) and/or 8082 (h2c) |
| H/3 | [h3spec](https://github.com/kazu-yamamoto/h3spec) | the QUIC listener on port 8443 - no route needed |
| WebSocket | [Autobahn Testsuite](https://github.com/crossbario/autobahn-testsuite) | the existing [`/ws` echo](../ws/) |

Two of the suites need things the benchmark routes do not provide: HEAD and OPTIONS answered with `200`, a request body echoed back whatever it contains, and the request headers echoed back. `/spec` is one route that provides all of it. h3spec sends malformed QUIC and HTTP/3 traffic and checks the error the server closes with, so it never needs a route, and Autobahn already has one in `/ws`.

The route is opt-in for now. An entry turns it on with `"spec": true` in `meta.json`; without it, the entry's H/1.1 and H/2 compliance cells show as not measured. The compliance columns themselves are being added to the validation run - until they land, validation checks the route but no score is recorded.

{{< cards >}}
  {{< card link="implementation" title="Implementation" subtitle="The /spec contract: methods, ports, bodies, the header echo, and why each part exists." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="What validate.sh checks on /spec, on each listener the entry runs." icon="check-circle" >}}
{{< /cards >}}
