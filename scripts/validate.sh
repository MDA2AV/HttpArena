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

# Build
echo "[build] Building Docker image..."
if [ -x "frameworks/$FRAMEWORK/build.sh" ]; then
    "frameworks/$FRAMEWORK/build.sh" || { echo "FAIL: Docker build failed"; exit 1; }
else
    docker build -t "$IMAGE_NAME" "frameworks/$FRAMEWORK" || { echo "FAIL: Docker build failed"; exit 1; }
fi

# Mount volumes based on subscribed tests
HARD_NOFILE=$(ulimit -Hn)
if has_test "async-db" || has_test "mixed" || has_test "api-4" || has_test "api-16"; then
    docker_args=(-d --name "$CONTAINER_NAME" --network host --security-opt seccomp=unconfined
        --ulimit memlock=-1:-1 --ulimit nofile="$HARD_NOFILE:$HARD_NOFILE")
else
    docker_args=(-d --name "$CONTAINER_NAME" -p "$PORT:8080"
        --ulimit memlock=-1:-1 --ulimit nofile="$HARD_NOFILE:$HARD_NOFILE")
fi
docker_args+=(-v "$DATA_DIR/dataset.json:/data/dataset.json:ro")

needs_h2=false
if has_test "baseline-h2" || has_test "static-h2" || has_test "baseline-h3" || has_test "static-h3"; then
    needs_h2=true
fi

if $needs_h2 && [ -d "$CERTS_DIR" ]; then
    docker_args+=(-p "$H2PORT:8443" -v "$CERTS_DIR:/certs:ro")
fi

if has_test "compression" || has_test "mixed"; then
    docker_args+=(-v "$DATA_DIR/dataset-large.json:/data/dataset-large.json:ro")
fi

if has_test "mixed" || has_test "sync-db"; then
    DB_FILE="$DATA_DIR/benchmark.db"
    if [ ! -f "$DB_FILE" ]; then
        echo "[db] benchmark.db not found, generating..."
        python3 "$SCRIPT_DIR/generate-db.py" "$DATA_DIR/dataset.json" "$DB_FILE"
    fi
    docker_args+=(-v "$DB_FILE:/data/benchmark.db:ro")
fi

if has_test "static" || has_test "static-h2" || has_test "static-h3" || has_test "mixed"; then
    docker_args+=(-v "$DATA_DIR/static:/data/static:ro")
fi

# Allow io_uring syscalls for frameworks that need them (blocked by default seccomp)
ENGINE=$(python3 -c "import json; print(json.load(open('$META_FILE')).get('engine',''))" 2>/dev/null || true)
if [ "$ENGINE" = "io_uring" ]; then
    docker_args+=(--security-opt seccomp=unconfined)
    docker_args+=(--ulimit memlock=-1:-1)
fi

# Start Postgres sidecar if async-db or mixed is needed
if has_test "async-db" || has_test "mixed" || has_test "api-4" || has_test "api-16"; then
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

# Remove any stale container from a previous run
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

if has_test "baseline" || has_test "limited-conn" || has_test "mixed" || has_test "api-4" || has_test "api-16"; then
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

if has_test "json" || has_test "mixed" || has_test "api-4" || has_test "api-16"; then
    JSON_DOCS="$DOCS_BASE/h1/isolated/json-processing/validation"
    echo "[test] json endpoint"
    response=$(curl -s --max-time 30 "http://localhost:$PORT/json")
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
        fail_with_link "[GET /json]: count=$json_count, has_total=$json_total, correct_totals=$json_correct" "$JSON_DOCS"
    fi

    # Check Content-Type header
    check_header "GET /json Content-Type" "Content-Type" "application/json" "$JSON_DOCS" \
        "http://localhost:$PORT/json"
fi

# ───── Upload (POST /upload) ─────

if has_test "upload" || has_test "mixed"; then
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

    # Large upload: 20 MB binary payload
    LARGE_SIZE=20971520
    ACTUAL_LARGE=$(dd if=/dev/urandom bs=1M count=20 2>/dev/null | curl -s --max-time 60 -X POST -H "Content-Type: application/octet-stream" --data-binary @- "http://localhost:$PORT/upload")
    if [ "$ACTUAL_LARGE" = "$LARGE_SIZE" ]; then
        echo "  PASS [POST /upload 20MB] (bytes: $ACTUAL_LARGE)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[POST /upload 20MB]: expected '$LARGE_SIZE', got '$ACTUAL_LARGE'" "$UPLOAD_DOCS"
    fi
fi

# ───── Compression (GET /compression) ─────

