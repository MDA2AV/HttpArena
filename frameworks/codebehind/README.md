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
| `/pipeline` | GET | Returns `ok` |

## Tests subscribed to

- `baseline` — GET/POST `/baseline11`
- `async` — GET `/delay/{ms}`
- `json` — GET `/json/{count}?m=N`
- `echo` — POST `/echo` (also covers the HTTP half of `8gbit`)
- `pipelined` — GET `/pipeline` (reference-only in HttpArena, not scored for
  frameworks)

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
- The dataset is read once at startup via `DatasetService` (registered as a
  singleton); `DATASET_PATH` overrides the default location, which resolves
  to `data/dataset.json` under the app base directory. A missing or broken
  file is not fatal and `/json` then answers with an empty list
- `baseline11`, `delay`, and `echo` declare `async Task PageLoad`; all I/O is
  asynchronous. `json` and `pipeline` are synchronous — they do no I/O.
- `echo` reads the request body as UTF-8 text and writes it back; the HttpArena
  echo test sends text bodies, so this is sufficient
- Only port 8080 (HTTP/1.1) is configured. TLS on 8081, response compression,
  and the H/2, H/3, gRPC, WebSocket, Gateway and Production Stack profiles are
  not implemented in this entry
- The project is `httparena-codebehind.csproj` with assembly `server`