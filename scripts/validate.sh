#!/usr/bin/env bash
set -euo pipefail

FRAMEWORK="$1"
IMAGE_NAME="httparena-${FRAMEWORK}"
CONTAINER_NAME="httparena-validate-${FRAMEWORK}"
PORT=8080
H2PORT=8443
H1TLS_PORT=8081
H2C_PORT=8082
PASS=0
FAIL=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
META_FILE="$ROOT_DIR/frameworks/$FRAMEWORK/meta.json"
CERTS_DIR="$ROOT_DIR/certs"
DATA_DIR="$ROOT_DIR/data"

PG_CONTAINER="httparena-validate-postgres"
PG_NETWORK="httparena-validate-net"

cleanup() {
    # Kill watchdog if still running
    [ -n "${WATCHDOG_PID:-}" ] && kill "$WATCHDOG_PID" 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    # Stop any multi-container compose stacks that may be running.
    # Each profile has its own compose file + project namespace.
    local cp_profile cp_compose
    for cp_profile in gateway-64 gateway-h3 production-stack; do
        if [ "$cp_profile" = "gateway-64" ]; then
            cp_compose="$ROOT_DIR/frameworks/$FRAMEWORK/compose.gateway.yml"
        else
            cp_compose="$ROOT_DIR/frameworks/$FRAMEWORK/compose.$cp_profile.yml"
        fi
        if [ -f "$cp_compose" ]; then
            CERTS_DIR="${CERTS_DIR:-$ROOT_DIR/certs}" DATA_DIR="${DATA_DIR:-$ROOT_DIR/data}" DATABASE_URL="${DATABASE_URL:-}" \
                docker compose -f "$cp_compose" -p "httparena-validate-gw-${cp_profile}-${FRAMEWORK}" down --remove-orphans 2>/dev/null || true
        fi
    done
    docker rm -f "$PG_CONTAINER" 2>/dev/null || true
    docker network rm "$PG_NETWORK" 2>/dev/null || true
}
trap cleanup EXIT

# 5-minute overall timeout
VALIDATE_TIMEOUT=${VALIDATE_TIMEOUT:-300}
( trap 'exit 0' TERM; sleep "$VALIDATE_TIMEOUT"; echo ""; echo "FAIL: Validation timed out after ${VALIDATE_TIMEOUT}s"; kill -TERM $$ 2>/dev/null ) &
WATCHDOG_PID=$!

echo "=== Validating: $FRAMEWORK ==="

# Read subscribed tests from meta.json
if [ ! -f "$META_FILE" ]; then
    echo "FAIL: meta.json not found"
    exit 1
fi
TESTS=$(python3 -c "import json; print(' '.join(json.load(open('$META_FILE'))['tests']))")
echo "[info] Subscribed tests: $TESTS"

has_test() {
    echo "$TESTS" | grep -qw "$1"
}

# Build — skip standalone build if framework only subscribes to compose profiles
# (gateway-64, gateway-h3, production-stack) and has no isolated tests.
GATEWAY_ONLY=true
for t in $TESTS; do
    case "$t" in
        gateway-64|gateway-h3|production-stack) ;;
        *) GATEWAY_ONLY=false ;;
    esac
done

if [ "$GATEWAY_ONLY" = "false" ]; then
    echo "[build] Building Docker image..."
    if [ -x "frameworks/$FRAMEWORK/build.sh" ]; then
        "frameworks/$FRAMEWORK/build.sh" || { echo "FAIL: Docker build failed"; exit 1; }
    else
        docker build --no-cache -t "$IMAGE_NAME" "frameworks/$FRAMEWORK" || { echo "FAIL: Docker build failed"; exit 1; }
    fi
fi

# Mount volumes based on subscribed tests
HARD_NOFILE=$(ulimit -Hn 2>/dev/null || echo 1048576)
# Docker --ulimit nofile rejects "unlimited"; fall back to a large numeric cap
[[ "$HARD_NOFILE" =~ ^[0-9]+$ ]] || HARD_NOFILE=1048576
if has_test "async-db" || has_test "crud" || has_test "api-4" || has_test "api-16" || has_test "gateway-64" || has_test "gateway-h3" || has_test "production-stack"; then
    docker_args=(-d --name "$CONTAINER_NAME" --network host --security-opt seccomp=unconfined
        --ulimit memlock=-1:-1 --ulimit nofile="$HARD_NOFILE:$HARD_NOFILE")
else
    docker_args=(-d --name "$CONTAINER_NAME" -p "$PORT:8080"
        --ulimit memlock=-1:-1 --ulimit nofile="$HARD_NOFILE:$HARD_NOFILE")
fi
docker_args+=(-v "$DATA_DIR/dataset.json:/data/dataset.json:ro")

needs_h2=false
if has_test "baseline-h2" || has_test "static-h2" || has_test "baseline-h3" || has_test "static-h3" || has_test "gateway-64" || has_test "gateway-h3" || has_test "production-stack"; then
    needs_h2=true
fi

needs_h1tls=false
if has_test "json-tls"; then
    needs_h1tls=true
fi

needs_h2c=false
if has_test "baseline-h2c" || has_test "json-h2c"; then
    needs_h2c=true
fi

if ($needs_h2 || $needs_h1tls) && [ -d "$CERTS_DIR" ]; then
    docker_args+=(-v "$CERTS_DIR:/certs:ro")
    $needs_h2     && docker_args+=(-p "$H2PORT:8443")
    $needs_h1tls  && docker_args+=(-p "$H1TLS_PORT:8081")
fi

# h2c uses no TLS so no certs mount needed; just expose the port.
$needs_h2c && docker_args+=(-p "$H2C_PORT:8082")

if has_test "gateway-64" || has_test "gateway-h3"; then
    docker_args+=(-v "$DATA_DIR/dataset-large.json:/data/dataset-large.json:ro")
fi

if has_test "static" || has_test "static-h2" || has_test "static-h3" || has_test "gateway-64" || has_test "gateway-h3" || has_test "production-stack"; then
    docker_args+=(-v "$DATA_DIR/static:/data/static:ro")
fi

# Allow io_uring syscalls for frameworks that need them (blocked by default seccomp)
ENGINE=$(python3 -c "import json; print(json.load(open('$META_FILE')).get('engine',''))" 2>/dev/null || true)
if [ "$ENGINE" = "io_uring" ]; then
    docker_args+=(--security-opt seccomp=unconfined)
    docker_args+=(--ulimit memlock=-1:-1)
fi

# Start Postgres sidecar if async-db is needed
if has_test "async-db" || has_test "crud" || has_test "api-4" || has_test "api-16" || has_test "gateway-64" || has_test "gateway-h3" || has_test "production-stack"; then
    echo "[postgres] Starting Postgres sidecar for validation..."
    docker rm -f "$PG_CONTAINER" 2>/dev/null || true
    docker run -d --name "$PG_CONTAINER" --network host \
        -e POSTGRES_USER=bench \
        -e POSTGRES_PASSWORD=bench \
        -e POSTGRES_DB=benchmark \
        -v "$DATA_DIR/pgdb-seed.sql:/docker-entrypoint-initdb.d/seed.sql:ro" \
        postgres:18 \
        -c max_connections=256
    for i in $(seq 1 60); do
        if docker exec "$PG_CONTAINER" pg_isready -U bench -d benchmark >/dev/null 2>&1; then
            # Ensure seed data is loaded (pg_isready fires before init scripts finish)
            if docker exec "$PG_CONTAINER" psql -U bench -d benchmark -tAc "SELECT 1 FROM items LIMIT 1" 2>/dev/null | grep -q 1; then
                echo "[postgres] Ready"
                break
            fi
        fi
        [ "$i" -eq 60 ] && { echo "FAIL: Postgres sidecar not ready"; exit 1; }
        sleep 1
    done
    docker_args+=(-e "DATABASE_URL=postgres://bench:bench@localhost:5432/benchmark")
    docker_args+=(-e "DATABASE_MAX_CONN=256")
fi

# Start container (skip for gateway-only — compose handles it later)
if [ "$GATEWAY_ONLY" = "false" ]; then
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    docker run "${docker_args[@]}" "$IMAGE_NAME"

    # Wait for server to start.
    #
    # Primary probe is GET /baseline11 over plaintext HTTP/1.1 on $PORT — that
    # works for the vast majority of frameworks, which all listen on 8080.
    # H/2-only or H/3-only frameworks (e.g. wtx, which speaks h2c on 8080 or
    # h2/h3 on 8443 depending on build) never respond to an HTTP/1.1 request
    # and would otherwise time out. Fall back to GET /baseline2 over HTTPS
    # with ALPN h2 on $H2PORT when the framework subscribes to any h2 or h3
    # profile. H/3 servers still advertise h2 on the same TLS listener via
    # ALPN, so this single fallback covers both cases without requiring
    # curl to be built with HTTP/3 support.
    need_tls_probe=false
    if has_test "baseline-h2" || has_test "static-h2" \
       || has_test "baseline-h3" || has_test "static-h3"; then
        need_tls_probe=true
    fi

    need_h2c_probe=false
    if has_test "baseline-h2c" || has_test "json-h2c"; then
        need_h2c_probe=true
    fi

    echo "[wait] Waiting for server..."
    for i in $(seq 1 30); do
        if curl -s --max-time 2 -o /dev/null -w '' "http://localhost:$PORT/baseline11?a=1&b=1" 2>/dev/null; then
            break
        fi
        if [ "$need_tls_probe" = "true" ] && \
           curl -sk --http2 --max-time 2 -o /dev/null -w '' "https://localhost:$H2PORT/baseline2?a=1&b=1" 2>/dev/null; then
            break
        fi
        if [ "$need_h2c_probe" = "true" ] && \
           curl -s --http2-prior-knowledge --max-time 2 -o /dev/null -w '' "http://localhost:$H2C_PORT/baseline2?a=1&b=1" 2>/dev/null; then
            break
        fi
        if [ "$i" -eq 30 ]; then
            echo "FAIL: Server did not start within 30s"
            exit 1
        fi
        sleep 1
    done
    echo "[ready] Server is up"
