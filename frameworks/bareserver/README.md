# bareserver

BareServer - Zero-dependency, native-fast Express-compatible HTTP engine powered by Rust Tokio/Hyper.

## Stack

- **Language:** JavaScript / Rust
- **Runtime:** Node.js 22+
- **Framework:** [bareserver](https://github.com/tarunbtw/bareserver)
- **Engine:** Rust Hyper 1.x / Tokio work-stealing I/O
- **Build:** Multi-stage on `node:22-bookworm-slim`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | Sums query parameter values, plus the body for POST |
| `/baseline2` | GET | Sums query parameter values |
| `/delay/:ms` | GET | Waits `ms` milliseconds asynchronously and returns `ms` |
| `/json/:count` | GET | Serializes a slice of the dataset with multiplier `m` |
| `/db` | GET | Reads from SQLite, read-only, memory mapped |
| `/async-db` | GET | Reads from PostgreSQL through a pool of four |
| `/echo` | POST | Returns the request body back verbatim |

## Notes

- Standard mode: 100% Express-compatible API with zero V8 closure allocations on request dispatch.
- Tokio handles multi-threaded connection acceptance and HTTP/1.1 parsing natively in Rust.
- In-flight requests are served with static prototype dispatch, bypassing V8 GC churn.
