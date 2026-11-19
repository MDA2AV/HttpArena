# Roxygen

[Roxygen](https://github.com/facebookincubator/roxygen) is Meta's HTTP/1.1 and
HTTP/2 library for Rust. It brings the design of
[Proxygen](https://github.com/facebook/proxygen) to Rust: every connection
belongs to one worker thread, and a request or response is a stream of header
and body events that the connection pulls when it is ready for more.

This entry serves the four HTTP/2 profiles with `roxygen_server::HttpServer`
from the `ferroxygen_*` crates on crates.io.

| Listener | Endpoints | Profiles |
| --- | --- | --- |
| h2c `:8082` | `/baseline2`, `/json/{count}` | `baseline-h2c`, `json-h2c` |
| HTTP/2 over TLS `:8443` | `/baseline2`, `/static/*` | `baseline-h2`, `static-h2` |

Both listeners also answer `/spec` and `/spec/headers`.

## Configuration

- One `HttpServer` per listener, each with one worker thread per CPU in the
  container's affinity mask. A connection stays on the worker that accepted it.
- `owned_http2` puts connections on Roxygen's experimental owned HTTP/2 driver,
  which polls a connection's codec, handlers and response bodies from one
  future instead of running a task per request. The `HttpHandler` is the same
  one the default driver runs.
- HTTP/2 settings: 1,024 concurrent streams, a 1 MiB stream window, a 10 MiB
  connection window and a 32 KiB header list limit. Response header values are
  sent as given (`verbatim_http2_header_values`).
- TLS is rustls with the ring provider, TLS 1.3 only, preferring AES-128-GCM,
  with session tickets.
- Session timeouts are off, and responses carry no `Date` header
  (`add_date_header_to_response: false`).
- Responses are in-memory `HttpFixedSource` bodies. Each worker builds its
  response heads once at startup and clones them per request.
- The allocator is mimalloc.

## Static files

`/static/*` is served by
[`StaticFiles`](https://github.com/facebookincubator/roxygen/blob/main/server/src/experimental/static_files.rs)
from `roxygen_server::experimental`. Each worker keeps its own cache that
follows the disk: every request checks the file with `stat`, a cached copy is
served only while the file's inode, size and timestamps still match, and a file
is cached only once it has been unchanged for two seconds. When
`Accept-Encoding` allows, it serves the precompressed `.br` or `.gz` sibling of
a file.

## Running locally

```bash
./scripts/validate.sh roxygen
./scripts/benchmark-lite.sh roxygen baseline-h2
```
