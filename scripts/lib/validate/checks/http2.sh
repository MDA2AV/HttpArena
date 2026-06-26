# checks/http2.sh — baseline-h2, baseline-h2c, json-h2c
# Part of the validate.sh suite — sourced by scripts/validate.sh, not run directly.

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
m = $jm
d = json.load(sys.stdin)
count = d.get('count', -1)
items = d.get('items', [])
items_n = len(items)
def valid_item(it):
    r = it.get('rating')
    return ('id' in it and 'name' in it and 'category' in it and 'price' in it
            and 'quantity' in it and 'total' in it
            and isinstance(it.get('tags'), list) and isinstance(it.get('active'), bool)
            and isinstance(r, dict) and 'score' in r and 'count' in r)
valid = all(valid_item(it) for it in items) if items else False
correct_totals = True
for item in items:
    expected = item.get('price', 0) * item.get('quantity', 0) * m
    if item.get('total', 0) != expected:
        correct_totals = False
        break
print(f'{count} {items_n} {valid} {correct_totals}')
" 2>/dev/null || echo "-1 -1 False False")
        pc=$(echo "$parsed" | cut -d' ' -f1)
        pn=$(echo "$parsed" | cut -d' ' -f2)
        pv=$(echo "$parsed" | cut -d' ' -f3)
        ptot=$(echo "$parsed" | cut -d' ' -f4)
        if [ "$pc" = "$jcount" ] && [ "$pn" = "$jcount" ] && [ "$pv" = "True" ] && [ "$ptot" = "True" ]; then
            :
        else
            fail_with_link "[GET /json/$jcount?m=$jm (h2c)]: count=$pc, items=$pn, schema=$pv, correct_totals=$ptot, expected $jcount" "$JSON_H2C_DOCS"
            json_h2c_fail=true
        fi
    done
    if [ "$json_h2c_fail" = "false" ]; then
        echo "  PASS [GET /json/{count}?m=X over h2c] (4 counts × multipliers, full item schema + totals)"
        PASS=$((PASS + 1))
    fi
fi


# keep `source` exit status 0 so the orchestrator continues (set -e stays active inside)
true
