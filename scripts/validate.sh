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
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    docker rm -f "$PG_CONTAINER" 2>/dev/null || true
    docker network rm "$PG_NETWORK" 2>/dev/null || true
}
trap cleanup EXIT

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

# Build
echo "[build] Building Docker image..."
if [ -x "frameworks/$FRAMEWORK/build.sh" ]; then
    "frameworks/$FRAMEWORK/build.sh" || { echo "FAIL: Docker build failed"; exit 1; }
else
    docker build -t "$IMAGE_NAME" "frameworks/$FRAMEWORK" || { echo "FAIL: Docker build failed"; exit 1; }
fi

# Mount volumes based on subscribed tests
docker_args=(-d --name "$CONTAINER_NAME" -p "$PORT:8080")
docker_args+=(-v "$DATA_DIR/dataset.json:/data/dataset.json:ro")

needs_h2=false
if has_test "baseline-h2" || has_test "static-h2" || has_test "baseline-h3" || has_test "static-h3"; then
    needs_h2=true
fi

if $needs_h2 && [ -d "$CERTS_DIR" ]; then
    docker_args+=(-p "$H2PORT:8443" -v "$CERTS_DIR:/certs:ro")
fi

if has_test "compression"; then
    docker_args+=(-v "$DATA_DIR/dataset-large.json:/data/dataset-large.json:ro")
fi

if has_test "static-h2" || has_test "static-h3"; then
    docker_args+=(-v "$DATA_DIR/static:/data/static:ro")
fi

# Allow io_uring syscalls for frameworks that need them (blocked by default seccomp)
ENGINE=$(python3 -c "import json; print(json.load(open('$META_FILE')).get('engine',''))" 2>/dev/null || true)
if [ "$ENGINE" = "io_uring" ]; then
    docker_args+=(--security-opt seccomp=unconfined)
    docker_args+=(--ulimit memlock=-1:-1)
fi

# Start Postgres sidecar if async-db is needed
if has_test "async-db"; then
    echo "[postgres] Starting Postgres sidecar for validation..."
    docker network create "$PG_NETWORK" 2>/dev/null || true
    docker rm -f "$PG_CONTAINER" 2>/dev/null || true
    docker run -d --name "$PG_CONTAINER" --network "$PG_NETWORK" \
        -e POSTGRES_USER=bench \
        -e POSTGRES_PASSWORD=bench \
        -e POSTGRES_DB=benchmark \
        -v "$DATA_DIR/pgdb-seed.sql:/docker-entrypoint-initdb.d/seed.sql:ro" \
        postgres:17-alpine
    for i in $(seq 1 30); do
        if docker exec "$PG_CONTAINER" pg_isready -U bench -d benchmark >/dev/null 2>&1; then
            echo "[postgres] Ready"
            break
        fi
        [ "$i" -eq 30 ] && { echo "FAIL: Postgres sidecar not ready"; exit 1; }
        sleep 1
    done
    docker_args+=(--network "$PG_NETWORK")
    docker_args+=(-e "DATABASE_URL=postgres://bench:bench@$PG_CONTAINER:5432/benchmark")
fi

# Remove any stale container from a previous run
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

docker run "${docker_args[@]}" "$IMAGE_NAME"

# Wait for server to start
echo "[wait] Waiting for server..."
for i in $(seq 1 30); do
    if curl -s -o /dev/null -w '' "http://localhost:$PORT/baseline11?a=1&b=1" 2>/dev/null; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "FAIL: Server did not start within 30s"
        exit 1
    fi
    sleep 1
done
echo "[ready] Server is up"

# ───── Helpers ─────

check() {
    local label="$1"
    local expected_body="$2"
    shift 2
    local response
    response=$(curl -s -D- "$@")
    local body
    body=$(echo "$response" | tail -1)

    if [ "$body" = "$expected_body" ]; then
        echo "  PASS [$label]"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [$label]: expected body '$expected_body', got '$body'"
        FAIL=$((FAIL + 1))
    fi
}

check_status() {
    local label="$1"
    local expected_status="$2"
    shift 2
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' "$@")

    if [ "$http_code" = "$expected_status" ]; then
        echo "  PASS [$label] (HTTP $http_code)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [$label]: expected HTTP $expected_status, got HTTP $http_code"
        FAIL=$((FAIL + 1))
    fi
}

