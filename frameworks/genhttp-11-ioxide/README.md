# genhttp-11-ioxide

[GenHTTP 11](https://github.com/Kaliumhexacyanoferrat/GenHTTP) running on a custom
**io_uring** server engine (the [ioxide](https://github.com/MDA2AV/ioxide) runtime)
instead of GenHTTP's default socket engine.

The engine runs GenHTTP's own HTTP/1.1 conversation directly on ioxide's per-connection
duplex pipe — thread-per-core, one io_uring reactor per core, with chunked transfer-encoding,
keep-alive, a per-second cached `Date` header and a per-reactor request pool. It is built from
the GenHTTP `ioxide-engine` branch ([PR #860](https://github.com/Kaliumhexacyanoferrat/GenHTTP/pull/860)):
the Dockerfile clones that branch and the app references its engine plus the
IO / Layouting / Webservices / Compression / Files modules from source, and the published
`ioxide.pg` (Postgres) and `ioxide.tls` (TLS) packages.

Postgres access and TLS termination ride generic per-reactor seams the engine exposes
(`IoxideReactor.Current`, an `onReactorStart` hook, and a connection-transport factory) — the
engine itself stays free of any `ioxide.pg` / `ioxide.tls` dependency.

## Profiles

Responses are produced by GenHTTP's own pipeline (routing + serialization), not hand-written:

- `baseline` — mixed GET/POST with query parsing (`/baseline11` sum webservice)
- `pipelined` — 16× batched pipelining (`/pipeline`)
- `limited-conn` — short-lived connections that close after 10 requests
- `json` / `json-comp` — `/json/{count}?m=N` serialized items; json-comp adds Brotli (`Accept-Encoding`)
- `json-tls` — `json` over TLS on `:8081` (`ioxide.tls`, kTLS TX offload)
- `static` — `/static/...` files with encoding negotiation (Modules.IO / Files)
- `upload` — `POST /upload`, streamed request body, returns the byte count
- `async-db` — `/async-db?min=&max=&limit=`, Postgres via `ioxide.pg` (per-reactor pool)
- `crud` — list / get / create / update on `/crud/items`, cache-aside (`X-Cache`, in-process)
- `api-4` / `api-16` — mixed baseline+json+async-db at 4 / 16 reactors

`json-tls` serves on `:8081` when `TLS_CERT` / `TLS_KEY` (default `/certs`) exist; the DB profiles
need `DATABASE_URL`. Both are provided by the harness sidecars.

## Build note

This entry targets **.NET 11** (`net11.0`), matching the GenHTTP `ioxide-engine` branch it
builds from. Requires the .NET 11 SDK with Roslyn 5.3+ (GenHTTP's `MemoryView` source generator
references `Microsoft.CodeAnalysis 5.3`); the `mcr.microsoft.com/dotnet/sdk:11.0.100-preview.5`
image used by the Dockerfile provides both.