if has_test "compression" || has_test "mixed"; then
    COMP_DOCS="$DOCS_BASE/h1/isolated/compression/validation"
    echo "[test] compression endpoint"

    # Must return Content-Encoding: gzip when Accept-Encoding: gzip is sent
    comp_headers=$(curl -s --max-time 30 -D- -o /dev/null -H "Accept-Encoding: gzip" "http://localhost:$PORT/compression")
    comp_encoding=$(echo "$comp_headers" | grep -i "^content-encoding:" | sed 's/^[^:]*: *//' | tr -d '\r' | awk '{print tolower($1)}' || true)
    if [ "$comp_encoding" = "gzip" ]; then
        echo "  PASS [compression Content-Encoding: gzip]"
        PASS=$((PASS + 1))
    else
        fail_with_link "[compression]: expected Content-Encoding gzip, got '$comp_encoding'" "$COMP_DOCS"
    fi

    # Verify compressed response is valid JSON with items and totals
    comp_response=$(curl -s --max-time 30 --compressed -H "Accept-Encoding: gzip" "http://localhost:$PORT/compression")
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
        fail_with_link "[compression response]: count=$comp_count, has_total=$comp_total" "$COMP_DOCS"
    fi

    # Verify compressed size is reasonable (should be well under 1MB uncompressed ~1MB)
    comp_size=$(curl -s --max-time 30 -o /dev/null -w '%{size_download}' -H "Accept-Encoding: gzip" "http://localhost:$PORT/compression")
    if [ "$comp_size" -lt 500000 ]; then
        echo "  PASS [compression size] ($comp_size bytes < 500KB)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[compression size]: $comp_size bytes — compression not effective" "$COMP_DOCS"
    fi

    # Verify compression happens per-request (not pre-compressed cache)
    # Request without Accept-Encoding: gzip must NOT return Content-Encoding: gzip
    no_enc_headers=$(curl -s --max-time 30 -D- -o /dev/null "http://localhost:$PORT/compression")
    no_enc_encoding=$(echo "$no_enc_headers" | grep -i "^content-encoding:" | sed 's/^[^:]*: *//' | tr -d '\r' | awk '{print tolower($1)}' || true)
    if [ -z "$no_enc_encoding" ]; then
        echo "  PASS [per-request compression] (no Content-Encoding without Accept-Encoding)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[per-request compression]: got Content-Encoding: $no_enc_encoding without Accept-Encoding — compression must happen per request, not pre-compressed" "$COMP_DOCS"
    fi
fi

# ───── Noisy / Resilience (baseline + malformed requests) ─────

if has_test "noisy"; then
    NOISY_DOCS="$DOCS_BASE/h1/isolated/noisy/validation"
    echo "[test] noisy resilience"

    # Valid baseline request still works
    check "GET /baseline11?a=13&b=42 (noisy context)" "55" "$NOISY_DOCS" \
        "http://localhost:$PORT/baseline11?a=13&b=42"

    # Bad method should return 4xx (400 or 405)
    noisy_bad_method=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -X GETT "http://localhost:$PORT/baseline11?a=1&b=1" 2>/dev/null || echo "000")
    if [ "$noisy_bad_method" -ge 400 ] && [ "$noisy_bad_method" -lt 500 ]; then
        echo "  PASS [bad method] (HTTP $noisy_bad_method)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[bad method]: expected 4xx, got HTTP $noisy_bad_method" "$NOISY_DOCS"
    fi

    # Nonexistent path should return 404
    check_status "GET /this/path/does/not/exist" "404" "$NOISY_DOCS" \
        "http://localhost:$PORT/this/path/does/not/exist"

    # After noise, valid request still works (server didn't crash)
    A4=$((RANDOM % 900 + 100))
    B4=$((RANDOM % 900 + 100))
    check "GET /baseline11?a=$A4&b=$B4 (post-noise)" "$((A4 + B4))" "$NOISY_DOCS" \
        "http://localhost:$PORT/baseline11?a=$A4&b=$B4"
fi

# ───── DB (GET /db — SQLite, tested when framework has mixed test) ─────

if has_test "mixed"; then
    DB_DOCS="$DOCS_BASE/h1/isolated/database/validation"
    echo "[test] db endpoint (mixed test prerequisite)"
    response=$(curl -s --max-time 30 "http://localhost:$PORT/db?min=10&max=50")
    db_result=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = d.get('count', 0)
