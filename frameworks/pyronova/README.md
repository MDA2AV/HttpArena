# Pyronova — HTTP Arena submission

Pyronova is a Python web framework with a Rust core: hyper + tokio + rustls +
mimalloc, plus PEP 684 sub-interpreters for true multi-core Python. This
submission exposes every Arena endpoint with standard Pyronova decorators —
no special harness-only glue.

## Feature posture

| Profile | Pyronova feature |
|---|---|
| baseline / pipelined / limited-conn | sub-interpreter dispatch, mimalloc, SO_REUSEPORT |
| json / json-comp | Rust-side `serde_json` via `pythonize`; `app.enable_compression()` handles `Accept-Encoding` |
| json-tls | rustls 0.23 (ring), ALPN `h2,http/1.1` |
| baseline-h2 / static-h2 | same TLS listener on :8443; hyper's `AutoBuilder` picks HTTP/2 on negotiated ALPN |
| upload | `@app.post(stream=True)` — chunked body ingest via tokio feeder → mpsc channel, no buffering |
| async-db | `PgPool` backed by sqlx on a dedicated tokio runtime, shared across workers via Rust-side `OnceLock` |
| static | Tokio async-fs with `O_NOFOLLOW` + mime-from-extension |

Everything is compiled in and runtime-toggled. A single `pip install
pyronova` covers every profile; no Cargo features or rebuilds.

## Build (local)

Populate the Pyronova source into the build context, then build:

```bash
cp -r /path/to/pyronova frameworks/pyronova/pyronova_src
docker build -t httparena-pyronova frameworks/pyronova
```

Or let the Arena CI populate `pyronova_src` from the official repo.

## Run (manual / debug)

```bash
./scripts/run.sh pyronova
```

Exposes 8080 (plain), 8081 (TLS h1), 8443 (TLS h2). Harness probes
`http://localhost:8080/baseline11?a=1&b=1` to confirm readiness.

## Design notes

Two processes are spawned by `launcher.py` — one for plaintext, one for
TLS — because Pyronova's `app.run()` binds a single port. Each process
gets half the CPU budget to avoid sub-interpreter oversubscription.
The HTTP/2 listener shares the TLS process (single listener; ALPN
picks the protocol). This is a launcher detail, not a framework
limitation — a follow-up adds multi-bind to the engine so one process
covers all three ports.

The PgPool is a Rust-side `OnceLock<sqlx::PgPool>` — not per-Python-
interpreter. All sub-interp workers reach the same pool via the global,
so a 16-interp deployment doesn't multiply connection count.
