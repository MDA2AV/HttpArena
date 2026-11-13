# genhttp-kt-netty

Kotlin port of the [GenHTTP](https://github.com/Kaliumhexacyanoferrat/GenHTTP) web server, running on its Netty
engine - the counterpart of GenHTTP's ioxide engine. The application is the one of the [genhttp-kt](../genhttp-kt)
entry; only the engine differs (the dependency `genhttp-core-netty` and the `Host` it imports).

## Stack

- **Language:** Kotlin / JDK 25
- **Framework:** genhttp-kt
- **Engine:** Netty (one event loop per core on the native epoll transport, sockets bound per loop with
  `SO_REUSEPORT`, every connection served by a coroutine on the loop that accepted it, timers on that loop,
  TLS through OpenSSL via netty-tcnative)
- **Build:** Gradle `installDist`, run on the Temurin 25 JRE

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 variant) |
| `/json/{count}` | GET | Processes the first `count` dataset items, serializes JSON |
| `/delay/{ms}` | GET | Answers after waiting `ms` milliseconds (a timer on the event loop) |
| `/async-db` | GET | Postgres range query with JSON response |
| `/echo` | POST | Returns the request body back verbatim |
| `/static/{filename}` | GET | Serves static files, using pre-compressed Brotli variants if available |
| `/ws` | GET | WebSocket echo |

## Notes

- Implemented via web services and a layout router
- Compression and routing modules
- Handlers run on the event loops and must not block: the JDBC calls of `/async-db` run on a dispatcher with as
  many threads as the connection pool, the request resumes on its event loop afterwards
- Logging is disabled (no-op logger factory on the host, `slf4j-nop` for third-party libraries)
