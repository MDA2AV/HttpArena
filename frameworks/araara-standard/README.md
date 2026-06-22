# araara-standard

Experimental standard-mode HttpArena entry for araara, an OCaml 5 web stack
built on HCS and Eio.

This entry builds the same benchmark server as `frameworks/araara`, but runs it
with `HCS_ARENA_MODE=standard`. In that mode the server keeps
`Hcs.Server.default_config` values except for harness-required listener fields
such as protocol, port, TLS, and the upload profile's accepted body size.

It still uses all detected physical cores, matching the tuned entry and the
HttpArena benchmark machine.
`SO_REUSEPORT` remains enabled so each domain can bind the required ports.

The Dockerfile applies `standard-mode.patch` to the cloned HCS release before
building so this behavior is available while the tuned entry can stay pinned to
the same release.

Not implemented: HTTP/3 / QUIC, gRPC, gateway-64, and production-stack.
