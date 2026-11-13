# genhttp-kt

Kotlin port of the [GenHTTP](https://github.com/Kaliumhexacyanoferrat/GenHTTP) web server, running on its own
HTTP/1.1 engine. The implementation mirrors the [genhttp](../genhttp) entry.

## Stack

- **Language:** Kotlin / JDK 25
- **Framework:** genhttp-kt
- **Engine:** genhttp-kt (NIO channels, a coroutine per connection on virtual threads, JDK SSLEngine for TLS)
- **Build:** Gradle `installDist`, run on the Temurin 25 JRE

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 variant) |
| `/json/{count}` | GET | Processes the first `count` dataset items, serializes JSON |
| `/delay/{ms}` | GET | Answers after waiting `ms` milliseconds |
| `/async-db` | GET | Postgres range query with JSON response |
| `/echo` | POST | Returns the request body back verbatim |
| `/static/{filename}` | GET | Serves static files, using pre-compressed Brotli variants if available |
| `/ws` | GET | WebSocket echo |

## Notes

- Implemented via web services and a layout router
- Compression and routing modules
- Logging is disabled (no-op logger factory on the host, `slf4j-nop` for third-party libraries)
