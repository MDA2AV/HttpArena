#!/usr/bin/env bash
# Validation suite for true-async-server — runs inside the 'validator' service.
#
# Environment (set by docker-compose.yml):
#   SERVER      hostname of the server service  (default: server)
#   HTTP_PORT   plain HTTP port                 (default: 8080)
#   HTTPS_PORT  TLS port for HTTP/2 + TLS       (default: 8443)

set -uo pipefail   # -e intentionally omitted — arithmetic would kill the script

SERVER="${SERVER:-server}"
HTTP_PORT="${HTTP_PORT:-8080}"
HTTPS_PORT="${HTTPS_PORT:-8443}"

H1="http://${SERVER}:${HTTP_PORT}"
TLS="https://${SERVER}:${HTTPS_PORT}"

PASS=0
FAIL=0

# ── helpers ──────────────────────────────────────────────────────────────────

ok()   { echo "  PASS [$1]"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL [$1]: $2"; FAIL=$((FAIL + 1)); }

# check <label> <expected-body> [curl-args...]
check() {
    local lbl="$1" exp="$2"; shift 2
    local got
    got=$(curl -s --max-time 10 "$@" 2>/dev/null || true)
    [[ "$got" == "$exp" ]] && ok "$lbl" || fail "$lbl" "expected='$exp' got='${got:0:120}'"
}

# check_status <label> <expected-code> [curl-args...]
check_status() {
    local lbl="$1" exp="$2"; shift 2
    local got
    got=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "$@" 2>/dev/null || true)
    [[ "$got" == "$exp" ]] && ok "$lbl" || fail "$lbl" "expected HTTP $exp got $got"
}

# check_header <label> <header-name> <expected-prefix> [curl-args...]
# Uses -D - to dump headers without changing the HTTP method (avoids curl
# refusing to combine --head with --data on newer curl versions).
check_header() {
    local lbl="$1" hname="$2" exp="$3"; shift 3
    local got
    got=$(curl -s --max-time 10 -D - -o /dev/null "$@" 2>/dev/null \
          | grep -i "^${hname}:" | head -1 | tr -d '\r' | sed 's/^[^:]*: *//')
    echo "$got" | grep -qi "^${exp}" && ok "$lbl ($got)" || fail "$lbl" "expected $hname~'$exp' got='$got'"
}