check_header() {
    local label="$1"
    local header_name="$2"
    local expected_value="$3"
    shift 3
    local headers
    headers=$(curl -s -D- -o /dev/null "$@")
    local value
    value=$(echo "$headers" | grep -i "^${header_name}:" | sed 's/^[^:]*: *//' | tr -d '\r' || true)

    if [ "$value" = "$expected_value" ] || [[ "$value" == "$expected_value;"* ]]; then
        echo "  PASS [$label] ($header_name: $value)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [$label]: expected $header_name '$expected_value', got '$value'"
        FAIL=$((FAIL + 1))
    fi
}

wait_h2() {
    echo "[wait] Waiting for HTTPS port..."
    for i in $(seq 1 15); do
        if curl -sk --http2 -o /dev/null "https://localhost:$H2PORT/baseline2?a=1&b=1" 2>/dev/null; then
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

if has_test "baseline" || has_test "limited-conn"; then
    echo "[test] baseline endpoints"
    check "GET /baseline11?a=13&b=42" "55" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    check "POST /baseline11?a=13&b=42 body=20" "75" \
        -X POST -H "Content-Type: text/plain" -d "20" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    check "POST /baseline11?a=13&b=42 chunked body=20" "75" \
        -X POST -H "Content-Type: text/plain" -H "Transfer-Encoding: chunked" -d "20" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    # Anti-cheat: randomized inputs to detect hardcoded responses
    echo "[test] baseline anti-cheat (randomized inputs)"
    A1=$((RANDOM % 900 + 100))
    B1=$((RANDOM % 900 + 100))
    check "GET /baseline11?a=$A1&b=$B1 (random)" "$((A1 + B1))" \
        "http://localhost:$PORT/baseline11?a=$A1&b=$B1"

    BODY1=$((RANDOM % 900 + 100))
    BODY2=$((RANDOM % 900 + 100))
    while [ "$BODY1" -eq "$BODY2" ]; do BODY2=$((RANDOM % 900 + 100)); done
    check "POST body=$BODY1 (cache check 1)" "$((13 + 42 + BODY1))" \
        -X POST -H "Content-Type: text/plain" -d "$BODY1" \
        "http://localhost:$PORT/baseline11?a=13&b=42"
    check "POST body=$BODY2 (cache check 2)" "$((13 + 42 + BODY2))" \
        -X POST -H "Content-Type: text/plain" -d "$BODY2" \
        "http://localhost:$PORT/baseline11?a=13&b=42"
fi

# ───── Pipelined (GET /pipeline) ─────

if has_test "pipelined"; then
    echo "[test] pipelined endpoint"
    check "GET /pipeline" "ok" \
        "http://localhost:$PORT/pipeline"
fi

# ───── JSON Processing (GET /json) ─────

if has_test "json"; then
    echo "[test] json endpoint"
    response=$(curl -s "http://localhost:$PORT/json")
    json_result=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = d.get('count', 0)
items = d.get('items', [])
has_total = all('total' in item for item in items) if items else False
# Verify total is computed correctly (price * quantity, rounded to 2 decimals)
correct_totals = True
for item in items:
    expected = round(item['price'] * item['quantity'], 2)
    if abs(item.get('total', 0) - expected) > 0.01:
        correct_totals = False
        break
print(f'{count} {has_total} {correct_totals}')
" 2>/dev/null || echo "0 False False")
    json_count=$(echo "$json_result" | cut -d' ' -f1)
    json_total=$(echo "$json_result" | cut -d' ' -f2)
    json_correct=$(echo "$json_result" | cut -d' ' -f3)

    if [ "$json_count" = "50" ] && [ "$json_total" = "True" ] && [ "$json_correct" = "True" ]; then
        echo "  PASS [GET /json] (50 items, totals computed correctly)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [GET /json]: count=$json_count, has_total=$json_total, correct_totals=$json_correct"
        FAIL=$((FAIL + 1))
    fi

    # Check Content-Type header
    check_header "GET /json Content-Type" "Content-Type" "application/json" \
        "http://localhost:$PORT/json"
fi

# ───── Upload (POST /upload) ─────

if has_test "upload"; then
    echo "[test] upload endpoint"
    # Small upload: returns byte count
    UPLOAD_BODY="Hello, HttpArena!"
    EXPECTED_LEN=${#UPLOAD_BODY}
    check "POST /upload small body" "$EXPECTED_LEN" \
        -X POST -H "Content-Type: application/octet-stream" --data-binary "$UPLOAD_BODY" \
        "http://localhost:$PORT/upload"

    # Anti-cheat: random body to detect hardcoded responses
    RANDOM_BODY=$(head -c 64 /dev/urandom | base64 | head -c 48)
    EXPECTED_RANDOM_LEN=${#RANDOM_BODY}
    ACTUAL_LEN=$(curl -s -X POST -H "Content-Type: application/octet-stream" --data-binary "$RANDOM_BODY" "http://localhost:$PORT/upload")
    if [ "$ACTUAL_LEN" = "$EXPECTED_RANDOM_LEN" ]; then
        echo "  PASS [POST /upload random body] (bytes: $ACTUAL_LEN)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [POST /upload random body]: expected '$EXPECTED_RANDOM_LEN', got '$ACTUAL_LEN'"
        FAIL=$((FAIL + 1))
    fi
fi

# ───── Compression (GET /compression) ─────

if has_test "compression"; then
    echo "[test] compression endpoint"

    # Must return Content-Encoding: gzip when Accept-Encoding: gzip is sent
    comp_headers=$(curl -s -D- -o /dev/null -H "Accept-Encoding: gzip" "http://localhost:$PORT/compression")
    comp_encoding=$(echo "$comp_headers" | grep -i "^content-encoding:" | tr -d '\r' | awk '{print tolower($2)}' || true)
    if [ "$comp_encoding" = "gzip" ]; then
        echo "  PASS [compression Content-Encoding: gzip]"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [compression]: expected Content-Encoding gzip, got '$comp_encoding'"
        FAIL=$((FAIL + 1))
    fi

    # Verify compressed response is valid JSON with items and totals
    comp_response=$(curl -s --compressed -H "Accept-Encoding: gzip" "http://localhost:$PORT/compression")
    comp_result=$(echo "$comp_response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = d.get('count', 0)
items = d.get('items', [])
has_total = all('total' in item for item in items) if items else False
print(f'{count} {has_total}')
" 2>/dev/null || echo "0 False")
    comp_count=$(echo "$comp_result" | cut -d' ' -f1)
    comp_total=$(echo "$comp_result" | cut -d' ' -f2)

    if [ "$comp_count" = "6000" ] && [ "$comp_total" = "True" ]; then
        echo "  PASS [compression response] (6000 items with totals)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [compression response]: count=$comp_count, has_total=$comp_total"
        FAIL=$((FAIL + 1))
    fi

    # Verify compressed size is reasonable (should be well under 1MB uncompressed ~1MB)
    comp_size=$(curl -s -o /dev/null -w '%{size_download}' -H "Accept-Encoding: gzip" "http://localhost:$PORT/compression")
    if [ "$comp_size" -lt 500000 ]; then
        echo "  PASS [compression size] ($comp_size bytes < 500KB)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [compression size]: $comp_size bytes — compression not effective"
        FAIL=$((FAIL + 1))
    fi
fi

# ───── Noisy / Resilience (baseline + malformed requests) ─────

if has_test "noisy"; then
    echo "[test] noisy resilience"

    # Valid baseline request still works
    check "GET /baseline11?a=13&b=42 (noisy context)" "55" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    # Bad method should return 4xx (400 or 405)
    noisy_bad_method=$(curl -s -o /dev/null -w '%{http_code}' -X GETT "http://localhost:$PORT/baseline11?a=1&b=1" 2>/dev/null || echo "000")
    if [ "$noisy_bad_method" -ge 400 ] && [ "$noisy_bad_method" -lt 500 ]; then
        echo "  PASS [bad method] (HTTP $noisy_bad_method)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [bad method]: expected 4xx, got HTTP $noisy_bad_method"
        FAIL=$((FAIL + 1))
    fi

    # Nonexistent path should return 404
    check_status "GET /this/path/does/not/exist" "404" \
        "http://localhost:$PORT/this/path/does/not/exist"

    # After noise, valid request still works (server didn't crash)
    A4=$((RANDOM % 900 + 100))
    B4=$((RANDOM % 900 + 100))
    check "GET /baseline11?a=$A4&b=$B4 (post-noise)" "$((A4 + B4))" \
        "http://localhost:$PORT/baseline11?a=$A4&b=$B4"
fi

# ───── Baseline H2 (GET /baseline2 over HTTP/2 + TLS) ─────

if has_test "baseline-h2"; then
    echo "[test] baseline-h2 endpoint"
    if wait_h2; then
        # Verify server actually speaks HTTP/2
        h2_proto=$(curl -sk --http2 -o /dev/null -w '%{http_version}' "https://localhost:$H2PORT/baseline2?a=1&b=1")
        if [ "$h2_proto" = "2" ]; then
            echo "  PASS [HTTP/2 protocol negotiation] (HTTP/$h2_proto)"
            PASS=$((PASS + 1))
        else
            echo "  FAIL [HTTP/2 protocol negotiation]: server responded with HTTP/$h2_proto"
            FAIL=$((FAIL + 1))
        fi

        check "GET /baseline2?a=13&b=42 over HTTP/2" "55" \
            -sk --http2 "https://localhost:$H2PORT/baseline2?a=13&b=42"

        # Anti-cheat: randomized query params
        A3=$((RANDOM % 900 + 100))
        B3=$((RANDOM % 900 + 100))
        check "GET /baseline2?a=$A3&b=$B3 over HTTP/2 (random)" "$((A3 + B3))" \
            -sk --http2 "https://localhost:$H2PORT/baseline2?a=$A3&b=$B3"
    fi
fi

# ───── Static Files H2 (GET /static/* over HTTP/2 + TLS) ─────

if has_test "static-h2"; then
    echo "[test] static-h2 endpoint"
    if wait_h2; then
        # Check a few static files exist and return correct Content-Type
        check_header "GET /static/reset.css Content-Type" "Content-Type" "text/css" \
            -sk --http2 "https://localhost:$H2PORT/static/reset.css"

        check_header "GET /static/app.js Content-Type" "Content-Type" "application/javascript" \
            -sk --http2 "https://localhost:$H2PORT/static/app.js"

        check_header "GET /static/manifest.json Content-Type" "Content-Type" "application/json" \
            -sk --http2 "https://localhost:$H2PORT/static/manifest.json"

        # Check response size is non-zero
        static_size=$(curl -sk --http2 -o /dev/null -w '%{size_download}' "https://localhost:$H2PORT/static/reset.css")
        if [ "$static_size" -gt 0 ]; then
            echo "  PASS [static-h2 response size] ($static_size bytes)"
            PASS=$((PASS + 1))
        else
            echo "  FAIL [static-h2 response size]: empty response"
            FAIL=$((FAIL + 1))
        fi

        # 404 for missing files
        check_status "GET /static/nonexistent.txt" "404" \
            -sk --http2 "https://localhost:$H2PORT/static/nonexistent.txt"
    fi
fi

# ───── Async Database (GET /pgdb) ─────

if has_test "async-db"; then
    echo "[test] async-db endpoint"
    response=$(curl -s "http://localhost:$PORT/pgdb?min=10&max=50")
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

    if [ "$pgdb_count" -gt 0 ] && [ "$pgdb_count" -le 50 ] && [ "$pgdb_rating" = "True" ] && [ "$pgdb_tags" = "True" ] && [ "$pgdb_active" = "True" ]; then
        echo "  PASS [GET /pgdb?min=10&max=50] ($pgdb_count items, correct structure)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [GET /pgdb?min=10&max=50]: count=$pgdb_count, rating=$pgdb_rating, tags=$pgdb_tags, active=$pgdb_active"
        FAIL=$((FAIL + 1))
    fi

    check_header "GET /pgdb Content-Type" "Content-Type" "application/json" \
        "http://localhost:$PORT/pgdb?min=10&max=50"

    # Anti-cheat: empty range should return 0 items
    response_empty=$(curl -s "http://localhost:$PORT/pgdb?min=9999&max=9999")
    pgdb_empty=$(echo "$response_empty" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count','-1'))" 2>/dev/null || echo "-1")
    if [ "$pgdb_empty" = "0" ]; then
        echo "  PASS [GET /pgdb empty range] (count=0)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [GET /pgdb empty range]: expected count=0, got $pgdb_empty"
        FAIL=$((FAIL + 1))
    fi
fi

# ───── Summary ─────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
