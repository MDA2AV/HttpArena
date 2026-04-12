#!/usr/bin/env bash
set -euo pipefail

FRAMEWORK="$1"
IMAGE_NAME="httparena-${FRAMEWORK}"
CONTAINER_NAME="httparena-validate-${FRAMEWORK}"
PORT=8080
H2PORT=8443
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
    # Stop gateway compose stack if running
    local gw_compose="$ROOT_DIR/frameworks/$FRAMEWORK/compose.gateway.yml"
    if [ -f "$gw_compose" ]; then
        CERTS_DIR="${CERTS_DIR:-$ROOT_DIR/certs}" DATA_DIR="${DATA_DIR:-$ROOT_DIR/data}" DATABASE_URL="${DATABASE_URL:-}" \
            docker compose -f "$gw_compose" -p "httparena-validate-gw-${FRAMEWORK}" down --remove-orphans 2>/dev/null || true
    fi
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

# Build — skip standalone build if framework only subscribes to gateway-64
GATEWAY_ONLY=false
if [ "$TESTS" = "gateway-64" ]; then
    GATEWAY_ONLY=true
fi

if [ "$GATEWAY_ONLY" = "false" ]; then
    echo "[build] Building Docker image..."
    if [ -x "frameworks/$FRAMEWORK/build.sh" ]; then
        "frameworks/$FRAMEWORK/build.sh" || { echo "FAIL: Docker build failed"; exit 1; }
    else
        docker build --no-cache -t "$IMAGE_NAME" "frameworks/$FRAMEWORK" || { echo "FAIL: Docker build failed"; exit 1; }
    fi
fi

# Mount volumes based on subscribed tests
HARD_NOFILE=$(ulimit -Hn)
if has_test "async-db" || has_test "api-4" || has_test "api-16" || has_test "gateway-64"; then
    docker_args=(-d --name "$CONTAINER_NAME" --network host --security-opt seccomp=unconfined
        --ulimit memlock=-1:-1 --ulimit nofile="$HARD_NOFILE:$HARD_NOFILE")
else
    docker_args=(-d --name "$CONTAINER_NAME" -p "$PORT:8080"
        --ulimit memlock=-1:-1 --ulimit nofile="$HARD_NOFILE:$HARD_NOFILE")
fi
docker_args+=(-v "$DATA_DIR/dataset.json:/data/dataset.json:ro")

needs_h2=false
if has_test "baseline-h2" || has_test "static-h2" || has_test "baseline-h3" || has_test "static-h3" || has_test "gateway-64"; then
    needs_h2=true
fi

if $needs_h2 && [ -d "$CERTS_DIR" ]; then
    docker_args+=(-p "$H2PORT:8443" -v "$CERTS_DIR:/certs:ro")
fi

if has_test "gateway-64"; then
    docker_args+=(-v "$DATA_DIR/dataset-large.json:/data/dataset-large.json:ro")
fi

if has_test "static" || has_test "static-h2" || has_test "static-h3" || has_test "gateway-64"; then
    docker_args+=(-v "$DATA_DIR/static:/data/static:ro")
fi

# Allow io_uring syscalls for frameworks that need them (blocked by default seccomp)
ENGINE=$(python3 -c "import json; print(json.load(open('$META_FILE')).get('engine',''))" 2>/dev/null || true)
if [ "$ENGINE" = "io_uring" ]; then
    docker_args+=(--security-opt seccomp=unconfined)
    docker_args+=(--ulimit memlock=-1:-1)
fi

# Start Postgres sidecar if async-db is needed
if has_test "async-db" || has_test "api-4" || has_test "api-16" || has_test "gateway-64"; then
    echo "[postgres] Starting Postgres sidecar for validation..."
    docker rm -f "$PG_CONTAINER" 2>/dev/null || true
    docker run -d --name "$PG_CONTAINER" --network host \
        -e POSTGRES_USER=bench \
        -e POSTGRES_PASSWORD=bench \
        -e POSTGRES_DB=benchmark \
        -v "$DATA_DIR/pgdb-seed.sql:/docker-entrypoint-initdb.d/seed.sql:ro" \
        postgres:17-alpine \
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
    docker_args+=(-e "DATABASE_MAX_CONN=512")
fi

# Start container (skip for gateway-only — compose handles it later)
if [ "$GATEWAY_ONLY" = "false" ]; then
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    docker run "${docker_args[@]}" "$IMAGE_NAME"

    # Wait for server to start
    echo "[wait] Waiting for server..."
    for i in $(seq 1 30); do
        if curl -s --max-time 2 -o /dev/null -w '' "http://localhost:$PORT/baseline11?a=1&b=1" 2>/dev/null; then
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
    response=$(curl -s --max-time 30 -D- "$@")
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
    http_code=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' "$@")

    if [ "$http_code" = "$expected_status" ]; then
        echo "  PASS [$label] (HTTP $http_code)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[$label]: expected HTTP $expected_status, got HTTP $http_code" "$docs_url"
    fi
}

