# HttpArena

[![Discord](https://discordapp.com/api/guilds/1177529388229734410/widget.png?style=shield)](https://discord.com/invite/H84B5ZqDXR)

Results and instructions are on **[http-arena.com](https://http-arena.com/)**:

- [Leaderboard](https://http-arena.com/): the results
- [Knowledge base](https://http-arena.com/docs/): what every test measures, how it is scored, and how to add a framework

## Run Locally

```bash
git clone https://github.com/MDA2AV/HttpArena.git
cd HttpArena

./scripts/validate.sh <framework>            # correctness check
./scripts/benchmark.sh <framework>           # all profiles
./scripts/benchmark.sh <framework> baseline  # specific profile
./scripts/benchmark.sh <framework> gateway-h3,gateway-64  # several profiles, in that order
./scripts/benchmark.sh <framework> --save    # save results
```

## Contributing

- [Add a new framework](https://http-arena.com/docs/add-framework/)
- Improve an existing implementation by opening a PR that modifies files under `frameworks/<name>/`
- [Open an issue](https://github.com/MDA2AV/HttpArena/issues)
- Comment on any open issue or PR

### Framework Maintainers

Add your GitHub username to the `maintainers` array in your framework's `meta.json` to get notified when someone opens a PR that touches your framework:

```json
"maintainers": ["your-github-username"]
```

## Add the badge

Benchmarked here? Put your rank in your own README. It updates itself every
time the board is republished, so you paste it once:

[![HTTP Arena](https://img.shields.io/endpoint?url=https://http-arena.com/badge/actix/h1.json)](https://http-arena.com/#type=emerging,flagship&tuned=0)

```md
[![HTTP Arena](https://img.shields.io/endpoint?url=https://http-arena.com/badge/actix/h1.json)](https://http-arena.com/#type=emerging,flagship&tuned=0)
```

Swap `actix` for your entry and `h1` for the family: `h1`, `h2`, `h3`, `gw`,
`grpc`, `ws` or `db`. Your exact line, linked to the right board, is in
[`/badge/index.json`](https://http-arena.com/badge/index.json) under your
entry's `scopes.<family>.default.markdown`.

<details>
<summary>Families and entry names</summary>

| Family | `<family>` | Composite it reports |
|---|---|---|
| HTTP/1.1 | `h1` | Connection, Concurrency, Efficiency and Workload profiles |
| HTTP/2 | `h2` | the HTTP/2 profiles |
| HTTP/3 | `h3` | the HTTP/3 profiles |
| Gateway | `gw` | reverse-proxy and production-stack profiles |
| gRPC | `grpc` | unary, plaintext and TLS |
| WebSocket | `ws` | the echo profiles |
| Database | `db` | the Async DB and Fortunes profiles |

`<framework>` is your entry's name on the board, lowercased, with anything
outside `A-Z a-z 0-9 . _ -` turned into `-`: the same name as your file in
[`site/data/results/`](site/data/results).

</details>

<details>
<summary>Ranked among your own language</summary>

Append `-<language>` to the family for a badge reading **`#1 of 6 (Rust)`**:
the same scores and the same order, counting only entries in your language.

```md
[![HTTP Arena](https://img.shields.io/endpoint?url=https://http-arena.com/badge/actix/h1-rust.json)](https://http-arena.com/#type=emerging,flagship&tuned=0&lang=Rust)
```

The language is lowercased, with `#` spelled `sharp` and `++` spelled `pp`, so
`C#` is `csharp`, `C++` is `cpp`, `TS` is `ts`. The badge links to the board
filtered to that language, so the field is the one you can count there. Your
line is under `scopes.<family>.byLanguage.markdown`.

</details>

<details>
<summary>Counting tuned entries in</summary>

By default the field is **standard configurations only**, so the number
compares like for like. Append `-with-tuned` to count tuned entries too:

```md
[![HTTP Arena](https://img.shields.io/endpoint?url=https://http-arena.com/badge/actix/h1-with-tuned.json)](https://http-arena.com/#type=emerging,flagship&tuned=1)
```

It combines with the language suffix, as in `h1-rust-with-tuned.json`. If your
own entry is tuned, its default URL already counts tuned entries, since it
cannot be ranked in a field it is excluded from, so `h1.json` and
`h1-with-tuned.json` give it the same number.

</details>

<details>
<summary>What the badge shows</summary>

The right half is how you placed: gold for first, then shading down by how far
into the field you are. The left half is the tier you competed in, in the
colours the board uses for the square next to every framework name:

| | Tier | Ranked against |
|---|---|---|
| 🟩 | `flagship` | flagship + emerging, as one field |
| 🟦 | `emerging` | flagship + emerging, as one field |
| 🟧 | `experimental` | other experimental entries |
| 🟥 | `engine` | other engines, on the profiles engines are scored on |
| 🟦 (teal) | `infrastructure` | other proxies / static-file servers, on the profiles infrastructure is scored on |

- **The rank is against your own tier**, so a framework's ceiling is never set
  by an engine's result, or the reverse.
- **It only exists where you scored.** No result in a family means no badge for
  it, and a family with a single entry in your tier publishes nothing.
- **The field is every row the board lists**, including entries sitting at 0
  because nothing they ran scores for their tier. Those count toward the field
  but get no badge of their own.
- **It follows the default board**: the same scoring as the page it links to,
  and the link lands on the whole field, so `#6 of 83` arrives with the other
  82 around it.

</details>

<details>
<summary>Updates and styling</summary>

The rank changes when the site deploys, then when the caches let it: shields
holds it for 5 minutes, GitHub's image proxy for a few hours. Nothing to
re-paste either way.

Shields' usual styling works: append `&style=flat-square`, `&logo=rust` and so
on to the `img.shields.io` URL.

</details>

The full reference is in the knowledge base:
[README Badge](https://http-arena.com/docs/add-framework/badges/).
