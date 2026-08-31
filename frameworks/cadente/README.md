# Cadente

Cadente is a standalone managed HTTP/1.1 server for .NET. This entry uses `Sisk.Cadente` directly, without the Sisk framework, routing, middleware, or response abstractions.

## Stack

- **Language:** C# / .NET 10
- **Engine:** Cadente managed sockets
- **Package:** `Sisk.Cadente` 1.6.3-rc2
- **Build:** Self-contained Linux x64 publish

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters and a fixed-length or chunked request body |
| `/pipeline` | GET | Returns `ok` as plain text |

## Profiles

- `baseline`
- `latency-1m`
- `latency-10k`
- `pipelined`
- `limited-conn`
