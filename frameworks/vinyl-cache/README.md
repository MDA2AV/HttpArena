# Vinyl Cache

Vinyl Cache is the current name of what used to be called Varnish — same project, renamed, not a fork. See [vinyl-cache.org](https://vinyl-cache.org/). No Fedora package exists yet, so this framework builds `vinyld` from source. It runs a custom vmod (`vmod_httparena`) computing `/baseline11` entirely inside `vinyld` — no separate backend process.

## Stack

- **Language:** C
- **Engine:** vinyld main branch (vinyl-cache)
- **Build:** Multi-stage, built from source (autotools) on `fedora:43`
- **Dynamic logic:** `vmod_httparena`, a small C vmod to handle the `/baseline11` sum

## vmod_httparena VMOD

The custom vmod resides in `vmod/` and gets added to the source tree by copying
the relevant files and patching `Makefile.am`.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text), answered directly via `vcl_synth` |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
