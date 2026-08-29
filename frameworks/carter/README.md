# carter

Carter 10 on ASP.NET Core and Kestrel, default configuration.

## Stack

- **Language:** C# / .NET 10
- **Framework:** Carter 10 (routing modules over ASP.NET Core)
- **Build:** Multi-stage, self-contained, `runtime-deps:10.0`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Reads the body and returns the byte count |

The same routes are served over TLS on port 8081 for `json-tls`.

## Notes

- Routes are declared in an `ICarterModule` and mapped through `MapCarter()`,
  rather than on the app directly: module discovery and the
  `IEndpointRouteBuilder` mapping are what this entry exists to measure
- JSON through System.Text.Json with web defaults, serialized per request
- Compression through ASP.NET Core's `ResponseCompression`, gzip and brotli at
  `CompressionLevel.Fastest`, which is level 1 and what the profile asks for
- Uploads are counted through one rented 64 KB buffer rather than held in
  memory, and `MaxRequestBodySize` is raised to 64 MB for the 20 MB body
- The dataset is read once at startup; a missing or broken file is not fatal
  and `/json` then answers with an empty list
- json-tls on 8081 is an HTTP/1.1-only Kestrel listener, so ALPN advertises
  `http/1.1` and an h2-capable client is never offered the upgrade
- A missing `/certs` leaves the TLS listener down instead of aborting startup:
  `validate.sh` mounts the directory only for entries subscribed to a TLS test
- The project is `httparena-carter.csproj` with assembly `server`: naming it
  `carter` makes NuGet read the Carter package reference as a dependency cycle
