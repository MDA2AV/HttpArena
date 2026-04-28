# SimpleW

SimpleW is Web server Library in .NET Core. Powerfully Simple and Blazingly Fast.

## Stack

- **Language:** C# / .NET 10
- **Framework:** SimpleW
- **Engine:** SimpleW
- **Build:** Self-contained musl publish, `runtime-deps:10.0-alpine`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 variant) |
| `/json/{count}?m=N` | GET | Processes the first `count` dataset items and computes `total = price * quantity * N` |
| `/async-db?min=X&max=Y&limit=N` | GET | Postgres range query with JSON response |
| `/crud/items` | GET/POST | Paginated list and create endpoint for the CRUD profile |
| `/crud/items/{id}` | GET/PUT | Cached read and cache-invalidating update endpoint |
| `/upload` | POST | Receives upload bodies up to 20 MB and returns the byte count |
| `/static/{filename}` | GET | Serves preloaded static files with MIME types |
| `/ws` | WS | Echo websocket endpoint |

## Notes

- Plain HTTP listens on `8080`.
- If `/certs/server.crt` and `/certs/server.key` are mounted, HTTPS for `json-tls` listens on `8081`.
