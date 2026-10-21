# fiber-tuned

The [`fiber`](../fiber/) entry with three things the standard entry leaves at
the framework's defaults: sonic for JSON, the compress middleware at its
best-speed level, and a Postgres pool filled at startup. sonic is what tuned
mode exists for and standard mode forbids. The level and the pool fill are
documented options of the middleware and the driver the standard entry already
uses (`carter` and `salvo` run their compression at level 1 in standard mode),
and they sit here rather than in `fiber` because that entry's line is *default
configuration*, and a level is a configuration.

The server is otherwise the same: the routes, prefork, the per-request static
reads, the `.br`/`.gz` twin selection, the TLS listener on `8081`, and the
drain-on-signal shutdown are all `fiber`'s, unchanged. `fiber`'s README
documents them, and this file covers only what differs.

Both entries appear on the board — `fiber` as `mode: standard`, this one as
`mode: tuned` with the ring the board draws for tuned entries. `/benchmark`
runs them side by side, so each tuned change shows up as a delta against the
standard entry rather than as a claim.

## What is tuned

| | `fiber` (standard) | `fiber-tuned` |
|---|---|---|
| JSON | `encoding/json` | `sonic` behind `c.JSON` |
| Compress level | framework default | best speed |
| Postgres pool | opened lazily | opened to full size at startup |

Everything else — the body limit, the buffer sizes, `GOGC`, the worker count —
is left at the framework's and the runtime's defaults, the same as the standard
entry. Tuned mode would allow more; these are the changes with a clear rationale
and a measurable effect, and the point of the pair is to measure them rather
than to collect knobs.

## Measured

Not board numbers — those come from `/benchmark` on the reference hardware.
These are from a 4-vCPU sandbox: one prefork worker of each build (child mode,
`GOMAXPROCS(1)`) pinned to one core, the load generator on two others, 16
keep-alive connections, two rounds in alternating order. The metric is CPU per
request, read from `/proc`, because it does not depend on whether the generator
saturates the server. Three builds: `fiber`; this entry on the fasthttp that
Fiber 3.5.0 pinned (v1.73.0); this entry on fasthttp `master`.

They were taken on Fiber 3.5.0 and have not been repeated since. Back then
`fiber` compressed brotli with `andybalholm/brotli`, and this entry raised
fasthttp to `master` at `c96f600` for
[valyala/fasthttp#2366](https://github.com/valyala/fasthttp/pull/2366), which
replaced that library with `molecule-man/go-brrr`. Fiber 3.6.0 pins fasthttp
v1.75.0, which carries that change, so both entries now build on go-brrr
(v1.0.1 in the `master` columns, v1.2.0 today) and `go.mod` no longer raises
anything. For `fiber` today, read the go-brrr numbers at level 4, not the
`andybalholm` ones.

| request | `fiber` | tuned, fasthttp v1.73.0 | tuned, fasthttp master |
|---|---|---|---|
| `/json/50?m=6`, `Accept-Encoding: gzip, br` (json-comp) | 367–378 µs, 1490 B | 148–149 µs, 1940 B | **97–98 µs**, 1944 B |
| `/json/50?m=6`, no encoding (json-tls, minus TLS) | 85 µs | 60–63 µs | 65–70 µs |
| `/baseline11?a=13&b=42` (control) | 11.2–12.9 µs | 14.5–14.9 µs | 11.9–16.5 µs |

The control row is the noise floor: identical code in all three columns, and
it spreads over 11–16 µs. Read the other rows against that. json-comp moves by
hundreds of microseconds and is real; the 5 µs between the two tuned builds on
the uncompressed row is inside the control's own spread, and this README does
not call it a difference.

The deltas in isolation (`go test -bench`, the exact 8397-byte body, fasthttp's
own pooled writers, so the same code path the middleware takes):

| work | `fiber` (fasthttp v1.73.0) | tuned (fasthttp master) |
|---|---|---|
| JSON marshal: `encoding/json` → sonic | 35.1 µs | 12.2 µs |
| brotli level 4 (`LevelDefault`): andybalholm → go-brrr | 259 µs, 1490 B | 107 µs, 1489 B |
| brotli level 0 (`LevelBestSpeed`): andybalholm → go-brrr | 68 µs, 1940 B | 25.6 µs, 1944 B |
| gzip level 6 → 1 (klauspost, the same on master) | 62 µs, 1519 B | 33 µs, 1722 B |

And go-brrr at every level this entry could have picked, same body:

| level | µs | bytes |
|---|---|---|
| 0 (`LevelBestSpeed`) | 25.6 | 1944 |
| 1 | 32.5 | 1876 |
| 2 | 51 | 1553 |
| 4 (`LevelDefault`) | 107 | 1489 |
| 6 | 167 | 1367 |

Level 0 stays the choice. json-comp scores requests per second and requires
valid brotli, not a ratio; at these sizes the 450 extra bytes are nothing on
the wire and the 80 µs between level 0 and the default are most of a request.
Level 2 is the interesting middle — the default's byte count at half its cost —
and the table is here so that whoever wants that trade can see it.

What the tables also show about the standard entry as it was on Fiber 3.5.0:
brotli at fasthttp's default level 4, on the library that release shipped, was
about two thirds of its json-comp cost, and four times what gzip at its own
default took for a body two per cent larger. On go-brrr the same level cost
107 µs instead of 259. The level is still the default, and the standard entry
ships the default.

### JSON: sonic

`fiber.Config{JSONEncoder: sonic.Marshal, JSONDecoder: sonic.Unmarshal}`, and
the handlers that (de)serialize directly call `sonic` too. `c.JSON` runs the
configured encoder (`res.go` calls `app.config.JSONEncoder`), so this reaches
`/json`, `/async-db` and the crud responses without touching a handler.

- Tuned mode names this first: "Alternative JSON serializers (simd-json,
  sonic-json, etc.)", and the `json-comp` and `json-tls` tuned rules both lead
  with "alternative JSON libraries". It is the one change standard mode most
  squarely forbids and tuned mode most squarely invites.