check_header() {
    local label="$1"
    local header_name="$2"
    local expected_value="$3"
    local docs_url="$4"
    shift 4
    local headers
    headers=$(curl -s --max-time 30 -D- -o /dev/null "$@")
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
fi

# ───── Pipelined (GET /pipeline) ─────

if has_test "pipelined"; then
    PIPELINED_DOCS="$DOCS_BASE/h1/isolated/pipelined/validation"
    echo "[test] pipelined endpoint"
    check "GET /pipeline" "ok" "$PIPELINED_DOCS" \
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
        response=$(curl -s --max-time 30 "http://localhost:$PORT/json/$jcount?m=$jm")
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
    jc_headers=$(curl -s --max-time 30 -D- -o /dev/null -H "Accept-Encoding: gzip, br" "http://localhost:$PORT/json/50?m=1")
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
        jc_response=$(curl -s --max-time 30 --compressed -H "Accept-Encoding: gzip, br" "http://localhost:$PORT/json/$jccount?m=$jcm")
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
    ACTUAL_LEN=$(curl -s --max-time 30 -X POST -H "Content-Type: application/octet-stream" --data-binary "$RANDOM_BODY" "http://localhost:$PORT/upload")
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
        ACTUAL_LARGE=$(dd if=/dev/urandom bs=1024 count=$upload_bs 2>/dev/null | curl -s --max-time 60 -X POST -H "Content-Type: application/octet-stream" --data-binary @- "http://localhost:$PORT/upload")
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
        h2_proto=$(curl -sk --max-time 30 --http2 -o /dev/null -w '%{http_version}' "https://localhost:$H2PORT/baseline2?a=1&b=1")
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
        actual_size=$(curl -s --max-time 30 -o /dev/null -w '%{size_download}' "http://localhost:$PORT/static/$sf")
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
        curl -s --max-time 30 --compressed -D "$_hdr_tmp" -o "$_body_tmp" "http://localhost:$PORT/static/$sf"
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
        static_size=$(curl -sk --max-time 30 --http2 -o /dev/null -w '%{size_download}' "https://localhost:$H2PORT/static/reset.css")
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

if has_test "async-db" || has_test "api-4" || has_test "api-16"; then
    ASYNCDB_DOCS="$DOCS_BASE/h1/isolated/async-database/validation"
    echo "[test] async-db endpoint"
    asyncdb_fail=false
    db_params=("min=5&max=80&limit=7" "min=20&max=150&limit=18" "min=100&max=400&limit=33" "min=10&max=50&limit=50")
    for dbp in "${db_params[@]}"; do
        dblimit=$(echo "$dbp" | grep -oP 'limit=\K[0-9]+')
        response=$(curl -s --max-time 30 "http://localhost:$PORT/async-db?$dbp")
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
    response_empty=$(curl -s --max-time 30 "http://localhost:$PORT/async-db?min=9999&max=9999&limit=50")
    pgdb_empty=$(echo "$response_empty" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count','-1'))" 2>/dev/null || echo "-1")
    if [ "$pgdb_empty" = "0" ]; then
        echo "  PASS [GET /async-db empty range] (count=0)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[GET /async-db empty range]: expected count=0, got $pgdb_empty" "$ASYNCDB_DOCS"
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

# ───── Gateway H2 (reverse proxy + server over HTTP/2 + TLS) ─────

if has_test "gateway-64"; then
    GATEWAY_DOCS="$DOCS_BASE/h2-gateway/gateway-64/validation"
    echo "[test] gateway-64 endpoints"

    # Start gateway compose stack
    GW_COMPOSE="$ROOT_DIR/frameworks/$FRAMEWORK/compose.gateway.yml"
    GW_PROJECT="httparena-validate-gw-${FRAMEWORK}"
    if [ -f "$GW_COMPOSE" ]; then
        echo "[gateway] Building and starting compose stack..."
        CERTS_DIR="$CERTS_DIR" DATA_DIR="$DATA_DIR" DATABASE_URL="postgres://bench:bench@localhost:5432/benchmark" \
            docker compose -f "$GW_COMPOSE" -p "$GW_PROJECT" up --build -d || { echo "FAIL: gateway compose up"; FAIL=$((FAIL + 1)); }
    else
        echo "  FAIL [gateway-64]: compose.gateway.yml not found"
        FAIL=$((FAIL + 1))
    fi

    GW_PORT=$H2PORT

    # Wait for gateway to respond
    echo "[wait] Waiting for gateway HTTPS port..."
    gw_ready=false
    for i in $(seq 1 30); do
        if curl -sk --max-time 2 --http2 -o /dev/null "https://localhost:$GW_PORT/static/reset.css" 2>/dev/null; then
            gw_ready=true
            break
        fi
        sleep 1
    done

    if [ "$gw_ready" = "true" ]; then
        # 1. HTTP/2 protocol negotiation
        gw_proto=$(curl -sk --max-time 30 --http2 -o /dev/null -w '%{http_version}' "https://localhost:$GW_PORT/static/reset.css")
        if [ "$gw_proto" = "2" ]; then
            echo "  PASS [gateway HTTP/2 negotiation] (HTTP/$gw_proto)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[gateway HTTP/2 negotiation]: got HTTP/$gw_proto" "$GATEWAY_DOCS"
        fi

        # 2. Static file — correct Content-Type
        check_header "gateway /static/reset.css Content-Type" "Content-Type" "text/css" "$GATEWAY_DOCS" \
            -sk --http2 "https://localhost:$GW_PORT/static/reset.css"

        check_header "gateway /static/app.js Content-Type" "Content-Type" "application/javascript" "$GATEWAY_DOCS" \
            -sk --http2 "https://localhost:$GW_PORT/static/app.js"

        # 3. Static file — non-zero size
        gw_static_size=$(curl -sk --max-time 30 --http2 -o /dev/null -w '%{size_download}' "https://localhost:$GW_PORT/static/app.js")
        if [ "$gw_static_size" -gt 0 ]; then
            echo "  PASS [gateway static file size] ($gw_static_size bytes)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[gateway static file size]: empty response for /static/app.js" "$GATEWAY_DOCS"
        fi

        # 4. Static file — 404 for missing files
        check_status "gateway /static/nonexistent.txt" "404" "$GATEWAY_DOCS" \
            -sk --http2 "https://localhost:$GW_PORT/static/nonexistent.txt"

        # 5. JSON endpoint — valid JSON with computed totals
        gw_json_response=$(curl -sk --max-time 30 --http2 "https://localhost:$GW_PORT/json/50")
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
            fail_with_link "[gateway /json]: count=$gw_json_count, has_total=$gw_json_total, correct=$gw_json_correct" "$GATEWAY_DOCS"
        fi

        check_header "gateway /json Content-Type" "Content-Type" "application/json" "$GATEWAY_DOCS" \
            -sk --http2 "https://localhost:$GW_PORT/json/50"

        # 6. Async database endpoint — valid result set
        gw_db_response=$(curl -sk --max-time 30 --http2 "https://localhost:$GW_PORT/async-db?min=10&max=50&limit=50")
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
            fail_with_link "[gateway /async-db]: count=$gw_db_count, rating=$gw_db_rating, tags=$gw_db_tags, active=$gw_db_active" "$GATEWAY_DOCS"
        fi

        check_header "gateway /async-db Content-Type" "Content-Type" "application/json" "$GATEWAY_DOCS" \
            -sk --http2 "https://localhost:$GW_PORT/async-db?min=10&max=50&limit=50"

        # 7. Async-db anti-cheat: empty range
        gw_db_empty=$(curl -sk --max-time 30 --http2 "https://localhost:$GW_PORT/async-db?min=9999&max=9999&limit=50" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count','-1'))" 2>/dev/null || echo "-1")
        if [ "$gw_db_empty" = "0" ]; then
            echo "  PASS [gateway /async-db empty range] (count=0)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[gateway /async-db empty range]: expected count=0, got $gw_db_empty" "$GATEWAY_DOCS"
        fi

        # 8. Baseline2 endpoint
        check "gateway /baseline2?a=13&b=42" "55" "$GATEWAY_DOCS" \
            -sk --http2 "https://localhost:$GW_PORT/baseline2?a=13&b=42"

        # 9. Baseline2 anti-cheat: randomized inputs
        GW_A=$((RANDOM % 900 + 100))
        GW_B=$((RANDOM % 900 + 100))
        check "gateway /baseline2?a=$GW_A&b=$GW_B (random)" "$((GW_A + GW_B))" "$GATEWAY_DOCS" \
            -sk --http2 "https://localhost:$GW_PORT/baseline2?a=$GW_A&b=$GW_B"
    else
        echo "  FAIL: Gateway HTTPS port $GW_PORT not responding after 30s"
        FAIL=$((FAIL + 1))
    fi

    # Cleanup gateway compose stack
    if [ -f "$GW_COMPOSE" ]; then
        CERTS_DIR="$CERTS_DIR" DATA_DIR="$DATA_DIR" DATABASE_URL="postgres://bench:bench@localhost:5432/benchmark" \
            docker compose -f "$GW_COMPOSE" -p "$GW_PROJECT" down --remove-orphans 2>/dev/null || true
    fi
fi

# ───── Summary ─────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
