# cutelyst

Cutelyst on Cutelyst::Server, one worker thread per core.

## Stack

- **Language:** C++23
- **Framework:** Cutelyst (Qt 6), built from upstream commit `5ec5ce95` (chunked request body support on top of 5.1)
- **Build:** CMake on Ubuntu 26.04

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/delay/{ms}` | GET | Async wait via `ASync` + `QTimer`, then echoes `ms` |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |

## Notes

- Routing through Cutelyst controllers (`:Local` / `:AutoArgs`)
- JSON through `Response::setJsonObjectBody` (`QJsonDocument`)
- TLS on `:8081` when `/certs/server.crt` and `/certs/server.key` are mounted
- `json-comp` is not subscribed yet: Cutelyst has no built-in dynamic response gzip/brotli middleware under standard rules
