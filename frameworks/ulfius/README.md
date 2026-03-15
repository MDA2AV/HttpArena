# Ulfius — C REST Framework

[Ulfius](https://github.com/babelouest/ulfius) is a lightweight HTTP framework for building REST APIs in pure C. Built on GNU Libmicrohttpd with Jansson for JSON processing, it's designed for embedded systems and applications where a small memory footprint matters.

## Why it's interesting

- **Pure C** — first C application framework in HttpArena (h2o/nginx are web servers, not app frameworks)
- **Libmicrohttpd backend** — battle-tested GNU HTTP library under the hood
- **Minimal footprint** — designed for embedded/constrained environments
- **Solo developer project** — @babelouest has been maintaining this since 2015

## Implementation notes

- Uses Jansson for all JSON serialization (same lib used by many C projects)
- Thread-local SQLite connections with prepared statements for `/db`
- Pre-loads datasets and static files into memory at startup
- TLS via GnuTLS (Ulfius's built-in secure framework support)
- Signal-based clean shutdown
