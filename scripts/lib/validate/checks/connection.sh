# checks/connection.sh — baseline, pipelined
# Part of the validate.sh suite — sourced by scripts/validate.sh, not run directly.

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


# keep `source` exit status 0 so the orchestrator continues (set -e stays active inside)
true
