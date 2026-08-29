# socketify

socketify.py 0.0.31 on its uWebSockets bindings.

> **Disabled.** socketify's bundled `libsocketify` rejects any request whose
> request line arrives split across TCP segments, answering
> `HTTP Version Not Supported / This server does not support HTTP/1.0` instead
> of parsing it. Splitting at every byte offset, the failures are exactly the
> request line through its CRLF, while every split in the headers or body
> succeeds. `validate.sh`: 30 passed, 10 failed, all of them fragmentation —
> json, json-comp, upload and json-tls all pass.
>
> **This is specific to socketify, not to uWebSockets.** The uWebSockets.js
> entries here handle it correctly: `hyper-express` was checked against the same
> byte-offset sweep and passed all 71 splits with zero failures. And it is not
> this entry's code — a twelve-line socketify app whose only handler is
> `lambda res, req: res.end("55")` fails the same way, at offsets 4-25 of a
> 24-byte request line.
>
> Not fixable by upgrading: 0.0.31 is the newest release on PyPI, and installing
> from the (actively maintained) git HEAD ships a byte-identical
> `libsocketify_linux_amd64.so` — same md5. It needs a rebuilt native library
> from upstream.

## Stack

- **Language:** Python 3.13
- **Framework:** socketify.py 0.0.31 (uWebSockets)
- **Build:** `python:3.13-slim`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Reads the body and returns the byte count |

The same routes are served over TLS on port 8081 for `json-tls`.

## Notes

- `libuv1` is installed in the image. socketify ships a prebuilt
  `libsocketify` that links libuv at runtime, and without it the import dies
  with `libuv.so.1: cannot open shared object file`
- One process per core per port. `App.run()` blocks and TLS is configured per
  `App` through `AppOptions`, so the TLS listener needs its own processes rather
  than a second `listen` on the same app. uWS listens with SO_REUSEPORT, so the
  children share each port and the kernel balances across them
- The core count comes from the cgroup v2 quota, then the CPU affinity mask
- Request values are read out of `req` **before** the first `await`: socketify
  recycles the request object once the handler yields, so anything needed later
  has to be pulled out first
- JSON through the stdlib `json` module, serialized per request
- socketify has no response compression of its own, so `json-comp` is negotiated
  by hand and gzipped at level 1, the level the profile asks for
- The dataset is read once per worker at startup; a missing or broken file is
  not fatal and `/json` then answers with an empty list
- A missing `/certs` leaves the TLS listener unstarted rather than aborting:
  `validate.sh` mounts the directory only for entries subscribed to a TLS test
