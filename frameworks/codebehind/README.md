# codebehind

CodeBehind on ASP.NET Core and Kestrel, default configuration.

## Stack

- **Language:** C# / .NET 10
- **Framework:** CodeBehind (controller classes over ASP.NET Core)
- **Build:** Multi-stage, self-contained, `runtime-deps:10.0`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/delay/{ms}` | GET | Waits `ms` milliseconds, returns `ms` |
| `/echo` | POST | Returns the request body back verbatim |
| `/upload` | POST | Reads the request body and returns its byte length |
| `/pipeline` | GET | Returns `ok` |
| `/static/*` | GET | Serves static files from the mounted directory |

## Tests subscribed to

- `baseline` — GET/POST `/baseline11`
- `async` — GET `/delay/{ms}`
- `limited-conn` — GET/POST `/baseline11`, connections close after 10 requests
- `json-comp` — GET `/json/{count}?m=N` with gzip/brotli when `Accept-Encoding` asks for it
- `json-tls` — GET `/json/{count}?m=N` on port 8081 over TLS
- `8gbit` — POST `/echo` on port 8081 over TLS, byte-exact
- `upload` — POST `/upload`
- `static-tls` — GET `/static/*` on port 8081 over TLS
- `pipelined` — GET `/pipeline` (reference-only in HttpArena)
- `latency-1m`, `latency-10k`, `latency-500k-8cpu` — GET/POST `/baseline11`, fixed request rate with CPU measurement

## Notes

- Each endpoint is a CodeBehind page under `wwwroot/<name>/Default.aspx` with
  `@page` and `@controller <Name>Controller`; the physical path of the `.aspx`
  file is what maps a URL to a controller, not the class name. `@segment` is
  declared only on the pages that read URL segments (`json`, `delay`).
- Controllers are partial classes deriving from `CodeBehindController` and are
  registered by `app.UseCodeBehindAsync()`
- Path parameters are read through `Segment.GetValue(0)`
- Responses are written through the controller's `Write()` method, which
  CodeBehind flushes into the HTTP response
- JSON through System.Text.Json with web defaults, serialized per request
- gzip and brotli through ASP.NET Core's `ResponseCompression` at
  `CompressionLevel.Fastest`, which is level 1 and what the profile asks for
- The dataset is read once at startup via `DatasetService` (registered as a
  singleton); `DATASET_PATH` overrides the default `/data/dataset.json`. A
  missing or broken file is not fatal and `/json` then answers with an empty list
- `baseline11`, `delay`, and `echo` declare `async Task PageLoad` and read the
  request body asynchronously. `json`, `pipeline`, and `upload` are synchronous
- `echo` returns the request body byte for byte; the `8gbit` profile sends
  random binary bodies, so the echo path must not decode them as text
- `upload` reads the body and answers with its byte length; it does not trust
  `Content-Length`
- json-tls, 8gbit, and static-tls are served on port 8081, an HTTP/1.1-only
  Kestrel listener, so ALPN advertises `http/1.1` and an h2-capable client is
  never offered the upgrade
- A missing `/certs` leaves the TLS listener down instead of aborting startup;
  `validate.sh` mounts the directory only for entries subscribed to a TLS test
- Static files come from the directory named by `STATIC_PATH`, defaulting to
  `/data/static`, mounted by the harness for the `static-tls` profile
- The H/2, H/3, gRPC, WebSocket, Gateway, Production Stack, Database, and
  Fortunes profiles are not implemented in this entry
- The project is `httparena-codebehind.csproj` with assembly `server`
