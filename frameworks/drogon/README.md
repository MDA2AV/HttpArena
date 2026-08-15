# drogon

Drogon on the trantor event loop, one loop per core.

## Stack

- **Language:** C++20
- **Framework:** Drogon 1.9
- **Build:** CMake on the `drogonframework/drogon` image

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Returns the body byte count |

## Notes

- Routing and path/query params through `registerHandler`
- JSON through `newHttpJsonResponse`, serialized by jsoncpp per request
- Compression is Drogon's built-in gzip, which answers `Accept-Encoding`
- `setThreadNum(0)` uses one event loop per core; the body size limits are raised
  to 30 MB for the upload profile
