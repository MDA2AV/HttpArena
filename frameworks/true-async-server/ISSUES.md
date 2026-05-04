# Known Issues — true-async-server

Test suite: `frameworks/true-async-server/test/validate.sh`
Latest result against local php-true-async build (post-alpha.3 fixes): **38 / 38 passing** stably across 5 consecutive runs.

No known server bugs at this time.

---

## Status

| Group | Result |
|---|---|
| baseline HTTP/1.1 (GET, POST, chunked POST) | ✅ |
| baseline TCP fragmentation (split request line, headers, headers/body, body bytes) | ✅ |
| pipelined | ✅ |
| json processing | ✅ |
| upload | ✅ |
| static files | ✅ |
| async-db (PostgreSQL) | ✅ |
| baseline-h2 (HTTPS + HTTP/2) | ✅ |
| static-h2 | ✅ |
| json-tls (HTTPS + HTTP/1.1 TLS) | ✅ |

---

## Fixed since alpha.3

### 1. HTTP/1.1 body not fully buffered on fragmented POST — FIXED

Previously, when a POST body arrived in a separate TCP segment after the headers,
`HttpRequest::getBody()` returned partial or empty data. The handler now waits
until `Content-Length` bytes have been fully received before dispatching.

`POST split headers/body` and `POST split body bytes` now pass reliably.

### 2. Sporadic empty responses during server startup (finalize-race) — FIXED

The `Warning: Attempt to finalize a coroutine that is still in the queue`
warning no longer appears, and worker threads no longer die during early
request handling. After sustained validator runs, all 16 worker threads
remain alive and the listening socket stays bound.

---

## Build requirements (host PHP)

When running with the `docker-compose.override.yml` that mounts a locally-built
`php-src`, the host PHP build must enable the following extensions in addition
to the defaults; otherwise json/async-db/TLS endpoints return HTTP 500:

```
--enable-ctype --enable-mbstring --enable-tokenizer --enable-filter --enable-session
--with-openssl --with-pgsql --with-pdo-pgsql
```

---

## Fixes applied in this integration

| Issue | Fix |
|---|---|
| `async-db` → HTTP 500 "Class PostgreSQL not found" | `PostgreSQL.php` is now `require`-d inside each per-thread closure; every worker thread has its own PHP class table |
| `check_header` using `curl -I` failing with newer curl | Replaced `-sI` with `-D - -o /dev/null` to dump headers without changing the HTTP method |
| Validator failures immediately after Docker Compose start | Added 20-request warm-up loop + `sleep 1` in `validate.sh` |
| `\r\n` literals not decoded to real CRLF in fragmented-TCP tests | Fixed bash→Python escaping: `'\\\\r'` in the `-c "…"` string becomes `'\\r'` in Python source, correctly replacing literal `\r` with CR |
