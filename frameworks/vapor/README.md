# vapor

Vapor 4 on SwiftNIO, default configuration.

## Stack

- **Language:** Swift 6.2
- **Framework:** Vapor 4.122
- **Build:** Multi-stage, `ubuntu:22.04` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Streams the body and returns the byte count |

## Notes

- Routing and path/query decoding through the Vapor API
- JSON through `Content`, encoded per request by Codable
- Compression through `http.server.configuration.responseCompression`
- `/upload` uses a streaming body so the 20 MB body is never collected
