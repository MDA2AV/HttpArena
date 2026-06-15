# genhttp-11-ioxide

[GenHTTP 11](https://github.com/Kaliumhexacyanoferrat/GenHTTP) running on a custom
**io_uring** server engine (the [ioxide](https://github.com/MDA2AV/ioxide) runtime)
instead of GenHTTP's default socket engine.

The engine runs GenHTTP's own HTTP/1.1 conversation directly on ioxide's per-connection
duplex pipe — thread-per-core, one io_uring reactor per core, with chunked transfer-encoding,
keep-alive, a per-second cached `Date` header and a per-reactor request pool. It is built from
the GenHTTP `ioxide-engine` branch ([PR #860](https://github.com/Kaliumhexacyanoferrat/GenHTTP/pull/860)):
the Dockerfile clones that branch and the app references its engine plus the
IO / Layouting / Webservices modules from source.

## Profiles

HTTP/1.1 only (the engine does not yet do TLS, HTTP/2 or WebSocket):

- `baseline` — mixed GET/POST with query parsing (`/baseline11` sum webservice)
- `pipelined` — 16× batched pipelining (`/pipeline`)
- `limited-conn` — short-lived connections that close after 10 requests

## Build note

Requires a .NET SDK with Roslyn 5.3+ (GenHTTP's `MemoryView` source generator references
`Microsoft.CodeAnalysis 5.3`); the `mcr.microsoft.com/dotnet/sdk:10.0` image used by the
Dockerfile provides it.
