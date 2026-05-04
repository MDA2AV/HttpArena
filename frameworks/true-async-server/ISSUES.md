# Known Issues — true-async-server (alpha.3)

Tested against `trueasync/php-true-async:0.7.0-alpha.3-php8.6`.  
Test suite: `frameworks/true-async-server/test/validate.sh`  
Result: **34 / 38 passed**.

---

## Passing test groups

| Group | Tests |
|---|---|
| baseline HTTP/1.1 (GET, POST, chunked POST) | ✅ |
| baseline TCP fragmentation — GET only | ✅ 2/4 |
| pipelined | ✅ |
| json processing | ✅ |
| upload | ✅ |
| static files | ✅ |
| async-db (PostgreSQL) | ✅ |
| baseline-h2 (HTTPS + HTTP/2) | ✅ |
| static-h2 | ✅ |
| json-tls (HTTPS + HTTP/1.1 TLS) | ✅ |

---

## Failing tests (4)

### 1. HTTP/1.1 body not fully buffered on fragmented POST

**Tests:**
- `POST split headers/body` — headers in one TCP segment, body `"20"` in a second
- `POST split body bytes` — headers in one TCP segment, body split into `"2"` + `"0"`

**Observed behaviour:**
```
FAIL [POST split headers/body]:  expected='75' got='57'
FAIL [POST split body bytes]:    expected='75' got='55'
```

`57 = 13 + 42 + 2` — the server read only the first byte `"2"` of the two-byte body `"20"`.  
`55 = 13 + 42 + 0` — the server read no body bytes at all when they arrived in two separate writes.

**Root cause:**  
`HttpRequest::getBody()` appears to return whatever bytes are present in the receive buffer at the moment of the call instead of waiting until `Content-Length` bytes have accumulated. When the request body arrives in a separate TCP segment after the headers, the handler coroutine is dispatched before the body bytes land in the buffer, and `getBody()` returns a partial (or empty) string.

**HTTP/2 is not affected** — HTTP/2 frames the body before dispatching, so `getBody()` is always complete.

**Suggested fix (server-level):**  
`getBody()` must block / yield until `Content-Length` bytes have been fully received from the socket before returning control to the handler.

---

### 2. Spорadic empty responses during server startup (race condition)

**Tests (intermittent):**
- `GET /baseline11 random a=… b=…`
- `POST /baseline11 random body=…`

**Observed behaviour:**
```
FAIL [GET /baseline11 random a=372 b=922]: expected='1294' got=''
FAIL [POST /baseline11 random body=346]:   expected='401'  got=''
```
The same requests succeed when sent against a server that has been running for several seconds.

**Server log (concurrent with failures):**
```
Warning: Attempt to finalize a coroutine that is still in the queue in Unknown on line 0
```

**Root cause:**  
When `ThreadPool` starts 16 workers simultaneously, their event-loop initialisation coroutines overlap with early incoming requests. The lifecycle management in `alpha.3` occasionally finalises a request-handler coroutine while it is still enqueued, causing the connection to be closed without a response.

The issue is transient: workers stabilise after a few seconds and subsequent identical requests succeed. A 20-request warm-up + 1 s sleep was added to `validate.sh` to reduce the window, but under low-latency Docker networks the race can still be triggered.

**Suggested fix (server-level):**  
Ensure that per-worker event-loop initialisation is fully complete (all coroutines flushed) before the first `accept()` call is made, or guard against finalising a coroutine that has not yet been dequeued.

**Workaround (application-level):**  
Set `WORKERS=1` or `WORKERS=2` via environment variable for integration testing; the race disappears with a single worker.

---

## Fixes applied in this integration

| Issue | Fix |
|---|---|
| `async-db` → HTTP 500 "Class PostgreSQL not found" | `PostgreSQL.php` is now `require`-d inside each per-thread closure; every worker thread has its own PHP class table |
| `check_header` using `curl -I` failing with newer curl | Replaced `-sI` with `-D - -o /dev/null` to dump headers without changing the HTTP method |
| Validator failures immediately after Docker Compose start | Added 20-request warm-up loop + `sleep 1` in `validate.sh` |
| `\r\n` literals not decoded to real CRLF in fragmented-TCP tests | Fixed bash→Python escaping: `'\\\\r'` in the `-c "…"` string becomes `'\\r'` in Python source, correctly replacing literal `\r` with CR |
