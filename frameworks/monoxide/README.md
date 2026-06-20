# monoxide

[Monoxide](https://github.com/MDA2AV/Monoxide) - an ioxide-native HTTP/1.1 web framework. Shared-nothing
per-reactor: requests are parsed off the io_uring recv rings with [Glyph11](https://github.com/MDA2AV/Glyph11)
and responses written straight into the write slab - no `Stream`, no `Pipe` - on the published
[ioxide](https://github.com/MDA2AV/ioxide) 0.0.10 engine.

Routing, parsing, keep-alive, pipelining, chunked bodies, and response framing are the framework's; this
entry's `Program.cs` is just the route map.

## Profiles

| profile | how |
|---|---|
| baseline / pipelined / limited-conn | `a + b + body` sum, text/plain; the framework's Glyph11 parse + keep-alive + pipelining |
| json | dataset items serialized field-by-field, `total = price*quantity*m` |
| json-comp | json brotli-encoded per request when the client sends `Accept-Encoding: br` |
| upload | POST body drained against the framing, byte count returned |
| static | `ioxide.file` baked snapshots, br > gz > identity negotiation (`Content-Encoding` + `Vary`) |

## Build

The Dockerfile clones Monoxide to `/src/monoxide`. Local build:
`dotnet build monoxide-arena.csproj -c Release -p:MonoxideSrc=/path/to/Monoxide`.

## Env

- `IOXIDE_REACTORS` (default: processor count), `IOXIDE_PORT` (8080)
- `IOXIDE_DATASET` (/data/dataset.json), `IOXIDE_STATIC` (/data/static)
