# Dream (OCaml)

[Dream](https://github.com/camlworks/dream) is a tidy, feature-complete web framework for OCaml. It compiles to native code via the OCaml 5 compiler and uses httpaf/h2 under the hood with Lwt for async I/O.

## Why Dream?

- **Native compiled** — OCaml compiles to efficient native machine code
- **Functional approach** — handlers are just functions, middleware composes naturally
- **Lwt async** — cooperative concurrency without callback hell
- **Feature-complete** — routing, sessions, WebSockets, TLS, all in one flat module
- **1,800+ stars** — actively maintained by the OCaml community

## Implementation Notes

- Uses `Yojson` for JSON serialization
- Uses `sqlite3-ocaml` bindings for the `/db` endpoint
- Static files are pre-loaded into memory at startup
- Dataset is parsed once at startup and JSON response is pre-built
- Large dataset JSON is cached for the `/compression` endpoint
