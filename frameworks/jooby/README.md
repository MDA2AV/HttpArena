# jooby

Jooby 3.9 on Jetty, using the script API.

## Stack

- **Language:** Java 25
- **Framework:** Jooby 3.9 (`jooby-jetty`, `jooby-jackson`)
- **Build:** Maven shade jar, `eclipse-temurin:25-jre` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |

The same routes are served over TLS on port 8081 for `json-tls`.

## Notes

- `ioThreads` and `workerThreads` are both set explicitly, and that is
  load-bearing. `JettyServer.setOptions` does
  `setWorkerThreads(getWorkerThreads(THREADS))` against a hardcoded
  `THREADS = 200`, so leaving it unset does **not** fall back to Jooby's own
  `WORKER_THREADS` (cores × 8) — it pins the pool at 200. Jetty meanwhile sizes
  its selectors from `ioThreads`, which defaults to cores × 2. On the
  64-core/128-thread bench box that is 256 selectors against a 200-thread pool,
  so `ThreadPoolBudget` throws `Insufficient configured threads: required=290 <
  max=200` and the JVM exits before it ever listens. It only appears above
  ~48 cores, so a smaller machine starts fine and hides it
- Jetty rather than Netty, which is Jooby's default. On Netty this entry never
  closes the socket on `Connection: close` — it answers 200 with the right body
  and then holds the connection open, so every fragmentation probe sits waiting
  for an EOF that never arrives and all four GET shapes time out. Setting
  `Connection: close` on the response explicitly did not change it. Jetty
  honours it natively and the frag suite passes 9/9
- Routing and value access through Jooby's `Context` — path parameters via
  `ctx.path(...)`, query via `ctx.query()`
- JSON through the Jackson module, serialized per request; `@JsonPropertyOrder`
  fixes the field order to what the profile expects
- gzip for `json-comp` through Jooby's built-in compression at level 1, the
  level the profile asks for
- Uploads stream through one 64 KB buffer rather than being held in memory, and
  `maxRequestSize` is raised to 64 MB for the 20 MB body
- The dataset is read once at startup and shared; a missing file is not fatal
  and `/json` then answers with an empty list
- json-tls on 8081 via `ServerOptions.setSecurePort`, and a missing `/certs`
  leaves it down instead of aborting startup: `validate.sh` mounts the directory
  only for entries subscribed to a TLS test
- The build forks javac (`<fork>true</fork>`). plexus-compiler's in-process
  compiler throws "Cannot load from object array because this.hashes is null"
  on this JDK; a separate javac process takes a different path and compiles