fi

# ───── Helpers ─────

DOCS_BASE="https://www.http-arena.com/docs/test-profiles"

fail_with_link() {
    local msg="$1"
    local docs_url="$2"
    echo "  FAIL $msg"
    if [ -n "$docs_url" ]; then
        echo "        → $docs_url"
    fi
    FAIL=$((FAIL + 1))
}

check() {
    local label="$1"
    local expected_body="$2"
    local docs_url="$3"
    shift 3
    local response
    response=$(curl -s --max-time 30 -D- "$@" || true)
    local body
    body=$(echo "$response" | tail -1)

    if [ "$body" = "$expected_body" ]; then
        echo "  PASS [$label]"
        PASS=$((PASS + 1))
    else
        fail_with_link "[$label]: expected body '$expected_body', got '$body'" "$docs_url"
    fi
}

check_status() {
    local label="$1"
    local expected_status="$2"
    local docs_url="$3"
    shift 3
    local http_code
    http_code=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' "$@" || true)

    if [ "$http_code" = "$expected_status" ]; then
        echo "  PASS [$label] (HTTP $http_code)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[$label]: expected HTTP $expected_status, got HTTP $http_code" "$docs_url"
    fi
}

check_fragmented() {
    # Send an HTTP request in multiple TCP writes with small pauses between
    # them so the server's read loop sees partial, incomplete buffers and
    # must reassemble across recv() calls. Exercises HTTP parser correctness
    # under realistic network fragmentation (slow clients, small MTU, etc.).
    #
    # Usage: check_fragmented <label> <expected_body> <docs_url> <frag1> <frag2> [frag3...]
    # Use $'...' literal form in the caller to embed CR/LF inside fragments.
    local label="$1"
    local expected_body="$2"
    local docs_url="$3"
    shift 3
    local body
    body=$(PORT="$PORT" python3 -c '
import os, socket, sys, time
port = int(os.environ["PORT"])
frags = sys.argv[1:]
s = socket.create_connection(("localhost", port), timeout=5)
s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)  # no Nagle coalescing
for i, f in enumerate(frags):
    s.sendall(f.encode("latin-1"))
    if i < len(frags) - 1:
        time.sleep(0.03)
buf = b""
while True:
    chunk = s.recv(4096)
    if not chunk: break
    buf += chunk
s.close()
resp = buf.decode("latin-1", errors="replace")
try:
    head, raw = resp.split("\r\n\r\n", 1)
except ValueError:
    sys.stdout.write("")
    sys.exit(0)

# Parse headers (case-insensitive)
hdrs = {}
for line in head.split("\r\n")[1:]:
    if ":" in line:
        k, v = line.split(":", 1)
        hdrs[k.strip().lower()] = v.strip()

# If the response is chunked, decode the frames; otherwise honor Content-Length
# when present, else just return the raw remaining bytes.
if hdrs.get("transfer-encoding", "").lower() == "chunked":
    parts, rest = [], raw
    while rest:
        nl = rest.find("\r\n")
        if nl < 0: break
        try:
            size = int(rest[:nl].split(";", 1)[0], 16)  # ignore chunk extensions
        except ValueError:
            break
        rest = rest[nl+2:]
        if size == 0: break
        parts.append(rest[:size])
        rest = rest[size+2:]  # skip trailing CRLF
    body = "".join(parts)
elif "content-length" in hdrs:
    try:
        body = raw[:int(hdrs["content-length"])]
    except ValueError:
        body = raw
else:
    body = raw

sys.stdout.write(body.strip())
' "$@" 2>/dev/null || echo "")

    if [ "$body" = "$expected_body" ]; then
        echo "  PASS [$label]"
        PASS=$((PASS + 1))
    else
        fail_with_link "[$label]: expected body '$expected_body', got '$body'" "$docs_url"
    fi
}

check_header() {
    local label="$1"
    local header_name="$2"
    local expected_value="$3"
    local docs_url="$4"
    shift 4
    local headers
    headers=$(curl -s --max-time 30 -D- -o /dev/null "$@" || true)
    local value
    value=$(echo "$headers" | grep -i "^${header_name}:" | sed 's/^[^:]*: *//' | tr -d '\r' || true)

    # Normalize: text/javascript and application/javascript are equivalent (RFC 9239)
    local norm_value norm_expected
    norm_value=$(echo "$value" | sed 's|text/javascript|application/javascript|')
    norm_expected=$(echo "$expected_value" | sed 's|text/javascript|application/javascript|')
    if [ "$value" = "$expected_value" ] || [[ "$value" == "$expected_value;"* ]] || [ "$norm_value" = "$norm_expected" ] || [[ "$norm_value" == "$norm_expected;"* ]]; then
        echo "  PASS [$label] ($header_name: $value)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[$label]: expected $header_name '$expected_value', got '$value'" "$docs_url"
    fi
}

wait_h2() {
    echo "[wait] Waiting for HTTPS port..."
    for i in $(seq 1 15); do
        if curl -sk --max-time 30 --http2 -o /dev/null "https://localhost:$H2PORT/baseline2?a=1&b=1" 2>/dev/null; then
            return 0
        fi
        if [ "$i" -eq 15 ]; then
            echo "  FAIL: HTTPS port $H2PORT not responding"
            FAIL=$((FAIL + 1))
            return 1
        fi
        sleep 1
    done
}

# ───── Baseline (GET/POST /baseline11) ─────

if has_test "baseline" || has_test "limited-conn" || has_test "api-4" || has_test "api-16"; then
    BASELINE_DOCS="$DOCS_BASE/h1/isolated/baseline/validation"
    echo "[test] baseline endpoints"
    check "GET /baseline11?a=13&b=42" "55" "$BASELINE_DOCS" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    check "POST /baseline11?a=13&b=42 body=20" "75" "$BASELINE_DOCS" \
        -X POST -H "Content-Type: text/plain" -d "20" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    check "POST /baseline11?a=13&b=42 chunked body=20" "75" "$BASELINE_DOCS" \
        -X POST -H "Content-Type: text/plain" -H "Transfer-Encoding: chunked" -d "20" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    # Response Content-Type must be text/plain (bare or with ;charset=…). A
    # missing header or application/json is a spec violation. Issue #526.
    check_header "GET /baseline11 Content-Type" "Content-Type" "text/plain" "$BASELINE_DOCS" \
        "http://localhost:$PORT/baseline11?a=13&b=42"
    check_header "POST /baseline11 Content-Type" "Content-Type" "text/plain" "$BASELINE_DOCS" \
        -X POST -H "Content-Type: text/plain" -d "20" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    # Anti-cheat: randomized inputs to detect hardcoded responses
    echo "[test] baseline anti-cheat (randomized inputs)"
    A1=$((RANDOM % 900 + 100))
    B1=$((RANDOM % 900 + 100))
    check "GET /baseline11?a=$A1&b=$B1 (random)" "$((A1 + B1))" "$BASELINE_DOCS" \
        "http://localhost:$PORT/baseline11?a=$A1&b=$B1"

    BODY1=$((RANDOM % 900 + 100))
    BODY2=$((RANDOM % 900 + 100))
    while [ "$BODY1" -eq "$BODY2" ]; do BODY2=$((RANDOM % 900 + 100)); done
    check "POST body=$BODY1 (cache check 1)" "$((13 + 42 + BODY1))" "$BASELINE_DOCS" \
        -X POST -H "Content-Type: text/plain" -d "$BODY1" \
        "http://localhost:$PORT/baseline11?a=13&b=42"
    check "POST body=$BODY2 (cache check 2)" "$((13 + 42 + BODY2))" "$BASELINE_DOCS" \
        -X POST -H "Content-Type: text/plain" -d "$BODY2" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    # TCP fragmentation: send each request in multiple small writes with a
    # short pause between, so the server's HTTP parser sees partial buffers
    # and must reassemble across recv() calls. Exercises parser correctness
    # under realistic network conditions (slow clients, small MTU).
    echo "[test] baseline TCP fragmentation"
    # Split 1: break the request line mid-path
    check_fragmented "GET /baseline11 — split request line" "55" "$BASELINE_DOCS" \
        "GET /baseli" \
        $'ne11?a=13&b=42 HTTP/1.1\r\n' \
        $'Host: localhost\r\nConnection: close\r\n\r\n'

    # Split 2: break between request line and headers
    check_fragmented "GET /baseline11 — split before headers" "55" "$BASELINE_DOCS" \
        $'GET /baseline11?a=13&b=42 HTTP/1.1\r\n' \
        $'Host: localhost\r\n' \
        $'User-Agent: arena-frag/1.0\r\n' \
        $'Connection: close\r\n\r\n'

    # Split 3: POST with headers and body in separate writes
    check_fragmented "POST /baseline11 — split headers/body" "75" "$BASELINE_DOCS" \
        $'POST /baseline11?a=13&b=42 HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\n' \
        "20"

    # Split 4: POST with body split across two writes (body = "20", split to "2" + "0")
    check_fragmented "POST /baseline11 — split body bytes" "75" "$BASELINE_DOCS" \
        $'POST /baseline11?a=13&b=42 HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\n' \
        "2" \
        "0"
