# fiber-tuned

The [`fiber`](../fiber/) entry with four things the standard entry leaves at
the framework's defaults: sonic for JSON, the compress middleware at its
best-speed level, a Postgres pool filled at startup, and fasthttp at `master`
rather than at the release Fiber 3.5.0 pins — for the brotli library master
swapped in. sonic is what tuned mode exists for and standard mode forbids. The
level and the pool fill are documented options of the middleware and the driver
the standard entry already uses — `carter` and `salvo` run their compression at
level 1 in standard mode — and they sit here rather than in `fiber` because
that entry's line is *default configuration*, and a level is a configuration.
So is a dependency pin.

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
| fasthttp | v1.73.0, Fiber 3.5.0's pin | `master` at `c96f600` (2026-08-31): brotli by go-brrr |

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
saturates the server. Three builds: `fiber`; this entry on the fasthttp Fiber
pins (v1.73.0); this entry as shipped, on fasthttp `master`.

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

What the tables also show about the standard entry: brotli at fasthttp's
default level 4, on the library the release ships, is about two thirds of its
json-comp cost, and four times what gzip at its own default takes for a body
two per cent larger. That is the default, and the standard entry ships the
default.

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

`compress.New(compress.Config{Level: compress.LevelBestSpeed})` on the same two
prefixes the standard entry mounts it on (`/json`, `/static`).

- Tuned mode allows "tuned compression libraries" and "Any compression approach
  for static files"; `json-comp` tuned allows "tuned compression libraries … as
  long as the output is valid gzip or brotli".
- The profile it changes is `json-comp`, which scores requests per second for a
  body serialized and compressed per request and requires only *valid* gzip or
  brotli, not a ratio. Fiber's middleware picks brotli for the profile's
  `Accept-Encoding: gzip, br`. `LevelDefault` maps to brotli level 4 and gzip
  level 6 (fasthttp's `CompressBrotliDefaultCompression` and
  `CompressDefaultCompression`); `LevelBestSpeed` maps to brotli level 0 and
  gzip level 1. Measured above: 259 µs → 68 µs per body for brotli, at 1490 B →
  1940 B on the wire.
- The level is an option of the same middleware the standard entry mounts, not
  a different library, and `carter` and `salvo` set theirs to level 1 in
  standard mode. It could live in `fiber`; whether it should is a question
  about what that entry is for, and this pair keeps the answer measurable.
- Static is unaffected: the twins on disk are already compressed, and the
  middleware leaves an encoded body alone — so the level only ever applies to
  the per-request `/json` path.

### fasthttp: master, for go-brrr

`go.mod` raises fasthttp from the v1.73.0 that Fiber 3.5.0 pins to `master` at
`c96f600` (2026-08-31). Fiber's own requirement stays as it is; Go's minimum
version selection takes the higher of the two, and Fiber 3.5.0 builds against
it unchanged.

- What master has that v1.73.0 does not is
  [valyala/fasthttp#2366](https://github.com/valyala/fasthttp/pull/2366), merged
  2026-08-29: `andybalholm/brotli` replaced by `molecule-man/go-brrr`, a pure-Go
  brotli. The PR's motivation is that the old library is no longer maintained
  and its author points at go-brrr; the PR's own numbers on a 256 KiB HTML are
  2.0× at level 0 and 1.16× at level 4, and on this entry's 8 KB JSON above
  they are 2.7× and 2.4×.
- Wire-compatible. fasthttp's level constants keep their values, and the PR
  checked encode and decode both ways against streams from the old library.
  Its reviewer found the one behavioural difference — go-brrr accepted trailing
  bytes the old decoder rejected — and the merged PR closes it. Decoding is not
  on this entry's path anyway; it only encodes.
- Tuned mode allows "tuned compression libraries"; this is one, taken through
  the framework's own dependency rather than around it. The compress middleware
  is unchanged and does not know which library fasthttp built it on.
- The standard entry stays on the release, deliberately: v1.73.0 is what Fiber
  3.5.0 pins, and "default configuration" includes the dependency graph. When
  fasthttp cuts the release that carries #2366 and Fiber picks it up, `fiber`
  gets it for free and this row of the table closes to zero — which is the
  kind of thing a tuned/standard pair is for.

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
sonic needs no cgo and neither does go-brrr. What `go.mod` has that `fiber`'s
does not: `github.com/bytedance/sonic`, fasthttp raised to the `master`
pseudo-version, and `github.com/molecule-man/go-brrr` arriving through it in
place of `github.com/andybalholm/brotli`.
