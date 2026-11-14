---
title: Compliance
seo_title: "Protocol Compliance: The /spec Route"
description: "The /spec route the protocol-compliance suites run against, and the compliance score shown beside the H/1.1, H/2, H/3 and WebSocket results. Nothing here is measured or ranked."
weight: 6
---

An entry gets a protocol-compliance score for each suite it subscribes to, shown in that protocol's column on the H/1.1, H/2, H/3 and WebSocket boards. It is a score, not a gate: nothing here blocks an entry, and the compliance columns are never part of the composite.

| Column | `spec` | Suite | Runs against |
|---|---|---|---|
| H/1.1 | `h1` | [Http11Probe](https://www.http-probe.com/), pointed at HttpArena's routes | `/spec` on port 8080 |
| H/2 | `h2` | [h2spec](https://github.com/summerwind/h2spec) | `/spec` on port 8443 (TLS) and/or 8082 (h2c) |
| H/3 | `h3` | [h3spec](https://github.com/kazu-yamamoto/h3spec) | the QUIC listener on port 8443 - no route needed |
| WebSocket | `ws` | [Autobahn Testsuite](https://github.com/crossbario/autobahn-testsuite) | the existing [`/ws` echo](../ws/) |

Two of the suites need things the benchmark routes do not provide: HEAD and OPTIONS answered with `200`, a request body echoed back whatever it contains, and the request headers echoed back. `/spec` is one route that provides all of it. h3spec sends malformed QUIC and HTTP/3 traffic and checks the error the server closes with, so it never needs a route, and Autobahn already has one in `/ws`.

An entry subscribes to the suites it wants with `spec` in `meta.json`, a list like `tests`:

```json
"spec": ["h1", "h2", "h3", "ws"]
```

A suite the entry does not list shows as not measured in its column. Only `h1` and `h2` need `/spec`.

## Running the suites

On a PR, `/spec -f <entry>` runs the suites the entry lists, and a `/benchmark` without `-t` runs them after the benchmark. With `--save` the scores are committed to the PR as `site/data/spec/<entry>.json`, the way benchmark results are saved to `site/data/results/`. `<entry>` is the directory under `frameworks/`, not the display name: entries that share a display name (`actix`, `actix-h2c` and `actix-websocket` are all "actix" on the board) each keep their own file. Locally:

```bash
./scripts/spec.sh <entry>          # scores in results/spec/<entry>.json
./scripts/spec.sh <entry> --save   # and in site/data/spec/<entry>.json
```

Each suite runs against a fresh container, with the tools pinned in `scripts/spec.sh`: Http11Probe at a fixed commit, h2spec 2.6.0, h3spec v0.1.15 and Autobahn 25.10.1. Autobahn runs its cases 1-7 and 10: case 9 is a throughput test and 12-13 cover permessage-deflate, which no profile asks for.

## The scores

```json
{
  "framework": "aspnet-minimal",
  "dir": "aspnet-minimal",
  "suites": {
    "h1": {"tool": "http11probe", "version": "d50d818", "passed": 144, "total": 159, "warnings": 19,
           "failed": [{"id": "RFC9112-6.1-CL-PLUS-SIGN", "test": "Content-Length with plus sign must be rejected",
                       "rfc": "RFC 9112 §6.1", "level": "Must", "expected": "400 or close",
                       "got": "200, connection left open"}, "..."]},
    "h2": {"tool": "h2spec", "version": "2.6.0", "passed": 146, "total": 146, "failed": [],
           "listeners": {"tls": {"passed": 146, "total": 146, "failed": []}, "h2c": {"passed": 146, "total": 146, "failed": []}}},
    "h3": {"tool": "h3spec", "version": "v0.1.15", "passed": 43, "total": 85, "failed": [{"id": "...", "got": "..."}]}
  }
}
```

- **`passed` out of `total`** for every suite the entry lists, and in `failed` one record per failed test: its `id`, what it checks (`test`), what the tool `expected` and what the server did (`got`), with the RFC section and level where the tool gives them. The raw output stays on the machine that ran the suite, so this is what explains a failure: the `/spec` and `/benchmark` comments list it in a table per suite, and the entry's page on the site has a "Protocol compliance" section with the same tables, linked from its Spec cell.
- **`h1`** counts the probe's scored tests. A warning - the RFC allows both the strict and the lenient behaviour - counts as passed.
- **`h2`** is scored on each HTTP/2 listener the entry runs; the score is the weaker of the two, and both are kept under `listeners`.
- **`h3`** leaves out the tests h3spec reports as pending (0-RTT, extra streams it could not open).
- **`ws`** leaves out Autobahn's informational cases, which pass or fail no one, and lists `non_strict` ones, which pass.
- **`error`** in place of a score means the suite could not be measured at all - the server never came up, or the WebSocket handshake was refused on every case. It is not a score of zero.
- **`crashed`** means the server stopped running during the suite. The tests it could no longer answer count as failed.

On the board, the score is the Spec column of the H/1.1, H/2, H/3 and WebSocket views, right after the composite: the share of the suite passed, with passed out of total under it and the tool, failures and any crash in its tooltip. It sorts like any other column and is never part of the composite. Entries that share a display name are joined there: aspnet-minimal's WebSocket score comes from `aspnet-websocket.json`. If two of them run the same suite, the weaker score is shown. A dot means the entry does not run the suite, and a dash that it could not be measured.

{{< cards >}}
  {{< card link="implementation" title="Implementation" subtitle="The /spec contract: methods, ports, bodies, the header echo, and why each part exists." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="What validate.sh checks on /spec, on each listener the entry runs." icon="check-circle" >}}
{{< /cards >}}