fi

# ───── Pipelined (GET /pipeline) ─────

if has_test "pipelined"; then
    PIPELINED_DOCS="$DOCS_BASE/h1/isolated/pipelined/validation"
    echo "[test] pipelined endpoint"
    check "GET /pipeline" "ok" "$PIPELINED_DOCS" \
        "http://localhost:$PORT/pipeline"
    check_header "GET /pipeline Content-Type" "Content-Type" "text/plain" "$PIPELINED_DOCS" \
        "http://localhost:$PORT/pipeline"
fi

# ───── JSON Processing (GET /json) ─────

if has_test "json" || has_test "api-4" || has_test "api-16"; then
    JSON_DOCS="$DOCS_BASE/h1/isolated/json-processing/validation"
    echo "[test] json endpoint"
    json_fail=false
    json_params=("12:3" "22:7" "31:2" "50:5")
    for jp in "${json_params[@]}"; do
        jcount="${jp%%:*}"
        jm="${jp##*:}"
        response=$(curl -s --max-time 30 "http://localhost:$PORT/json/$jcount?m=$jm" || true)
        json_result=$(echo "$response" | python3 -c "
import sys, json
m = $jm
d = json.load(sys.stdin)
count = d.get('count', 0)
items = d.get('items', [])
has_total = all('total' in item for item in items) if items else False
correct_totals = True
for item in items:
    expected = item['price'] * item['quantity'] * m
    if item.get('total', 0) != expected:
        correct_totals = False
        break
print(f'{count} {has_total} {correct_totals}')
" 2>/dev/null || echo "0 False False")
        json_count=$(echo "$json_result" | cut -d' ' -f1)
        json_total=$(echo "$json_result" | cut -d' ' -f2)
        json_correct=$(echo "$json_result" | cut -d' ' -f3)

        if [ "$json_count" = "$jcount" ] && [ "$json_total" = "True" ] && [ "$json_correct" = "True" ]; then
            :
        else
            fail_with_link "[GET /json/$jcount?m=$jm]: count=$json_count, has_total=$json_total, correct_totals=$json_correct" "$JSON_DOCS"
            json_fail=true
        fi
    done
    if [ "$json_fail" = "false" ]; then
        echo "  PASS [GET /json/{count}?m=X] (4 counts with multipliers verified)"
        PASS=$((PASS + 1))
    fi

    # Check Content-Type header
    check_header "GET /json Content-Type" "Content-Type" "application/json" "$JSON_DOCS" \
        "http://localhost:$PORT/json/50?m=1"
fi

# ───── JSON Compressed (GET /json/{count}?m=X with Accept-Encoding) ─────

if has_test "json-comp"; then
    JSONCOMP_DOCS="$DOCS_BASE/h1/isolated/json-processing/validation"
    echo "[test] json-comp endpoint"

    # Must return Content-Encoding: gzip or br when Accept-Encoding is sent
    jc_headers=$(curl -s --max-time 30 -D- -o /dev/null -H "Accept-Encoding: gzip, br" "http://localhost:$PORT/json/50?m=1" || true)
    jc_encoding=$(echo "$jc_headers" | grep -i "^content-encoding:" | sed 's/^[^:]*: *//' | tr -d '\r' | awk '{print tolower($1)}' || true)
    if [ "$jc_encoding" = "gzip" ] || [ "$jc_encoding" = "br" ]; then
        echo "  PASS [json-comp Content-Encoding: $jc_encoding]"
        PASS=$((PASS + 1))
    else
        fail_with_link "[json-comp]: expected Content-Encoding gzip or br, got '$jc_encoding'" "$JSONCOMP_DOCS"
    fi

    # Verify compressed response with varying counts and multipliers
    jc_fail=false
    jc_params=("12:9" "31:4" "50:6")
    for jcp in "${jc_params[@]}"; do
        jccount="${jcp%%:*}"
        jcm="${jcp##*:}"
        jc_response=$(curl -s --max-time 30 --compressed -H "Accept-Encoding: gzip, br" "http://localhost:$PORT/json/$jccount?m=$jcm" || true)
        jc_result=$(echo "$jc_response" | python3 -c "
import sys, json
m = $jcm
d = json.load(sys.stdin)
count = d.get('count', 0)
items = d.get('items', [])
has_total = all('total' in item for item in items) if items else False
correct_totals = True
for item in items:
    expected = item['price'] * item['quantity'] * m
    if item.get('total', 0) != expected:
        correct_totals = False
        break
print(f'{count} {has_total} {correct_totals}')
" 2>/dev/null || echo "0 False False")
        jc_count=$(echo "$jc_result" | cut -d' ' -f1)
        jc_total=$(echo "$jc_result" | cut -d' ' -f2)
        jc_correct=$(echo "$jc_result" | cut -d' ' -f3)

        if [ "$jc_count" = "$jccount" ] && [ "$jc_total" = "True" ] && [ "$jc_correct" = "True" ]; then
            :
        else
            fail_with_link "[json-comp /json/$jccount?m=$jcm]: count=$jc_count, has_total=$jc_total, correct=$jc_correct" "$JSONCOMP_DOCS"
            jc_fail=true
        fi
    done
    if [ "$jc_fail" = "false" ]; then
        echo "  PASS [json-comp response] (3 counts with multipliers, compressed)"
        PASS=$((PASS + 1))
    fi

    # Without Accept-Encoding must NOT return Content-Encoding
    jc_no_enc=$(curl -s --max-time 30 -D- -o /dev/null "http://localhost:$PORT/json/50?m=1" | grep -i "^content-encoding:" | tr -d '\r' || true)
    if [ -z "$jc_no_enc" ]; then
        echo "  PASS [json-comp per-request] (no Content-Encoding without Accept-Encoding)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[json-comp per-request]: got $jc_no_enc without Accept-Encoding" "$JSONCOMP_DOCS"
    fi
fi

# ───── JSON TLS (GET /json/{count}?m=X over HTTP/1.1 + TLS on :8081) ─────

if has_test "json-tls"; then
    JSONTLS_DOCS="$DOCS_BASE/h1/isolated/json-tls/validation"
    echo "[test] json-tls endpoint"

    # Must negotiate HTTP/1.1 (not h2) via ALPN on :8081
    jt_proto=$(curl -sk --max-time 30 --http1.1 -o /dev/null -w '%{http_version}' "https://localhost:$H1TLS_PORT/json/1?m=1" 2>/dev/null || echo "0")
    if [ "$jt_proto" = "1.1" ]; then
        echo "  PASS [json-tls protocol negotiation] (HTTP/$jt_proto over TLS)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[json-tls protocol negotiation]: expected 1.1, got HTTP/$jt_proto" "$JSONTLS_DOCS"
    fi

    # Response body correctness across 3 (count, m) pairs (different from json-comp so a caller can't share state)
    jt_fail=false
    jt_params=("7:2" "23:11" "50:1")
    for jtp in "${jt_params[@]}"; do
        jtcount="${jtp%%:*}"
        jtm="${jtp##*:}"
        jt_response=$(curl -sk --max-time 30 "https://localhost:$H1TLS_PORT/json/$jtcount?m=$jtm" || true)
        jt_result=$(echo "$jt_response" | python3 -c "
import sys, json
m = $jtm
d = json.load(sys.stdin)
count = d.get('count', 0)
items = d.get('items', [])
has_total = all('total' in item for item in items) if items else False
correct_totals = True
for item in items:
    expected = item['price'] * item['quantity'] * m
    if item.get('total', 0) != expected:
        correct_totals = False
        break
print(f'{count} {has_total} {correct_totals}')
" 2>/dev/null || echo "0 False False")
        jt_count=$(echo "$jt_result" | cut -d' ' -f1)
        jt_total=$(echo "$jt_result" | cut -d' ' -f2)
        jt_correct=$(echo "$jt_result" | cut -d' ' -f3)

        if [ "$jt_count" = "$jtcount" ] && [ "$jt_total" = "True" ] && [ "$jt_correct" = "True" ]; then
            :
        else
            fail_with_link "[json-tls /json/$jtcount?m=$jtm]: count=$jt_count, has_total=$jt_total, correct=$jt_correct" "$JSONTLS_DOCS"
            jt_fail=true
        fi
    done
    if [ "$jt_fail" = "false" ]; then
        echo "  PASS [json-tls response] (3 (count, m) pairs over TLS)"
        PASS=$((PASS + 1))
    fi

    # Content-Type must be application/json
    jt_ct=$(curl -sk --max-time 30 -D- -o /dev/null "https://localhost:$H1TLS_PORT/json/1?m=1" | grep -i "^content-type:" | tr -d '\r' || true)
    if echo "$jt_ct" | grep -qi 'application/json'; then
        echo "  PASS [json-tls Content-Type: application/json]"
        PASS=$((PASS + 1))
    else
        fail_with_link "[json-tls Content-Type]: expected application/json, got '$jt_ct'" "$JSONTLS_DOCS"
    fi
fi

# ───── Upload (POST /upload) ─────

if has_test "upload"; then
    UPLOAD_DOCS="$DOCS_BASE/h1/isolated/upload/validation"
    echo "[test] upload endpoint"
    # Small upload: returns byte count
    UPLOAD_BODY="Hello, HttpArena!"
    EXPECTED_LEN=${#UPLOAD_BODY}
    check "POST /upload small body" "$EXPECTED_LEN" "$UPLOAD_DOCS" \
        -X POST -H "Content-Type: application/octet-stream" --data-binary "$UPLOAD_BODY" \
        "http://localhost:$PORT/upload"

    # Anti-cheat: random body to detect hardcoded responses
    RANDOM_BODY=$(head -c 64 /dev/urandom | base64 | head -c 48)
    EXPECTED_RANDOM_LEN=${#RANDOM_BODY}
    ACTUAL_LEN=$(curl -s --max-time 30 -X POST -H "Content-Type: application/octet-stream" --data-binary "$RANDOM_BODY" "http://localhost:$PORT/upload" || true)
    if [ "$ACTUAL_LEN" = "$EXPECTED_RANDOM_LEN" ]; then
        echo "  PASS [POST /upload random body] (bytes: $ACTUAL_LEN)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[POST /upload random body]: expected '$EXPECTED_RANDOM_LEN', got '$ACTUAL_LEN'" "$UPLOAD_DOCS"
    fi

    # Varying upload sizes
    upload_fail=false
    for upload_spec in "500K:512000" "2M:2097152" "10M:10485760" "20M:20971520"; do
        upload_label="${upload_spec%%:*}"
        upload_size="${upload_spec##*:}"
        upload_bs=$((upload_size / 1024))
        ACTUAL_LARGE=$( { dd if=/dev/urandom bs=1024 count=$upload_bs 2>/dev/null | curl -s --max-time 60 -X POST -H "Content-Type: application/octet-stream" --data-binary @- "http://localhost:$PORT/upload"; } || true )
        if [ "$ACTUAL_LARGE" = "$upload_size" ]; then
            :
        else
            fail_with_link "[POST /upload $upload_label]: expected '$upload_size', got '$ACTUAL_LARGE'" "$UPLOAD_DOCS"
            upload_fail=true
        fi
    done
    if [ "$upload_fail" = "false" ]; then
        echo "  PASS [POST /upload] (4 sizes verified: 500K, 2M, 10M, 20M)"
        PASS=$((PASS + 1))
    fi
fi

# ───── Baseline H2 (GET /baseline2 over HTTP/2 + TLS) ─────

if has_test "baseline-h2"; then
    H2_DOCS="$DOCS_BASE/h2/baseline-h2/validation"
    echo "[test] baseline-h2 endpoint"
    if wait_h2; then
        # Verify server actually speaks HTTP/2
        h2_proto=$(curl -sk --max-time 30 --http2 -o /dev/null -w '%{http_version}' "https://localhost:$H2PORT/baseline2?a=1&b=1" || echo "0")
        if [ "$h2_proto" = "2" ]; then
            echo "  PASS [HTTP/2 protocol negotiation] (HTTP/$h2_proto)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[HTTP/2 protocol negotiation]: server responded with HTTP/$h2_proto" "$H2_DOCS"
        fi

        check "GET /baseline2?a=13&b=42 over HTTP/2" "55" "$H2_DOCS" \
            -sk --http2 "https://localhost:$H2PORT/baseline2?a=13&b=42"

        # Anti-cheat: randomized query params
        A3=$((RANDOM % 900 + 100))
        B3=$((RANDOM % 900 + 100))
        check "GET /baseline2?a=$A3&b=$B3 over HTTP/2 (random)" "$((A3 + B3))" "$H2_DOCS" \
            -sk --http2 "https://localhost:$H2PORT/baseline2?a=$A3&b=$B3"

        check_header "GET /baseline2 Content-Type" "Content-Type" "text/plain" "$H2_DOCS" \
            -sk --http2 "https://localhost:$H2PORT/baseline2?a=1&b=1"
    fi
fi

# ───── Baseline H2c (GET /baseline2 over HTTP/2 cleartext, prior-knowledge) ─────

if has_test "baseline-h2c"; then
    H2C_DOCS="$DOCS_BASE/h2/baseline-h2c/validation"
    echo "[test] baseline-h2c endpoint"

    # Wait briefly for the h2c listener to be up — the main probe waited on
    # :8080 or :8443, not :8082. One shot with a short timeout is enough
    # because the container has already been up for the earlier tests.
    for i in $(seq 1 10); do
        if curl -s --http2-prior-knowledge --max-time 2 -o /dev/null \
             "http://localhost:$H2C_PORT/baseline2?a=1&b=1" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    # Anti-cheat #1: require HTTP/2 on the wire. Forces prior-knowledge so
    # a server that naively accepts an HTTP/1.1 request on the same port
    # can't pass by answering plain h1 — %{http_version} reports the actual
    # negotiated protocol.
    h2c_proto=$(curl -s --max-time 30 --http2-prior-knowledge \
        -o /dev/null -w '%{http_version}' \
        "http://localhost:$H2C_PORT/baseline2?a=1&b=1" 2>/dev/null || echo "0")
    if [ "$h2c_proto" = "2" ]; then
        echo "  PASS [HTTP/2 cleartext (prior-knowledge)] (HTTP/$h2c_proto)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[HTTP/2 cleartext (prior-knowledge)]: server responded with HTTP/$h2c_proto, expected HTTP/2" "$H2C_DOCS"
    fi

    # Anti-cheat #2: the same port MUST NOT also serve HTTP/1.1. If it did,
    # the benchmark could be measuring h1 throughput (much higher on some
    # stacks) while labeled as h2c. --http1.1 forces curl to refuse the
    # h2 preface; we check that the server didn't happily answer.
    h1_code=$(curl -s --max-time 5 --http1.1 \
        -o /dev/null -w '%{http_code}' \
        "http://localhost:$H2C_PORT/baseline2?a=1&b=1" 2>/dev/null || echo "000")
    if [ "$h1_code" != "200" ]; then
        echo "  PASS [h2c-only: port $H2C_PORT rejects plain HTTP/1.1] (got $h1_code)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[h2c-only]: port $H2C_PORT also answered HTTP/1.1 with 200 — dual-serving lets the benchmark measure h1 throughput instead of h2c. The h2c listener must refuse HTTP/1.1 requests." "$H2C_DOCS"
    fi

    check "GET /baseline2?a=13&b=42 over h2c" "55" "$H2C_DOCS" \
        -s --http2-prior-knowledge "http://localhost:$H2C_PORT/baseline2?a=13&b=42"

    # Anti-cheat #3: randomized sum
    A4=$((RANDOM % 900 + 100))
    B4=$((RANDOM % 900 + 100))
    check "GET /baseline2?a=$A4&b=$B4 over h2c (random)" "$((A4 + B4))" "$H2C_DOCS" \
        -s --http2-prior-knowledge "http://localhost:$H2C_PORT/baseline2?a=$A4&b=$B4"

    check_header "GET /baseline2 Content-Type (h2c)" "Content-Type" "text/plain" "$H2C_DOCS" \
        -s --http2-prior-knowledge "http://localhost:$H2C_PORT/baseline2?a=1&b=1"
fi

# ───── JSON H2c (GET /json/{count}?m=M over HTTP/2 cleartext) ─────

if has_test "json-h2c"; then
    JSON_H2C_DOCS="$DOCS_BASE/h2/json-h2c/validation"
    echo "[test] json-h2c endpoint"

    # Still re-assert HTTP/2 on the wire for the /json path specifically —
    # a server could in theory route /baseline2 through h2c and /json
    # through an h1 fallback handler.
    h2c_json_proto=$(curl -s --max-time 30 --http2-prior-knowledge \
        -o /dev/null -w '%{http_version}' \
        "http://localhost:$H2C_PORT/json/1?m=1" 2>/dev/null || echo "0")
    if [ "$h2c_json_proto" = "2" ]; then
        echo "  PASS [/json HTTP/2 cleartext] (HTTP/$h2c_json_proto)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[/json HTTP/2 cleartext]: server responded with HTTP/$h2c_json_proto on /json" "$JSON_H2C_DOCS"
    fi

    check_header "GET /json Content-Type (h2c)" "Content-Type" "application/json" "$JSON_H2C_DOCS" \
        -s --http2-prior-knowledge "http://localhost:$H2C_PORT/json/1?m=1"

    # Same (count, m) validator as the h1 json profile — count field must
    # match and items.length equals count. Uses 4 distinct pairs that
    # differ from the benchmark rotation so caching-by-key gets punished.
    json_h2c_fail=false
    for jp in "12:3" "22:7" "31:2" "50:5"; do
        jcount="${jp%%:*}"
        jm="${jp##*:}"
        resp=$(curl -s --max-time 30 --http2-prior-knowledge \
            "http://localhost:$H2C_PORT/json/$jcount?m=$jm" 2>/dev/null || true)
        parsed=$(echo "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = d.get('count', -1)
items_n = len(d.get('items', []))
print(f'{count} {items_n}')
" 2>/dev/null || echo "-1 -1")
        pc=$(echo "$parsed" | cut -d' ' -f1)
        pn=$(echo "$parsed" | cut -d' ' -f2)
        if [ "$pc" = "$jcount" ] && [ "$pn" = "$jcount" ]; then
            :
        else
            fail_with_link "[GET /json/$jcount?m=$jm (h2c)]: count=$pc, items=$pn, expected $jcount" "$JSON_H2C_DOCS"
            json_h2c_fail=true
        fi
    done
    if [ "$json_h2c_fail" = "false" ]; then
        echo "  PASS [GET /json/{count}?m=X over h2c] (4 counts verified)"
        PASS=$((PASS + 1))
    fi
fi

# ───── Static Files H1 (GET /static/* over HTTP/1.1) ─────

if has_test "static"; then
    STATIC_DOCS="$DOCS_BASE/h1/isolated/static/validation"
    echo "[test] static endpoint"
    check_header "GET /static/reset.css Content-Type" "Content-Type" "text/css" "$STATIC_DOCS" \
        -s "http://localhost:$PORT/static/reset.css"

    check_header "GET /static/app.js Content-Type" "Content-Type" "application/javascript" "$STATIC_DOCS" \
        -s "http://localhost:$PORT/static/app.js"

    check_header "GET /static/manifest.json Content-Type" "Content-Type" "application/json" "$STATIC_DOCS" \
        -s "http://localhost:$PORT/static/manifest.json"

    # Verify file sizes match actual files on disk
    static_fail=false
    for sf in reset.css layout.css theme.css components.css utilities.css analytics.js helpers.js app.js vendor.js router.js header.html footer.html regular.woff2 bold.woff2 logo.svg icon-sprite.svg hero.webp thumb1.webp thumb2.webp manifest.json; do
        expected_size=$(wc -c < "$DATA_DIR/static/$sf" 2>/dev/null || echo "0")
        actual_size=$(curl -s --max-time 30 -o /dev/null -w '%{size_download}' "http://localhost:$PORT/static/$sf" || echo "0")
        if [ "$actual_size" -eq "$expected_size" ] 2>/dev/null; then
            true
        else
            fail_with_link "[static/$sf size]: expected $expected_size bytes, got $actual_size" "$STATIC_DOCS"
            static_fail=true
        fi
    done
    if [ "$static_fail" = "false" ]; then
        echo "  PASS [static file sizes] (20 files verified)"
        PASS=$((PASS + 1))
    fi

    # Verify compression works when Accept-Encoding is sent — for each file, if server compresses, decompressed size must match original
    static_comp_fail=false
    static_comp_count=0
    static_comp_skip=0
    for sf in reset.css layout.css theme.css components.css utilities.css analytics.js helpers.js app.js vendor.js router.js header.html footer.html regular.woff2 bold.woff2 logo.svg icon-sprite.svg hero.webp thumb1.webp thumb2.webp manifest.json; do
        expected_size=$(wc -c < "$DATA_DIR/static/$sf" 2>/dev/null || echo "0")
        _hdr_tmp=$(mktemp)
        _body_tmp=$(mktemp)
        curl -s --max-time 30 --compressed -D "$_hdr_tmp" -o "$_body_tmp" "http://localhost:$PORT/static/$sf" || true
        comp_enc=$(grep -i "^content-encoding:" "$_hdr_tmp" | sed 's/^[^:]*: *//' | tr -d '\r' | awk '{print tolower($1)}' || true)
        decompressed=$(wc -c < "$_body_tmp")
        rm -f "$_hdr_tmp" "$_body_tmp"
        if [ -n "$comp_enc" ]; then
            if [ "$decompressed" -eq "$expected_size" ] 2>/dev/null; then
                static_comp_count=$((static_comp_count + 1))
            else
                fail_with_link "[static/$sf compression]: Content-Encoding: $comp_enc but decompressed size $decompressed != expected $expected_size" "$STATIC_DOCS"
                static_comp_fail=true
            fi
        else
            static_comp_skip=$((static_comp_skip + 1))
        fi
    done
    if [ "$static_comp_fail" = "false" ]; then
        if [ "$static_comp_count" -gt 0 ]; then
            echo "  PASS [static compression] ($static_comp_count files compressed, $static_comp_skip skipped)"
            PASS=$((PASS + 1))
        else
            echo "  SKIP [static compression] (server does not compress static files)"
        fi
    fi

    check_status "GET /static/nonexistent.txt" "404" "$STATIC_DOCS" \
        -s "http://localhost:$PORT/static/nonexistent.txt"
fi


# ───── Static Files H2 (GET /static/* over HTTP/2 + TLS) ─────

if has_test "static-h2"; then
    STATIC_H2_DOCS="$DOCS_BASE/h2/static-h2/validation"
    echo "[test] static-h2 endpoint"
    if wait_h2; then
        # Check a few static files exist and return correct Content-Type
        check_header "GET /static/reset.css Content-Type" "Content-Type" "text/css" "$STATIC_H2_DOCS" \
            -sk --http2 "https://localhost:$H2PORT/static/reset.css"

        check_header "GET /static/app.js Content-Type" "Content-Type" "application/javascript" "$STATIC_H2_DOCS" \
            -sk --http2 "https://localhost:$H2PORT/static/app.js"

        check_header "GET /static/manifest.json Content-Type" "Content-Type" "application/json" "$STATIC_H2_DOCS" \
            -sk --http2 "https://localhost:$H2PORT/static/manifest.json"

        # Check response size is non-zero
        static_size=$(curl -sk --max-time 30 --http2 -o /dev/null -w '%{size_download}' "https://localhost:$H2PORT/static/reset.css" || echo "0")
        if [ "$static_size" -gt 0 ]; then
            echo "  PASS [static-h2 response size] ($static_size bytes)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[static-h2 response size]: empty response" "$STATIC_H2_DOCS"
        fi

        # 404 for missing files
        check_status "GET /static/nonexistent.txt" "404" "$STATIC_H2_DOCS" \
            -sk --http2 "https://localhost:$H2PORT/static/nonexistent.txt"
    fi
fi

# ───── Async Database (GET /async-db) ─────

if has_test "async-db" || has_test "crud" || has_test "api-4" || has_test "api-16"; then
    ASYNCDB_DOCS="$DOCS_BASE/h1/isolated/async-database/validation"
    echo "[test] async-db endpoint"
    asyncdb_fail=false
    db_params=("min=5&max=80&limit=7" "min=20&max=150&limit=18" "min=100&max=400&limit=33" "min=10&max=50&limit=50")
    for dbp in "${db_params[@]}"; do
        dblimit=$(echo "$dbp" | grep -oP 'limit=\K[0-9]+')
        response=$(curl -s --max-time 30 "http://localhost:$PORT/async-db?$dbp" || true)
        pgdb_result=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = d.get('count', 0)
items = d.get('items', [])
has_rating = all('rating' in item and 'score' in item['rating'] for item in items) if items else False
has_tags = all(isinstance(item.get('tags'), list) for item in items) if items else False
has_active_bool = all(isinstance(item.get('active'), bool) for item in items) if items else False
print(f'{count} {has_rating} {has_tags} {has_active_bool}')
" 2>/dev/null || echo "0 False False False")
        pgdb_count=$(echo "$pgdb_result" | cut -d' ' -f1)
        pgdb_rating=$(echo "$pgdb_result" | cut -d' ' -f2)
        pgdb_tags=$(echo "$pgdb_result" | cut -d' ' -f3)
        pgdb_active=$(echo "$pgdb_result" | cut -d' ' -f4)

        if [ "$pgdb_count" = "$dblimit" ] && [ "$pgdb_rating" = "True" ] && [ "$pgdb_tags" = "True" ] && [ "$pgdb_active" = "True" ]; then
            :
        else
            fail_with_link "[GET /async-db?limit=$dblimit]: count=$pgdb_count, rating=$pgdb_rating, tags=$pgdb_tags, active=$pgdb_active" "$ASYNCDB_DOCS"
            asyncdb_fail=true
        fi
    done
    if [ "$asyncdb_fail" = "false" ]; then
        echo "  PASS [GET /async-db?limit=N] (4 limits verified, correct structure)"
        PASS=$((PASS + 1))
    fi

    check_header "GET /async-db Content-Type" "Content-Type" "application/json" "$ASYNCDB_DOCS" \
        "http://localhost:$PORT/async-db?min=10&max=50&limit=50"

    # Anti-cheat: empty range should return 0 items
    response_empty=$(curl -s --max-time 30 "http://localhost:$PORT/async-db?min=9999&max=9999&limit=50" || true)
    pgdb_empty=$(echo "$response_empty" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count','-1'))" 2>/dev/null || echo "-1")
    if [ "$pgdb_empty" = "0" ]; then
        echo "  PASS [GET /async-db empty range] (count=0)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[GET /async-db empty range]: expected count=0, got $pgdb_empty" "$ASYNCDB_DOCS"
    fi
fi

# ───── CRUD (list + read + create + update /crud/items) ─────

if has_test "crud"; then
    CRUD_DOCS="$DOCS_BASE/h1/isolated/crud/validation"
    echo "[test] crud endpoints"

    # 1. GET list — paginated with category filter
    crud_list=$(curl -s --max-time 30 "http://localhost:$PORT/crud/items?category=electronics&page=1&limit=5" || true)
    crud_list_result=$(echo "$crud_list" | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d.get('items', [])
total = d.get('total', 0)
page = d.get('page', 0)
has_rating = all('rating' in i for i in items) if items else False
print(f'{len(items)} {total} {page} {has_rating}')
" 2>/dev/null || echo "0 0 0 False")
    crud_list_count=$(echo "$crud_list_result" | cut -d' ' -f1)
    crud_list_total=$(echo "$crud_list_result" | cut -d' ' -f2)
    crud_list_page=$(echo "$crud_list_result" | cut -d' ' -f3)
    crud_list_rating=$(echo "$crud_list_result" | cut -d' ' -f4)
    if [ "$crud_list_count" = "5" ] && [ "$crud_list_total" -gt 0 ] 2>/dev/null && [ "$crud_list_page" = "1" ] && [ "$crud_list_rating" = "True" ]; then
        echo "  PASS [GET /crud/items?category=electronics] ($crud_list_count items, total=$crud_list_total, page=$crud_list_page)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[GET /crud/items list]: count=$crud_list_count, total=$crud_list_total, page=$crud_list_page, rating=$crud_list_rating" "$CRUD_DOCS"
    fi

    # 2. GET single item — with cache check
    crud_get=$(curl -s --max-time 30 "http://localhost:$PORT/crud/items/1" || true)
    crud_get_id=$(echo "$crud_get" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','-1'))" 2>/dev/null || echo "-1")
    if [ "$crud_get_id" = "1" ]; then
        echo "  PASS [GET /crud/items/1] (returned id=1)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[GET /crud/items/1]: expected id=1, got $crud_get_id" "$CRUD_DOCS"
    fi

    # 3. Cache-aside check — first call MISS, second call HIT
    crud_cache1=$(curl -s --max-time 30 -D- -o /dev/null "http://localhost:$PORT/crud/items/42" | grep -i "^x-cache:" | tr -d '\r' | awk '{print $2}')
    crud_cache2=$(curl -s --max-time 30 -D- -o /dev/null "http://localhost:$PORT/crud/items/42" | grep -i "^x-cache:" | tr -d '\r' | awk '{print $2}')
    if [ "$crud_cache1" = "MISS" ] && [ "$crud_cache2" = "HIT" ]; then
        echo "  PASS [crud cache-aside] (first=MISS, second=HIT)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[crud cache-aside]: expected MISS then HIT, got '$crud_cache1' then '$crud_cache2'" "$CRUD_DOCS"
    fi

    # 4. GET non-existent item — 404
    check_status "GET /crud/items/999999 (not found)" "404" "$CRUD_DOCS" \
        -s --max-time 30 "http://localhost:$PORT/crud/items/999999"

    # 5. POST — create a new item
    crud_post_status=$(curl -s --max-time 30 -o /tmp/crud-post.json -w '%{http_code}' \
        -X POST -H "Content-Type: application/json" \
        -d '{"id":200001,"name":"ValidateItem","category":"test","price":42,"quantity":7}' \
        "http://localhost:$PORT/crud/items" || echo "0")
    if [ "$crud_post_status" = "201" ]; then
        echo "  PASS [POST /crud/items] (201 Created)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[POST /crud/items]: expected 201, got $crud_post_status" "$CRUD_DOCS"
    fi

    # 6. GET back the created item
    crud_verify=$(curl -s --max-time 30 "http://localhost:$PORT/crud/items/200001" || true)
    crud_verify_id=$(echo "$crud_verify" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','-1'))" 2>/dev/null || echo "-1")
    if [ "$crud_verify_id" = "200001" ]; then
        echo "  PASS [GET /crud/items/200001] (read back created item)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[GET /crud/items/200001]: expected id=200001, got $crud_verify_id" "$CRUD_DOCS"
    fi

    # 7. PUT — update, then verify cache was invalidated
    curl -s --max-time 30 -o /dev/null "http://localhost:$PORT/crud/items/200001"  # warm cache
    crud_put_status=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' \
        -X PUT -H "Content-Type: application/json" \
        -d '{"name":"UpdatedItem","category":"test","price":99,"quantity":1}' \
        "http://localhost:$PORT/crud/items/200001" || echo "0")
    crud_after_put=$(curl -s --max-time 30 -D- -o /dev/null "http://localhost:$PORT/crud/items/200001" | grep -i "^x-cache:" | tr -d '\r' | awk '{print $2}')
    if [ "$crud_put_status" = "200" ] && [ "$crud_after_put" = "MISS" ]; then
        echo "  PASS [PUT /crud/items/200001] (200 OK, cache invalidated)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[PUT /crud/items/200001]: status=$crud_put_status, cache_after=$crud_after_put" "$CRUD_DOCS"
    fi
fi

# ───── WebSocket Echo (ws://localhost/ws) ─────

if has_test "echo-ws"; then
    WS_DOCS="$DOCS_BASE/ws/echo/validation"
    echo "[test] echo-ws endpoint"
    WS_OUTPUT=$(python3 "$SCRIPT_DIR/validate-ws.py" localhost "$PORT" /ws 2>&1) || true
    echo "$WS_OUTPUT"

    # Parse pass/fail counts from the script output
    WS_PASS=$(echo "$WS_OUTPUT" | grep -oP '(\d+) passed' | grep -oP '\d+')
    WS_FAIL=$(echo "$WS_OUTPUT" | grep -oP '(\d+) failed' | grep -oP '\d+')
    PASS=$((PASS + ${WS_PASS:-0}))
    FAIL=$((FAIL + ${WS_FAIL:-0}))
    if [ "${WS_FAIL:-0}" -gt 0 ]; then
        echo "        → $WS_DOCS"
    fi
fi

# ───── Gateway profiles (reverse proxy + server, shared validation flow) ─────
#
# Both gateway-64 (h2) and gateway-h3 (h3 at the edge) use the same endpoint
# surface (/static, /json/{count}, /async-db, /baseline2) so validation is
# identical — only the compose file and docs URL change. Factored here so
# we don't duplicate ~150 lines of curl checks per profile.
#
# The h3 profile is validated via curl's --http2 path even though the test
# runs over QUIC at benchmark time, because curl builds don't reliably ship
# h3 support. Caddy (and most h3-capable proxies) answer h2 and h3 on the
# same port, so endpoint correctness is still covered. If h3 itself is
# broken, h2load-h3 will catch it at benchmark time with 0 rps.
_validate_gateway() {
    local profile="$1"
    local compose_file="$2"
    local gateway_docs="$3"

    echo "[test] $profile endpoints"

    local gw_project="httparena-validate-gw-${profile}-${FRAMEWORK}"
    if [ -f "$compose_file" ]; then
        echo "[gateway] Building and starting compose stack..."
        CERTS_DIR="$CERTS_DIR" DATA_DIR="$DATA_DIR" DATABASE_URL="postgres://bench:bench@localhost:5432/benchmark" \
            docker compose -f "$compose_file" -p "$gw_project" up --build -d || { echo "FAIL: gateway compose up"; FAIL=$((FAIL + 1)); return; }
    else
        echo "  FAIL [$profile]: compose file not found at $compose_file"
        FAIL=$((FAIL + 1))
        return
    fi

    local GW_PORT=$H2PORT

    echo "[wait] Waiting for gateway HTTPS port..."
    local gw_ready=false i
    for i in $(seq 1 30); do
        if curl -sk --max-time 2 --http2 -o /dev/null "https://localhost:$GW_PORT/static/reset.css" 2>/dev/null; then
            gw_ready=true
            break
        fi
        sleep 1
    done

    if [ "$gw_ready" = "true" ]; then
        # 1. HTTP/2 protocol negotiation (works for h2 and h3-capable proxies
        #    that still speak h2 on the same port — Caddy, nginx-quic, etc.)
        local gw_proto
        gw_proto=$(curl -sk --max-time 30 --http2 -o /dev/null -w '%{http_version}' "https://localhost:$GW_PORT/static/reset.css" || echo "0")
        if [ "$gw_proto" = "2" ]; then
            echo "  PASS [gateway HTTP/2 negotiation] (HTTP/$gw_proto)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[gateway HTTP/2 negotiation]: got HTTP/$gw_proto" "$gateway_docs"
        fi

        # 2. Static file — correct Content-Type
        check_header "gateway /static/reset.css Content-Type" "Content-Type" "text/css" "$gateway_docs" \
            -sk --http2 "https://localhost:$GW_PORT/static/reset.css"

        check_header "gateway /static/app.js Content-Type" "Content-Type" "application/javascript" "$gateway_docs" \
            -sk --http2 "https://localhost:$GW_PORT/static/app.js"

        # 3. Static file — non-zero size
        local gw_static_size
        gw_static_size=$(curl -sk --max-time 30 --http2 -o /dev/null -w '%{size_download}' "https://localhost:$GW_PORT/static/app.js" || echo "0")
        if [ "$gw_static_size" -gt 0 ]; then
            echo "  PASS [gateway static file size] ($gw_static_size bytes)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[gateway static file size]: empty response for /static/app.js" "$gateway_docs"
        fi

        # 4. Static file — 404 for missing files
        check_status "gateway /static/nonexistent.txt" "404" "$gateway_docs" \
            -sk --http2 "https://localhost:$GW_PORT/static/nonexistent.txt"

        # 5. JSON endpoint — valid JSON with computed totals
        local gw_json_response gw_json_result gw_json_count gw_json_total gw_json_correct
        gw_json_response=$(curl -sk --max-time 30 --http2 "https://localhost:$GW_PORT/json/50" || true)
        gw_json_result=$(echo "$gw_json_response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = d.get('count', 0)
items = d.get('items', [])
has_total = all('total' in item for item in items) if items else False
correct_totals = True
for item in items:
    expected = round(item['price'] * item['quantity'], 2)
    if abs(item.get('total', 0) - expected) > 0.02:
        correct_totals = False
        break
print(f'{count} {has_total} {correct_totals}')
" 2>/dev/null || echo "0 False False")
        gw_json_count=$(echo "$gw_json_result" | cut -d' ' -f1)
        gw_json_total=$(echo "$gw_json_result" | cut -d' ' -f2)
        gw_json_correct=$(echo "$gw_json_result" | cut -d' ' -f3)

        if [ "$gw_json_count" = "50" ] && [ "$gw_json_total" = "True" ] && [ "$gw_json_correct" = "True" ]; then
            echo "  PASS [gateway /json] (50 items, totals correct)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[gateway /json]: count=$gw_json_count, has_total=$gw_json_total, correct=$gw_json_correct" "$gateway_docs"
        fi

        check_header "gateway /json Content-Type" "Content-Type" "application/json" "$gateway_docs" \
            -sk --http2 "https://localhost:$GW_PORT/json/50"

        # 6. Async database endpoint — valid result set
        local gw_db_response gw_db_result gw_db_count gw_db_rating gw_db_tags gw_db_active
        gw_db_response=$(curl -sk --max-time 30 --http2 "https://localhost:$GW_PORT/async-db?min=10&max=50&limit=50" || true)
        gw_db_result=$(echo "$gw_db_response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = d.get('count', 0)
items = d.get('items', [])
has_rating = all('rating' in item and 'score' in item['rating'] for item in items) if items else False
has_tags = all(isinstance(item.get('tags'), list) for item in items) if items else False
has_active_bool = all(isinstance(item.get('active'), bool) for item in items) if items else False
print(f'{count} {has_rating} {has_tags} {has_active_bool}')
" 2>/dev/null || echo "0 False False False")
        gw_db_count=$(echo "$gw_db_result" | cut -d' ' -f1)
        gw_db_rating=$(echo "$gw_db_result" | cut -d' ' -f2)
        gw_db_tags=$(echo "$gw_db_result" | cut -d' ' -f3)
        gw_db_active=$(echo "$gw_db_result" | cut -d' ' -f4)

        if [ "$gw_db_count" -gt 0 ] && [ "$gw_db_count" -le 50 ] && [ "$gw_db_rating" = "True" ] && [ "$gw_db_tags" = "True" ] && [ "$gw_db_active" = "True" ]; then
            echo "  PASS [gateway /async-db] ($gw_db_count items, correct structure)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[gateway /async-db]: count=$gw_db_count, rating=$gw_db_rating, tags=$gw_db_tags, active=$gw_db_active" "$gateway_docs"
        fi

        check_header "gateway /async-db Content-Type" "Content-Type" "application/json" "$gateway_docs" \
            -sk --http2 "https://localhost:$GW_PORT/async-db?min=10&max=50&limit=50"

        # 7. Async-db anti-cheat: empty range
        local gw_db_empty
        gw_db_empty=$(curl -sk --max-time 30 --http2 "https://localhost:$GW_PORT/async-db?min=9999&max=9999&limit=50" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count','-1'))" 2>/dev/null || echo "-1")
        if [ "$gw_db_empty" = "0" ]; then
            echo "  PASS [gateway /async-db empty range] (count=0)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[gateway /async-db empty range]: expected count=0, got $gw_db_empty" "$gateway_docs"
        fi

        # 8. Baseline2 endpoint
        check "gateway /baseline2?a=13&b=42" "55" "$gateway_docs" \
            -sk --http2 "https://localhost:$GW_PORT/baseline2?a=13&b=42"

        # 9. Baseline2 anti-cheat: randomized inputs
        local GW_A=$((RANDOM % 900 + 100))
        local GW_B=$((RANDOM % 900 + 100))
        check "gateway /baseline2?a=$GW_A&b=$GW_B (random)" "$((GW_A + GW_B))" "$gateway_docs" \
            -sk --http2 "https://localhost:$GW_PORT/baseline2?a=$GW_A&b=$GW_B"
    else
        echo "  FAIL: Gateway HTTPS port $GW_PORT not responding after 30s"
        FAIL=$((FAIL + 1))
    fi

    # Cleanup gateway compose stack
    if [ -f "$compose_file" ]; then
        CERTS_DIR="$CERTS_DIR" DATA_DIR="$DATA_DIR" DATABASE_URL="postgres://bench:bench@localhost:5432/benchmark" \
            docker compose -f "$compose_file" -p "$gw_project" down --remove-orphans 2>/dev/null || true
    fi
}

# ───── Gateway H2 (h2 at the edge) ─────

if has_test "gateway-64"; then
    _validate_gateway "gateway-64" \
        "$ROOT_DIR/frameworks/$FRAMEWORK/compose.gateway.yml" \
        "$DOCS_BASE/h2-gateway/gateway-64/validation"
fi

# ───── Gateway H3 (h3/QUIC at the edge) ─────

if has_test "gateway-h3"; then
    _validate_gateway "gateway-h3" \
        "$ROOT_DIR/frameworks/$FRAMEWORK/compose.gateway-h3.yml" \
        "$DOCS_BASE/h3-gateway/gateway-h3/validation"
fi

# ───── Production-stack (edge + authsvc + cache + server) ─────
#
# Distinct endpoint surface from the gateway profiles: /public/* is
# unauthenticated compute, /api/* is behind an edge auth_request → Redis
# session lookup. We validate both the anonymous path (public works,
# api returns 401 without a cookie) and the authenticated path (api
# returns 200 with a pre-seeded session cookie).

_validate_production_stack() {
    local compose_file="$1"
    local docs_url="$2"
    local profile="production-stack"

    echo "[test] $profile endpoints"

    local gw_project="httparena-validate-gw-${profile}-${FRAMEWORK}"
    if [ -f "$compose_file" ]; then
        echo "[$profile] Building and starting compose stack..."
        CERTS_DIR="$CERTS_DIR" DATA_DIR="$DATA_DIR" DATABASE_URL="postgres://bench:bench@localhost:5432/benchmark" \
            docker compose -f "$compose_file" -p "$gw_project" up --build -d || { echo "FAIL: $profile compose up"; FAIL=$((FAIL + 1)); return; }
    else
        echo "  FAIL [$profile]: compose file not found at $compose_file"
        FAIL=$((FAIL + 1))
        return
    fi

    local GW_PORT=$H2PORT

    # Wait for the edge to answer. Also gives the Redis seed step time to
    # finish — without seeded sessions, /api/* would all return 401.
    echo "[wait] Waiting for $profile HTTPS port..."
    local gw_ready=false i
    for i in $(seq 1 60); do
        if curl -sk --max-time 2 --http2 -o /dev/null "https://localhost:$GW_PORT/static/reset.css" 2>/dev/null; then
            gw_ready=true
            break
        fi
        sleep 1
    done

    if [ "$gw_ready" = "true" ]; then
        # 1. HTTP/2 protocol negotiation
        local gw_proto
        gw_proto=$(curl -sk --max-time 30 --http2 -o /dev/null -w '%{http_version}' "https://localhost:$GW_PORT/static/reset.css" || echo "0")
        if [ "$gw_proto" = "2" ]; then
            echo "  PASS [$profile HTTP/2 negotiation] (HTTP/$gw_proto)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[$profile HTTP/2 negotiation]: got HTTP/$gw_proto" "$docs_url"
        fi

        # 2. Static file served by edge
        check_header "$profile /static/reset.css Content-Type" "Content-Type" "text/css" "$docs_url" \
            -sk --http2 "https://localhost:$GW_PORT/static/reset.css"

        local gw_static_size
        gw_static_size=$(curl -sk --max-time 30 --http2 -o /dev/null -w '%{size_download}' "https://localhost:$GW_PORT/static/app.js" || echo "0")
        if [ "$gw_static_size" -gt 0 ]; then
            echo "  PASS [$profile static file size] ($gw_static_size bytes)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[$profile static file size]: empty response for /static/app.js" "$docs_url"
        fi

        # 3. Public baseline — no auth, no cache
        check "$profile /public/baseline?a=13&b=42" "55" "$docs_url" \
            -sk --http2 "https://localhost:$GW_PORT/public/baseline?a=13&b=42"

        local GW_A=$((RANDOM % 900 + 100))
        local GW_B=$((RANDOM % 900 + 100))
        check "$profile /public/baseline?a=$GW_A&b=$GW_B (random)" "$((GW_A + GW_B))" "$docs_url" \
            -sk --http2 "https://localhost:$GW_PORT/public/baseline?a=$GW_A&b=$GW_B"

        # 4. Public JSON — no auth, no cache, returns count items with totals
        local gw_json_response gw_json_result gw_json_count gw_json_total gw_json_correct
        gw_json_response=$(curl -sk --max-time 30 --http2 "https://localhost:$GW_PORT/public/json/25" || true)
        gw_json_result=$(echo "$gw_json_response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = d.get('count', 0)
items = d.get('items', [])
has_total = all('total' in item for item in items) if items else False
correct_totals = True
for item in items:
    expected = round(item['price'] * item['quantity'], 2)
    if abs(item.get('total', 0) - expected) > 0.02:
        correct_totals = False
        break
print(f'{count} {has_total} {correct_totals}')
" 2>/dev/null || echo "0 False False")
        gw_json_count=$(echo "$gw_json_result" | cut -d' ' -f1)
        gw_json_total=$(echo "$gw_json_result" | cut -d' ' -f2)
        gw_json_correct=$(echo "$gw_json_result" | cut -d' ' -f3)

        if [ "$gw_json_count" = "25" ] && [ "$gw_json_total" = "True" ] && [ "$gw_json_correct" = "True" ]; then
            echo "  PASS [$profile /public/json/25] (25 items, totals correct)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[$profile /public/json/25]: count=$gw_json_count, has_total=$gw_json_total, correct=$gw_json_correct" "$docs_url"
        fi

        # 5. Auth wall (GET) — /api/* without a cookie must return 401
        check_status "$profile GET /api/items no-token" "401" "$docs_url" \
            -sk --http2 "https://localhost:$GW_PORT/api/items/1"

        # 6. Auth wall (GET) — /api/* with a bogus cookie must also return 401
        check_status "$profile GET /api/items bogus-cookie" "401" "$docs_url" \
            -sk --http2 -H "Authorization: Bearer invalid.token.here" "https://localhost:$GW_PORT/api/items/1"

        # 7. Auth wall (POST) — the write path MUST also reject unauth calls,
        #    otherwise an anonymous client could UPDATE rows in Postgres.
        #    If nginx forgot to apply auth_request to the POST branch, or if
        #    the framework ignored the edge's 401 and processed the body, this
        #    check catches it. Body matters less than status — a bogus body
        #    is fine because the server should reject at auth before parsing.
        check_status "$profile POST /api/items no-token" "401" "$docs_url" \
            -sk --http2 -X POST -H "Content-Type: application/json" \
            -d '{"name":"unauth","price":1,"quantity":1}' \
            "https://localhost:$GW_PORT/api/items/1"

        # 8. Auth wall (POST) — bogus cookie must also return 401
        check_status "$profile POST /api/items bogus-cookie" "401" "$docs_url" \
            -sk --http2 -X POST -H "Content-Type: application/json" \
            -H "Authorization: Bearer invalid.token.here" \
            -d '{"name":"unauth","price":1,"quantity":1}' \
            "https://localhost:$GW_PORT/api/items/1"

        # 7. Authenticated /api/items/{id} — cache-aside returns item JSON
        local gw_item_response gw_item_id
        gw_item_response=$(curl -sk --max-time 30 --http2 -H "Authorization: Bearer $(cat $ROOT_DIR/data/jwt-token.txt)" "https://localhost:$GW_PORT/api/items/1" || true)
        gw_item_id=$(echo "$gw_item_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','-1'))" 2>/dev/null || echo "-1")
        if [ "$gw_item_id" = "1" ]; then
            echo "  PASS [$profile /api/items/1] (authenticated, returned id=1)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[$profile /api/items/1]: expected id=1, got $gw_item_id" "$docs_url"
        fi

        # 8. Cache-aside HIT after MISS — pick a previously-unread id, first
        #    call must be MISS, immediate second call must be HIT. Proves
        #    SetStringAsync populated the cache on miss.
        local first_cache second_cache
        first_cache=$(curl -sk --max-time 30 --http2 -H "Authorization: Bearer $(cat $ROOT_DIR/data/jwt-token.txt)" \
            -D- -o /dev/null "https://localhost:$GW_PORT/api/items/7" | grep -i "^x-cache:" | tr -d '\r' | awk '{print $2}')
        second_cache=$(curl -sk --max-time 30 --http2 -H "Authorization: Bearer $(cat $ROOT_DIR/data/jwt-token.txt)" \
            -D- -o /dev/null "https://localhost:$GW_PORT/api/items/7" | grep -i "^x-cache:" | tr -d '\r' | awk '{print $2}')
        if [ "$first_cache" = "MISS" ] && [ "$second_cache" = "HIT" ]; then
            echo "  PASS [$profile cache-aside] (first=MISS, second=HIT)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[$profile cache-aside]: expected first=MISS second=HIT, got first='$first_cache' second='$second_cache'" "$docs_url"
        fi

        # 9. POST /api/items/{id} — write path + cache invalidation.
        #    After POST, the next GET on the same id must be MISS (because
        #    the cache was invalidated).
        local post_status invalidated_cache
        post_status=$(curl -sk --max-time 30 --http2 -X POST \
            -H "Authorization: Bearer $(cat $ROOT_DIR/data/jwt-token.txt)" \
            -H "Content-Type: application/json" \
            -d '{"name":"validate-updated","price":777,"quantity":99}' \
            -o /dev/null -w '%{http_code}' \
            "https://localhost:$GW_PORT/api/items/2" || echo "0")
        if [ "$post_status" = "204" ]; then
            echo "  PASS [$profile POST /api/items/2] (204 No Content)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[$profile POST /api/items/2]: expected 204, got $post_status" "$docs_url"
        fi

        # 10. Warm the cache for item 2, then invalidate via POST, then
        #     confirm the cache is MISS again (proving RemoveAsync worked).
        curl -sk --max-time 30 --http2 -H "Authorization: Bearer $(cat $ROOT_DIR/data/jwt-token.txt)" \
            -o /dev/null "https://localhost:$GW_PORT/api/items/3"  # warm
        curl -sk --max-time 30 --http2 -X POST \
            -H "Authorization: Bearer $(cat $ROOT_DIR/data/jwt-token.txt)" \
            -H "Content-Type: application/json" \
            -d '{"name":"validate-invalidated","price":111,"quantity":22}' \
            -o /dev/null "https://localhost:$GW_PORT/api/items/3" # invalidate
        invalidated_cache=$(curl -sk --max-time 30 --http2 -H "Authorization: Bearer $(cat $ROOT_DIR/data/jwt-token.txt)" \
            -D- -o /dev/null "https://localhost:$GW_PORT/api/items/3" | grep -i "^x-cache:" | tr -d '\r' | awk '{print $2}')
        if [ "$invalidated_cache" = "MISS" ]; then
            echo "  PASS [$profile POST invalidation] (GET after POST shows MISS)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[$profile POST invalidation]: expected MISS after POST, got '$invalidated_cache'" "$docs_url"
        fi

        # 11. Authenticated /api/me — cache-aside from users table
        local gw_me_response gw_me_id
        gw_me_response=$(curl -sk --max-time 30 --http2 -H "Authorization: Bearer $(cat $ROOT_DIR/data/jwt-token.txt)" "https://localhost:$GW_PORT/api/me" || true)
        gw_me_id=$(echo "$gw_me_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','-1'))" 2>/dev/null || echo "-1")
        if [ "$gw_me_id" = "42" ]; then
            echo "  PASS [$profile /api/me] (authenticated, returned user 42)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[$profile /api/me]: expected user id 42, got $gw_me_id" "$docs_url"
        fi
    else
        echo "  FAIL: $profile HTTPS port $GW_PORT not responding after 60s"
        FAIL=$((FAIL + 1))
    fi

    # Cleanup
    if [ -f "$compose_file" ]; then
        CERTS_DIR="$CERTS_DIR" DATA_DIR="$DATA_DIR" DATABASE_URL="postgres://bench:bench@localhost:5432/benchmark" \
            docker compose -f "$compose_file" -p "$gw_project" down --remove-orphans 2>/dev/null || true
    fi
}

if has_test "production-stack"; then
    _validate_production_stack \
        "$ROOT_DIR/frameworks/$FRAMEWORK/compose.production-stack.yml" \
        "$DOCS_BASE/production-stack/validation"
fi

# ───── Summary ─────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
