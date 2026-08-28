# lwan

lwan's own coroutine HTTP server, built from source and linked as a static lib.

> **Disabled.** Two blockers, both in lwan itself rather than in this entry.
>
> - **No chunked request bodies.** `Transfer-Encoding: chunked` and `chunked`
>   do not appear anywhere in `src/lib/lwan-request.c`; lwan parses a body only
>   when there is a `Content-Length`. A chunked `POST /baseline11` answers
>   `400 Bad request`. `validate.sh` sends chunked bodies in four places — the
>   baseline chunked check, the chunked upload check, and the `POST, chunked`
>   and `POST, chunked in two chunks` fragmentation shapes — so this cannot pass.
> - **POST bodies stay capped.** The upload profile posts 20 MB. lwan's default
>   is `10 * DEFAULT_BUFFER_SIZE`; setting `max_post_data_size` (a documented
>   config key, and accepted below its 128 MiB ceiling) in `lwan.conf` did not
>   raise it — a 500 KB `Content-Length` upload is still answered
>   `Request too large`, with the `site` block from the same file demonstrably
>   in effect since the routes resolve.
>
> `json-tls` is additionally out of reach: lwan's TLS is Linux kTLS with an
> mbedTLS **1.2** handshake behind the off-by-default `ENABLE_TLS`, and the
> profile requires TLS 1.3. That is why `json-tls` is absent from `tests` rather
> than merely failing.

## Stack

- **Language:** C (gnu11), GCC
- **Framework:** lwan, built from source, linked from `liblwan.a`
- **Build:** `debian:trixie-slim`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET/POST | Sums query parameter values, plus the body on POST |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Returns the body byte count |

## Notes

- Linked with `-Wl,--whole-archive`. lwan registers its modules and handlers into
  custom linker sections, and the `__start_`/`__stop_` boundary symbols only
  exist if something contributes to them. Archive members are pulled in on
  reference alone, so without it the link fails on `undefined reference to
  __start_lwan_module`
- The clone is not `--depth 1`: lwan's cmake runs `git describe`, which aborts
  with "No names found" when no tags are present
- Routes come from `lwan.conf`, written by the entrypoint at startup
- `/json/` is a prefix route; lwan leaves the remainder of the path in
  `request->url`, which is where `{count}` is read from
- Query parameters are iterated with `LWAN_ARRAY_FOREACH` over
  `lwan_request_get_query_params()`; the raw body comes from
  `lwan_request_get_request_body()`
- The dataset is parsed at startup by a small reader in this entry. lwan ships
  no JSON parser, and the response is built directly into the lwan string buffer
- `parse_long` had to be renamed: it collides with a symbol lwan already exports
