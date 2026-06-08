# veb

[veb](https://modules.vlang.io/veb.html) is the web framework that ships with
the [V](https://vlang.io) standard library.

## Implemented tests

| Test | Endpoint |
|------|----------|
| `pipelined` | `GET /pipeline` |
| `json` | `GET /json/{count}?m=M` (over `/data/dataset.json`) |
| `async-db` | `GET /async-db?min&max&limit` via `db.pg` |

> The `baseline` profile is not subscribed: veb does not decode chunked request
> bodies, which baseline validation requires. `GET/POST /baseline11` are still
> implemented for non-chunked requests.

## Stack

* [V](https://vlang.io) 0.5.1 (pinned prebuilt release)
* [veb](https://modules.vlang.io/veb.html) — HTTP framework
* `db.pg` (stdlib) — pooled PostgreSQL driver

JSON is serialized manually (precomputed prefixes + `strings.Builder`) to avoid
per-request reflection.
