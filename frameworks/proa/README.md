# Proa

Proa compiles the Fortunes HTML component and serves HTTP/1.1 (with TLS 1.3 on `:8081` via `rustls`/`aws-lc-rs`) over thread-per-core Axum/Hyper workers with `mimalloc` v2, `SO_REUSEPORT`, `TCP_NODELAY`, `sonic-rs`, thread-local `libdeflater` gzip compression, and per-worker `deadpool-postgres` pools.

On `/fortunes`, each request queries PostgreSQL, borrows row strings, appends the runtime row, sorts in byte order, and renders escaped HTML directly into one owned response buffer. The remaining HTTP/1.1 profiles exercise the same Axum/Hyper server stack (`sonic-rs` + `libdeflater` gzip on `/json/{count}`, zero-copy `/echo` over TLS, `/async-db`, `/baseline11`, `/pipeline`, and `/delay/{ms}`).