- It is the JIT build, not the `encoding/json` fallback. sonic's build tags
  select the assembly path for `amd64` and `arm64` on every Go from 1.17 up to
  (not including) 1.28; the 1.26 toolchain in the Dockerfile is inside that
  range. On another architecture sonic compiles to a wrapper over
  `encoding/json` and this entry would simply match the standard one.
- The bytes are the same. For the dataset's types sonic's output is identical
  to `encoding/json` (checked), and the one default that differs — sonic does
  not HTML-escape `<`, `>`, `&` — has nothing to act on: the dataset contains
  none of those three characters in any string field.
- sonic compiles an encoder per type on first use. `pretouchJSON` does that at
  startup, once per worker, so the JIT compile lands where nothing is being
  measured instead of in the first requests of a run.

### Compression: best speed

`compress.New(compress.Config{Level: compress.LevelBestSpeed})` on the prefix
the standard entry mounts it on (`/json`).

- Tuned mode allows "tuned compression libraries"; `json-comp` tuned allows
  "tuned compression libraries … as long as the output is valid gzip or
  brotli".
- The profile it changes is `json-comp`, which scores requests per second for a
  body serialized and compressed per request and requires only *valid* gzip or
  brotli, not a ratio. Fiber's middleware picks brotli for the profile's
  `Accept-Encoding: gzip, br`. `LevelDefault` maps to brotli level 4 and gzip
  level 6 (fasthttp's `CompressBrotliDefaultCompression` and
  `CompressDefaultCompression`); `LevelBestSpeed` maps to brotli level 0 and
  gzip level 1. Measured above: 107 µs → 25.6 µs per body for brotli, at
  1489 B → 1944 B on the wire.
- The level is an option of the same middleware the standard entry mounts, not
  a different library, and `carter` and `salvo` set theirs to level 1 in
  standard mode. It could live in `fiber`; whether it should is a question
  about what that entry is for, and this pair keeps the answer measurable.
- Static is unaffected: the middleware is not mounted on `/static`, as in the
  standard entry, so the level only ever applies to the per-request `/json`
  path.

### Postgres pool: eager fill

`cfg.MinConns = cfg.MaxConns`, alongside the `MaxConns` the standard entry
already sets from `DATABASE_MAX_CONN`.

- Tuned mode allows "custom pool sizes … or driver-specific optimizations
  beyond defaults". The *size* is unchanged from the standard entry — it is the
  server's budget divided by the worker count, and a pool bigger than Postgres
  accepts only fails to fill — so what is tuned is *when* the connections open.
- pgxpool opens connections lazily by default, so in the standard entry the
  first `async-db` requests of a run each pay for a TCP connect and a Postgres
  handshake. `MinConns` set to the pool size makes pgxpool open them at startup,
  in a background goroutine, before load arrives.
- Whether that reaches the board is doubtful, and this README should say so:
  each profile runs three times and the best run is kept, which discards a cold
  start by design. The fill matters to the first requests after a container
  starts — a real thing in production, where a deploy is a cold start under
  live traffic — not to a steady-state score. The same goes for `pretouchJSON`.

## Build

Identical to `fiber` (`golang:1.26-alpine` → `alpine:3.23`, `CGO_ENABLED=0`).
sonic needs no cgo. What `go.mod` has that `fiber`'s does not:
`github.com/bytedance/sonic`.
