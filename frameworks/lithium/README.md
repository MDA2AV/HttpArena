# lithium

Lithium's header-only HTTP server on its epoll/fiber backend.

> **Disabled.** Lithium's own JSON serializer cannot express the response the
> `json` profile requires, and the standard-mode rule for that profile is that
> the framework's standard JSON serialization is what gets measured — so this
> cannot be worked around by swapping the encoder while the entry stays
> `standard`. Two separate upstream problems, both reproduced against the
> pinned single header:
>
> - **Encoding writes booleans as numbers.** `json_vector(s::active).encode()`
>   over `{true, false}` produces `[{"active":1},{"active":0}]`. The profile's
>   validator asserts `isinstance(item["active"], bool)`, and `1` decodes as an
>   int.
> - **Decoding cannot read a boolean at all.** `{"id":1,"name":"x","active":true}`
>   fails with `json error: Ill-formated value`, into a `bool` field *or* an
>   `int` one. Strings, integers, `vector<string>` and nested objects all decode
>   fine, so it is booleans specifically — which is also why the dataset would
>   not load.
>
> Enabling it would mean either an alternative JSON library and `mode: tuned`
> (which the tuned rules do allow), or upstream fixing both.

## Stack

- **Language:** C++17, GCC
- **Framework:** Lithium (single-header `lithium_http_server.hh`)
- **Build:** `debian:trixie-slim`, OpenSSL + boost-context

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET/POST | Sums query parameter values, plus the body on POST |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Reads the body and returns the byte count |

## Notes

- `/baseline11` is registered as a single ANY route rather than a `.get()` and a
  `.post()`. Lithium keys `routes_map_` on the path alone, so registering the
  second verb silently replaces the first and the other method 404s
- `json_vector(E&& element)` stores `decltype(element)`, so handing it a
  temporary leaves it holding a dangling rvalue reference and the copy is
  deleted. The schemas are function-local statics passed as lvalues
- `LI_SYMBOL` is not self-guarding — the header wraps each of its own uses in an
  `#ifndef`, and any symbol it already defines (`id`, `name`, `host`, ...) must
  be guarded the same way or it is a redefinition
- The raw query string and the request body are on `req.http_ctx`
  (`get_parameters_string()`, `read_whole_body()`), not on `http_request`
- Chunked request bodies work, including chunked `/upload`
