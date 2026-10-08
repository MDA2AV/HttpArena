# zinc

Zinc web framework on the Go `net/http` server, default configuration.

## Stack

- **Language:** Go 1.26
- **Framework:** Zinc 0.7
- **Build:** `golang:1.26-alpine` -> `alpine:3.23` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |

## Notes

- Routing and path parameters through the Zinc router (`{name}` patterns), JSON through `c.JSON`, JSON request bodies through `c.Bind().JSON`
- Compression through the `middleware/compress` package
- HTTP/2 through the standard `net/http` server: over TLS on `:8443` (ALPN `h2`), and cleartext on `:8082` via `http.Protocols.SetUnencryptedHTTP2`. A Zinc app is an `http.Handler`, so it is served as-is
- Default configuration: no middleware besides compression; Zinc's built-in `/openapi.json` and `/docs` routes are left on, as they are by default

## Added profiles

`static`, `static-tls`, `json-tls`, `async-db`, `crud`, `baseline-h2`, `static-h2`, `baseline-h2c` and `json-h2c`.
