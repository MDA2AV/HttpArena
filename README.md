# HttpArena

[![Discord](https://discordapp.com/api/guilds/1177529388229734410/widget.png?style=shield)](https://discord.com/invite/H84B5ZqDXR)
<a href="https://www.anthropic.com"><img src="https://img.shields.io/badge/Sponsored%20by-Anthropic-D97757?logo=anthropic&logoColor=white" alt="Sponsored by Anthropic" /></a>

## Hardware Upgrade
Hi, thank you for visiting or contributing to our project, we are always looking to improve this benchmark platform, if you wish to help us by sponsoring or donating, all the money is invested into infrastructure costs, we are currently aiming for hardware upgrades that would substantially improve our benchmarks.

HTTP framework benchmark platform.

30 test profiles. 64-core dedicated hardware. Same conditions for every framework.

[View Leaderboard](https://www.http-arena.com/) | [Documentation](https://www.http-arena.com/#doc=) | [Add a Framework](https://www.http-arena.com/#doc=add-framework)

---

## PR Commands

| Command | Description |
|---------|-------------|
| `/benchmark -f <framework>` | Run every test the framework subscribes to |
| `/benchmark -f <framework> -t <test>` | Run one test only |
| `/benchmark -f <framework> --save` | Run and save results (updates the leaderboard on merge) |
| `/benchmark -f <framework> -t <test> --save` | Run one test and save results |
| `/benchmark -f <framework> --compare <other>` | Measure the deltas against another framework instead of this one |
| `/benchmark-multiple -f <fw1>,<fw2>,...` | Benchmark several frameworks in one run — takes `-t` and `--save` too; saved results land in a single commit |
| `/benchmark-multiple --save` | No `-f` needed: benchmark and save every framework the PR touches |
| `/benchmark-test -t <test>` | Benchmark **all** enabled frameworks subscribed to `<test>` and save the results |

For `/benchmark`, always specify `-f <framework>`; the flags combine in any order. Results come back as a comment with a per-profile table of RPS, p99, CPU and memory — one table per framework on multi runs. A new benchmark comment while a run is in flight queues behind it (one deep) instead of cancelling it. For multi-framework PRs (dependency bumps, same-language refactors) prefer `/benchmark-multiple`, which runs everything in a single job and commits all saved results together, so no run overwrites another. `--compare` works on single-framework runs only.

**What the deltas are measured against.** By default, this framework's own results published on `main` - answering *"did this change help?"*. When you are tuning a variant or a successor entry, `--compare` re-bases them on another entry instead:

```
/benchmark -f genhttp-11 --compare genhttp
```

The reply states which baseline it used, and profiles the other framework does not run show `n/a` rather than a delta.

---

## Test Profiles

| Category | Profiles | Description |
|----------|----------|-------------|
| Connection | `baseline`, `pipelined` *, `limited-conn` | Mixed GET/POST with query parsing (512/4K conns), 16× batched pipelining (reference-only, shown faded, excluded from the composite score), short-lived connections that close after 10 requests |
| Workload | `json`, `json-comp`, `json-tls`, `upload`, `static`, `static-tls` | JSON serialization, gzip/brotli compression, HTTP/1.1 over TLS, 20 MB body ingestion, 20-file static asset serving (plaintext and TLS) |
| Database | `async-db`, `crud` | Async Postgres sequential scan; realistic REST API with cached reads, list, upsert, update, and optional Redis cache |
| Templates | `fortunes` * | DB query + HTML template render (TechEmpower-style Fortunes). Reference-only — measures template-engine throughput, not part of the composite score |
| Multi-endpoint | `api-4`, `api-16` | Mixed baseline + JSON + async-db at CPU-budget cliffs (4 and 16 logical CPUs, i.e. 2 and 8 full SMT cores) |
| H/2 | `baseline-h2`, `static-h2`, `baseline-h2c`, `json-h2c` | Baseline + static over TLS with h2 stream multiplexing; baseline + JSON over cleartext h2 (prior-knowledge, port 8082) |
| H/3 | `baseline-h3`, `static-h3` | Baseline and static over QUIC with TLS 1.3 |
| gRPC | `unary-grpc`, `unary-grpc-tls`, `stream-grpc`, `stream-grpc-tls` | Unary and server-streaming gRPC over plaintext HTTP/2 and TLS |
| Gateway | `gateway-64`, `gateway-h3` | Reverse proxy + server stack over HTTP/2 and HTTP/3 with mixed workload |
| Production Stack | `production-stack` | Four-service architecture: edge + Redis + JWT auth sidecar + server, 10K-item cache-aside, concurrent reads + writes |
| WebSocket | `echo-ws`, `echo-ws-pipeline`, `echo-ws-limited` | Echo throughput across connection counts; 16x batched echo; echo with each connection closed after 10 messages (upgrade-handshake cost) |

## Run Locally

```bash
git clone https://github.com/MDA2AV/HttpArena.git
cd HttpArena

./scripts/validate.sh <framework>            # correctness check
./scripts/benchmark.sh <framework>           # all profiles
./scripts/benchmark.sh <framework> baseline  # specific profile
./scripts/benchmark.sh <framework> --save    # save results
```

## Contributing

- [Add a new framework](https://www.http-arena.com/#doc=add-framework)
- Improve an existing implementation — open a PR modifying files under `frameworks/<name>/`
- [Open an issue](https://github.com/MDA2AV/HttpArena/issues)
- Comment on any open issue or PR

### Framework Maintainers

Add your GitHub username to the `maintainers` array in your framework's `meta.json` to get notified when someone opens a PR that touches your framework:

```json
"maintainers": ["your-github-username"]
```

## Add the badge

Benchmarked here? Put your rank in your own README. It re-renders itself every
time the board is republished, so you paste it once and never touch it again:

[![HTTP Arena](https://img.shields.io/endpoint?url=https://www.http-arena.com/badge/actix/h1.json)](https://www.http-arena.com/#type=emerging,flagship&tuned=0)

```md
[![HTTP Arena](https://img.shields.io/endpoint?url=https://www.http-arena.com/badge/actix/h1.json)](https://www.http-arena.com/#type=emerging,flagship&tuned=0)
```

Swap `actix` for your entry and `h1` for the family you want:

| Family | `<family>` | Composite it reports |
|---|---|---|
| HTTP/1.1 | `h1` | Connection, Workload, Database and Multi-endpoint profiles |
| HTTP/2 | `h2` | the HTTP/2 profiles |
| HTTP/3 | `h3` | the HTTP/3 profiles |
| Gateway | `gw` | reverse-proxy and production-stack profiles |
| gRPC | `grpc` | unary and streaming, plaintext and TLS |
| WebSocket | `ws` | the echo profiles |

`<framework>` is your entry's name on the board, lowercased, with anything
outside `A-Z a-z 0-9 . _ -` turned into `-` — the same name as your file in
[`site/data/results/`](site/data/results). The full list of what is published,
with every rank in it, is at
[`/badge/index.json`](https://www.http-arena.com/badge/index.json).

### Ranked among your own language

Optional. Append `-<language>` to the family for a badge reading
**`#1 of 6 (Rust)`** — same scores and same order, counting only entries in your
language:

```md
[![HTTP Arena](https://img.shields.io/endpoint?url=https://www.http-arena.com/badge/actix/h1-rust.json)](https://www.http-arena.com/#type=emerging,flagship&tuned=0&lang=Rust)
```

The language is lowercased, with `#` spelled `sharp` and `++` spelled `pp` — so
`C#` is `csharp`, `C++` is `cpp`, `TS` is `ts`. It links to the board filtered to
that language, so the field is the one you can count there. Your line is in
`index.json` under `scopes.<family>.byLanguage.markdown`.

### Counting tuned entries in

Also optional. By default the field is **standard configurations only**, so the
number compares like for like. Append `-with-tuned` to count tuned entries too:

```md
[![HTTP Arena](https://img.shields.io/endpoint?url=https://www.http-arena.com/badge/actix/h1-with-tuned.json)](https://www.http-arena.com/#type=emerging,flagship&tuned=1)
```

It combines with the language suffix — `h1-rust-with-tuned.json`. Every variant
is in `index.json` under `scopes.<family>`, keyed `default`, `withTuned`,
`byLanguage` and `byLanguageWithTuned`.

If your own entry is tuned, its default URL already counts tuned entries — it
cannot be ranked in a field it is excluded from — so `h1.json` and
`h1-with-tuned.json` give it the same number.

The two halves say different things. The right half is how you placed — gold for
first, then shading down by how far into the field you are. The left half is
which tier you competed in, in the same colours the board uses for the little
square next to every framework name:

| | Tier | Ranked against |
|---|---|---|
| 🟩 | `flagship` | flagship + emerging, as one field |
| 🟦 | `emerging` | flagship + emerging, as one field |
| 🟧 | `experimental` | other experimental entries |
| 🟥 | `engine` | other engines, on the profiles engines are scored on |

A few things worth knowing before you paste it:

- **The rank is against your own tier.** `flagship` and `emerging` rank together
  as one field, because that is the board's default view. `engine` entries rank
  among engines, over the profile subset engines are scored on. That way a
  framework's ceiling is never set by an engine's result, or the reverse.
- **It only exists where you scored.** No result in a family means no badge for
  it, and a family with a single entry in your tier publishes nothing — a rank
  is worth showing once there was somebody to beat.
- **The field is every row the board lists.** `of 31` is what you get counting
  engine rows on the linked page, including any entry sitting at 0 because
  nothing it ran scores for its tier. Those occupy a place in the field but get
  no badge of their own.
- **It follows the default board.** Same scoring as the page it links to, with
  the memory-efficiency and rescale toggles off. Follow the link and you land on
  the field the rank was measured against — the whole league, not your row on
  its own, so `#6 of 83` arrives with the other 82 around it.
- **It updates on deploy, then when the caches let it.** shields holds a rank
  for 5 minutes, and GitHub proxies README images through Camo, which holds
  one for a few hours. Nothing to re-paste either way.

Shields' usual styling works — append `&style=flat-square`, `&logo=rust`, and so
on to the `img.shields.io` URL.
