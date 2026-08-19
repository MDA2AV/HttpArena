# fulmine-tuned

The same entry as [`fulmine`](../fulmine/), differing in three settings and nothing else. Diff the
two `app.js` and that is all there is to see: same routes, same middleware, same compression, same
`express.static()`. What the tuning buys is measured by the arena, not claimed here.

## Stack

- **Language:** JavaScript
- **Runtime:** Node.js 22
- **Framework:** [fulmine.js](https://github.com/nigrosimone/fulmine.js) (Express 5 API on uWebSockets.js)
- **Build:** Multi-stage, `node:22` build to `ubuntu:24.04` runtime

## What is tuned

Three shipped settings, each set through the framework's documented API. No hand-rolled
compression, no suffix lookup, no alternative JSON serializer, nothing precomputed at startup.

| Setting | Standard entry | Here | Why a standard entry may not have it |
|---------|---------------|------|--------------------------------------|
| `stat cache` | unset (`0`) | `24h` | The size and mtime of a file, never its body. The read still happens per request; what this saves is the syscall that asks whether the file changed. Longer than any run: the harness mounts these files read-only and nothing writes to them while the container lives. |
| `connection headers` | `true` | `false` | Drops `Connection: keep-alive` and `Keep-Alive: timeout=10` from every response. Express sends both, so a standard entry sends them too; HTTP/1.1 keeps the connection alive without being told. |

**No static file is held in memory.** `file cache` is off here exactly as it is in the standard
entry: caching bodies is against the rules whatever the mode, because the static profile exists to
measure file I/O. Every request reads the file it answers with.

## What is deliberately not tuned

- **The compression level stays where the standard entry has it**, brotli quality 3 with gzip
  level 1 as the fallback. `json-comp` scores `rps * (minBpr/myBpr)^2`, so smaller output is worth
  its weight twice over, which makes a higher quality look free. It is not: measured on this
  profile's own payload, the average body over counts 25, 40 and 50, quality 4 costs 88% more
  encode time for 0.2% fewer bytes, quality 5 costs ten times the time for 8% fewer bytes, and
  quality 11 is 160x the time for 21%. Against the squared byte term every one of them still
  loses, by 13% at quality 4 and by 95% at quality 11. Quality 3 is the maximum of that function,
  not a compromise, so there is nothing here for a tuned entry to take.
- **No alternative JSON serializer.** The framework's `res.json()` is what an application uses and
  what the standard entry uses.
- **Nothing is precomputed or cached per response.** Every request serializes and compresses its
  own body, which both modes require.

## Endpoints

The same handlers and the same twenty profiles as the standard entry, gateway and
production-stack included.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | Sums query parameter values, plus the body for POST |
| `/baseline2` | GET | Sums query parameter values |
| `/json/:count` | GET | Serializes a slice of the dataset, compressed when the client asks |
| `/async-db` | GET | Reads from PostgreSQL, prepared statement, pool sized under max_connections |
| `/upload` | POST | Counts the bytes of the request body |
| `/static/*` | GET | `express.static()` with `preCompressed`, served from the in-memory cache |

## Notes

The rest is the standard entry's, unchanged and worth repeating here:

- Routes with a parameter, `/json/:count` among them, are handed to the µWS router rather than
  matched in JavaScript.
- A handler simple enough to be read at registration time is compiled into a µWS declarative
  response. `/pipeline` is one, so it is answered without entering JavaScript. "Simple enough"
  means every argument is a literal, which is why its headers are written out instead of coming
  from the shared `SERVER_HDR`: the compiler reads the source and cannot see into a closure.
- `express.compression()` is the framework's own, taking the compression module's options: it is
  mounted on the json route, which is the only one the profiles ask to compress.
- `express({ cluster: "auto" })` is the framework's own fork, so there is no cluster boilerplate in
  the entry: one worker per usable core, each binding the same port with uWS's shared flag, which
  is `SO_REUSEPORT`. The kernel picks which worker gets a connection and the primary is not in the
  path, unlike node's `cluster` with an `http.Server`, where the primary accepts and passes each
  connection on. "auto" reads the cgroup quota first, so the worker count is the container's cores
  and not the host's.
