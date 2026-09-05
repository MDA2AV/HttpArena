# watson

[Watson Webserver](https://github.com/jchristn/WatsonWebserver) — a small async C# web server for
REST endpoints.

Written the way a caller writes it: routes are declared through Watson's own routing rather than a
hand-rolled dispatch — static routes for the fixed paths, parameter routes for the two that carry a
value in the path — because that is what the library is for and what its numbers should reflect.

## Scope

HTTP/1.1 cleartext on `:8080`, plus the async delay.

| Profiles |
|---|
| baseline, pipelined, limited-conn, async, latency-1m, latency-10k, json-comp |

## Notes

- `/json` is serialized from the parsed model on **every** request and compressed only when the
  client asked for it, at brotli quality 1. Nothing is answered from a precomputed body.
- `/delay/{ms}` uses `Task.Delay`, which registers a timer and yields rather than holding a thread,
  so waits in flight are bounded by memory.
- The project is named `watsonarena` rather than `watson`: a project named for the package it
  depends on makes NuGet resolve a dependency cycle on itself (NU1108).