items = d.get('items', [])
has_rating = all('rating' in item and 'score' in item['rating'] for item in items) if items else False
has_tags = all(isinstance(item.get('tags'), list) for item in items) if items else False
has_active_bool = all(isinstance(item.get('active'), bool) for item in items) if items else False
print(f'{count} {has_rating} {has_tags} {has_active_bool}')
" 2>/dev/null || echo "0 False False False")
    db_count=$(echo "$db_result" | cut -d' ' -f1)
    db_rating=$(echo "$db_result" | cut -d' ' -f2)
    db_tags=$(echo "$db_result" | cut -d' ' -f3)
    db_active=$(echo "$db_result" | cut -d' ' -f4)

    if [ "$db_count" -gt 0 ] && [ "$db_count" -le 50 ] && [ "$db_rating" = "True" ] && [ "$db_tags" = "True" ] && [ "$db_active" = "True" ]; then
        echo "  PASS [GET /db?min=10&max=50] ($db_count items, correct structure)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[GET /db?min=10&max=50]: count=$db_count, rating=$db_rating, tags=$db_tags, active=$db_active" "$DB_DOCS"
    fi

    check_header "GET /db Content-Type" "Content-Type" "application/json" "$DB_DOCS" \
        "http://localhost:$PORT/db?min=10&max=50"

    # Anti-cheat: empty range should return 0 items
    response_empty=$(curl -s --max-time 30 "http://localhost:$PORT/db?min=9999&max=9999")
    db_empty=$(echo "$response_empty" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count','-1'))" 2>/dev/null || echo "-1")
    if [ "$db_empty" = "0" ]; then
        echo "  PASS [GET /db empty range] (count=0)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[GET /db empty range]: expected count=0, got $db_empty" "$DB_DOCS"
    fi
fi

# ───── Sync DB (GET /db — SQLite) ─────

if has_test "sync-db"; then
    DB_DOCS="$DOCS_BASE/h1/isolated/database/validation"
    echo "[test] sync-db endpoint"
    response=$(curl -s --max-time 30 "http://localhost:$PORT/db?min=10&max=50")
    db_result=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = d.get('count', 0)
items = d.get('items', [])
has_rating = all('rating' in item and 'score' in item['rating'] for item in items) if items else False
has_tags = all(isinstance(item.get('tags'), list) for item in items) if items else False
has_active_bool = all(isinstance(item.get('active'), bool) for item in items) if items else False
print(f'{count} {has_rating} {has_tags} {has_active_bool}')
" 2>/dev/null || echo "0 False False False")
    db_count=$(echo "$db_result" | cut -d' ' -f1)
    db_rating=$(echo "$db_result" | cut -d' ' -f2)
    db_tags=$(echo "$db_result" | cut -d' ' -f3)
    db_active=$(echo "$db_result" | cut -d' ' -f4)

    if [ "$db_count" -gt 0 ] && [ "$db_count" -le 50 ] && [ "$db_rating" = "True" ] && [ "$db_tags" = "True" ] && [ "$db_active" = "True" ]; then
        echo "  PASS [GET /db?min=10&max=50] ($db_count items, correct structure)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[GET /db?min=10&max=50]: count=$db_count, rating=$db_rating, tags=$db_tags, active=$db_active" "$DB_DOCS"
    fi

    check_header "GET /db Content-Type" "Content-Type" "application/json" "$DB_DOCS" \
        "http://localhost:$PORT/db?min=10&max=50"

    # Anti-cheat: empty range should return 0 items
    response_empty=$(curl -s --max-time 30 "http://localhost:$PORT/db?min=9999&max=9999")
    db_empty=$(echo "$response_empty" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count','-1'))" 2>/dev/null || echo "-1")
    if [ "$db_empty" = "0" ]; then
        echo "  PASS [GET /db empty range] (count=0)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[GET /db empty range]: expected count=0, got $db_empty" "$DB_DOCS"
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

if has_test "static" || has_test "mixed"; then
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

if has_test "async-db" || has_test "mixed" || has_test "api-4" || has_test "api-16"; then
    ASYNCDB_DOCS="$DOCS_BASE/h1/isolated/async-database/validation"
    echo "[test] async-db endpoint"
    response=$(curl -s --max-time 30 "http://localhost:$PORT/async-db?min=10&max=50")
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
        echo "  PASS [GET /async-db?min=10&max=50] ($pgdb_count items, correct structure)"
        PASS=$((PASS + 1))
    else
        fail_with_link "[GET /async-db?min=10&max=50]: count=$pgdb_count, rating=$pgdb_rating, tags=$pgdb_tags, active=$pgdb_active" "$ASYNCDB_DOCS"
    fi

    check_header "GET /async-db Content-Type" "Content-Type" "application/json" "$ASYNCDB_DOCS" \
        "http://localhost:$PORT/async-db?min=10&max=50"

    # Anti-cheat: empty range should return 0 items
    response_empty=$(curl -s --max-time 30 "http://localhost:$PORT/async-db?min=9999&max=9999")
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

# ───── Summary ─────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