# check_json <label> <url> <expected-count> <mult>
# Verifies: count matches, every item has 'total', total == price*qty*mult
check_json() {
    local lbl="$1" url="$2" expected_count="$3" m="$4"
    local resp result
    resp=$(curl -sk --max-time 10 "$url" 2>/dev/null || true)
    result=$(python3 -c "
import sys, json
resp, expected_count, m = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    d = json.loads(resp)
except Exception as e:
    print('FAIL parse:', e); sys.exit(0)
count  = d.get('count', 0)
items  = d.get('items', [])
ht = all('total' in i for i in items) if items else False
ct = all(abs(i.get('total',0) - i['price'] * i['quantity'] * m) < 0.01 for i in items) if items else False
if count == expected_count and ht and ct:
    print('PASS')
else:
    print(f'FAIL count={count}/{expected_count} has_total={ht} totals_ok={ct}')
" "$resp" "$expected_count" "$m" 2>/dev/null || echo "FAIL python3 error")
    [[ "$result" == "PASS" ]] && ok "$lbl" || fail "$lbl" "$result"
}

# check_asyncdb <label> <url> <expected-count>
check_asyncdb() {
    local lbl="$1" url="$2" expected_count="$3"
    local resp result
    resp=$(curl -s --max-time 15 "$url" 2>/dev/null || true)
    result=$(python3 -c "
import sys, json
resp, expected_count = sys.argv[1], int(sys.argv[2])
try:
    d = json.loads(resp)
except Exception as e:
    print('FAIL parse:', e); sys.exit(0)
count  = d.get('count', 0)
items  = d.get('items', [])
hr = all('rating' in i and 'score' in i['rating'] for i in items) if items else True
ht = all(isinstance(i.get('tags'), list) for i in items) if items else True
ha = all(isinstance(i.get('active'), bool) for i in items) if items else True
if count == expected_count and hr and ht and ha:
    print('PASS')
else:
    print(f'FAIL count={count}/{expected_count} rating={hr} tags={ht} active={ha}')
" "$resp" "$expected_count" 2>/dev/null || echo "FAIL python3 error")
    [[ "$result" == "PASS" ]] && ok "$lbl" || fail "$lbl" "$result"
}

# check_fragmented <label> <expected-body> <frag1> [frag2 ...]
# Fragments may contain literal \r\n — python decodes them to actual CRLF.
check_fragmented() {
    local lbl="$1" exp="$2"; shift 2
    local result
    result=$(python3 -c "
import sys, socket, time
host, port = sys.argv[1], int(sys.argv[2])
frags = sys.argv[3:]
try:
    s = socket.create_connection((host, port), timeout=5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    for frag in frags:
        decoded = frag.replace('\\\\r', '\r').replace('\\\\n', '\n')
        try:
            s.sendall(decoded.encode('latin-1'))
        except OSError:
            break
        time.sleep(0.02)
    try:
        s.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    data = b''
    while True:
        try:
            chunk = s.recv(4096)
        except OSError:
            break
        if not chunk: break
        data += chunk
    s.close()
    _, _, body = data.partition(b'\r\n\r\n')
    print(body.decode('utf-8', errors='replace').rstrip())
except Exception as e:
    print(f'ERROR: {e}')
" "$SERVER" "$HTTP_PORT" "$@" 2>/dev/null || echo "ERROR python3")
    [[ "$result" == "$exp" ]] && ok "$lbl" || fail "$lbl" "expected='$exp' got='${result:0:80}'"
}

# ── warm-up ───────────────────────────────────────────────────────────────────
# All worker threads start concurrently; give them a moment to fully
# initialise before running tests that would race against startup coroutines.

echo "=== warming up server ==="
for _i in $(seq 1 20); do
    curl -sf --max-time 3 "$H1/pipeline" >/dev/null 2>&1 || true
done
sleep 1

# ── tests ─────────────────────────────────────────────────────────────────────

echo "=== baseline (HTTP/1.1) ==="

check "GET /baseline11?a=13&b=42"           "55" "$H1/baseline11?a=13&b=42"
check "POST /baseline11?a=13&b=42 body=20"  "75" \
    -X POST -H "Content-Type: text/plain" -d "20" "$H1/baseline11?a=13&b=42"
check "POST /baseline11 chunked body=20"    "75" \
    -X POST -H "Content-Type: text/plain" -H "Transfer-Encoding: chunked" -d "20" \
    "$H1/baseline11?a=13&b=42"
check_header "baseline Content-Type" "Content-Type" "text/plain" "$H1/baseline11?a=1&b=2"

A=$((RANDOM % 900 + 100)); B=$((RANDOM % 900 + 100))
check "GET /baseline11 random a=$A b=$B"   "$((A+B))"      "$H1/baseline11?a=$A&b=$B"
BODY=$((RANDOM % 900 + 100))
check "POST /baseline11 random body=$BODY" "$((13+42+BODY))" \
    -X POST -H "Content-Type: text/plain" -d "$BODY" "$H1/baseline11?a=13&b=42"

echo "=== baseline TCP fragmentation ==="

check_fragmented "split request line" "55" \
    "GET /baseli" \
    "ne11?a=13&b=42 HTTP/1.1\r\nHost: ${SERVER}\r\nConnection: close\r\n\r\n"

check_fragmented "split before headers" "55" \
    "GET /baseline11?a=13&b=42 HTTP/1.1\r\n" \
    "Host: ${SERVER}\r\nConnection: close\r\n\r\n"

check_fragmented "POST split headers/body" "75" \
    "POST /baseline11?a=13&b=42 HTTP/1.1\r\nHost: ${SERVER}\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\n" \
    "20"

check_fragmented "POST split body bytes" "75" \
    "POST /baseline11?a=13&b=42 HTTP/1.1\r\nHost: ${SERVER}\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\n" \
    "2" "0"

echo "=== pipelined ==="

check        "GET /pipeline"          "ok" "$H1/pipeline"
check_header "pipeline Content-Type"  "Content-Type" "text/plain" "$H1/pipeline"

echo "=== json processing ==="

for jp in "12:3" "22:7" "31:2" "50:5"; do
    jcount="${jp%%:*}"; jm="${jp##*:}"
    check_json "json/$jcount?m=$jm" "$H1/json/$jcount?m=$jm" "$jcount" "$jm"
done
check_header "json Content-Type" "Content-Type" "application/json" "$H1/json/50?m=1"

echo "=== upload ==="

check "POST /upload 10 bytes" "10" \
    -X POST -H "Content-Type: application/octet-stream" -d "0123456789" "$H1/upload"
check "POST /upload 0 bytes"  "0" \
    -X POST -H "Content-Type: application/octet-stream" -d "" "$H1/upload"
check_header "upload Content-Type" "Content-Type" "text/plain" \
    -X POST -d "x" "$H1/upload"

echo "=== static files ==="

check_status "GET /static/app.js 200"       "200" "$H1/static/app.js"
check_status "GET /static/nonexistent 404"  "404" "$H1/static/nonexistent.txt"
check_header "static Content-Type js"       "Content-Type" "\(text\|application\)/javascript" "$H1/static/app.js"

echo "=== sqlite-db ==="

# sqlite-db uses LIMIT 50 hardcoded; count varies by range hit, just verify
# response shape and headers.
sqlite_resp=$(curl -s --max-time 10 "$H1/sqlite-db?min=10&max=50" 2>/dev/null || true)
sqlite_ok=$(python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception as e:
    print('FAIL parse:', e); sys.exit(0)
items = d.get('items', [])
hr = all('rating' in i and 'score' in i['rating'] for i in items) if items else True
ht = all(isinstance(i.get('tags'), list) for i in items) if items else True
ha = all(isinstance(i.get('active'), bool) for i in items) if items else True
if isinstance(d.get('count'), int) and hr and ht and ha:
    print('PASS')
else:
    print(f'FAIL rating={hr} tags={ht} active={ha}')
" "$sqlite_resp" 2>/dev/null || echo "FAIL python3 error")
[[ "$sqlite_ok" == "PASS" ]] && ok "sqlite-db response shape" || fail "sqlite-db" "$sqlite_ok"

check_header "sqlite-db Content-Type" "Content-Type" "application/json" \
    "$H1/sqlite-db?min=10&max=50"

empty_sqlite=$(curl -s --max-time 10 "$H1/sqlite-db?min=99999&max=99999" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',-1))" 2>/dev/null || echo "-1")
[[ "$empty_sqlite" == "0" ]] \
    && ok "sqlite-db empty range → count=0" \
    || fail "sqlite-db empty range" "expected count=0 got $empty_sqlite"

echo "=== async-db (PostgreSQL) ==="

check_asyncdb "async-db limit=7"  "$H1/async-db?min=5&max=80&limit=7"     7
check_asyncdb "async-db limit=18" "$H1/async-db?min=20&max=150&limit=18"  18
check_asyncdb "async-db limit=33" "$H1/async-db?min=100&max=400&limit=33" 33
check_asyncdb "async-db limit=50" "$H1/async-db?min=10&max=50&limit=50"   50
check_header  "async-db Content-Type" "Content-Type" "application/json" \
    "$H1/async-db?min=10&max=50&limit=50"

empty_count=$(curl -s --max-time 10 "$H1/async-db?min=9999&max=9999&limit=50" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',-1))" 2>/dev/null || echo "-1")
[[ "$empty_count" == "0" ]] \
    && ok "async-db empty range → count=0" \
    || fail "async-db empty range" "expected count=0 got $empty_count"

echo "=== baseline-h2 (HTTPS + HTTP/2) ==="

check "h2 GET /baseline2"            "0"  -sk --http2 "$TLS/baseline2"
check "h2 GET /baseline11?a=5&b=7"   "12" -sk --http2 "$TLS/baseline11?a=5&b=7"
check "h2 POST /baseline11 body=3"   "58" \
    -sk --http2 -X POST -H "Content-Type: text/plain" -d "3" "$TLS/baseline11?a=13&b=42"
check_header "h2 baseline Content-Type" "Content-Type" "text/plain" \
    -sk --http2 "$TLS/baseline11?a=1&b=2"

proto=$(curl -sk --http2 -o /dev/null -w "%{http_version}" "$TLS/pipeline" 2>/dev/null || true)
[[ "$proto" == "2" ]] \
    && ok "h2 protocol negotiated (HTTP/$proto)" \
    || fail "h2 protocol" "expected http/2 got $proto"

echo "=== static-h2 ==="

check_status "h2 static app.js 200"     "200" -sk --http2 "$TLS/static/app.js"
check_status "h2 static nonexist 404"   "404" -sk --http2 "$TLS/static/nonexistent.txt"

# Regression: large file over h2 + TLS exercises the flow-control loop
# past the initial h2 stream window (65535 B). Pre-fix the response
# either crashed the worker (TLS write awaited from scheduler context)
# or truncated to 65535/65536 B (no WINDOW_UPDATE → drain loop). 30
# back-to-back fresh-connection runs catches both flake patterns. app.js
# is 200 KiB; expected_size = file size from disk so the test scales if
# the asset is regenerated.
APP_JS_SIZE=$(curl -s --max-time 5 -o /dev/null -w "%{size_download}" "$H1/static/app.js" 2>/dev/null)
ok_h2_big=0
trunc_h2_big=0
other_h2_big=0
for _i in $(seq 1 30); do
    s=$(curl -sk --http2 --max-time 5 -o /dev/null -w "%{size_download}" \
            "$TLS/static/app.js" 2>/dev/null)
    if [ "$s" = "$APP_JS_SIZE" ]; then
        ok_h2_big=$((ok_h2_big + 1))
    elif [ "$s" = "65535" ] || [ "$s" = "65536" ]; then
        trunc_h2_big=$((trunc_h2_big + 1))
    else
        other_h2_big=$((other_h2_big + 1))
    fi
done
# Tolerate at most 1 transient TCP/TLS handshake failure out of 30 — the
# real regression is truncation, which must be zero.
if [ "$trunc_h2_big" = "0" ] && [ "$other_h2_big" -le 1 ]; then
    ok "h2 static large repeated (ok=$ok_h2_big trunc=$trunc_h2_big other=$other_h2_big)"
else
    fail "h2 static large repeated" \
        "ok=$ok_h2_big trunc=$trunc_h2_big other=$other_h2_big (expected size=$APP_JS_SIZE)"
fi

# Concurrent h2 streams on a single connection — exercises window
# bookkeeping under multiplexing, which is where the original truncation
# bug clustered.
docker_compose_files=""
concur_out=$(curl -sk --http2 --max-time 15 \
    -o /dev/null -w "%{http_code} %{size_download}\n" \
    "$TLS/static/app.js" \
    -o /dev/null -w "%{http_code} %{size_download}\n" \
    "$TLS/static/components.css" \
    -o /dev/null -w "%{http_code} %{size_download}\n" \
    "$TLS/static/vendor.js" 2>/dev/null)
concur_bad=$(echo "$concur_out" | awk '$1 != "200" || $2 == "0" {print}' | head -1)
if [ -z "$concur_bad" ]; then
    ok "h2 static concurrent streams ($(echo "$concur_out" | wc -l) responses)"
else
    fail "h2 static concurrent streams" "bad response: $concur_bad"
fi

echo "=== json-tls (HTTPS + HTTP/1.1 TLS) ==="

check_header "json-tls Content-Type" "Content-Type" "application/json" -sk "$TLS/json/5?m=1"
check_json   "json-tls /json/5?m=2"  "$TLS/json/5?m=2" 5 2

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════"
printf "  PASSED: %-4d  FAILED: %d\n" "$PASS" "$FAIL"
echo "══════════════════════════════════════"

[[ $FAIL -eq 0 ]]
