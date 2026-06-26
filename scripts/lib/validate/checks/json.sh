# checks/json.sh — json, json-comp, json-tls
# Part of the validate.sh suite — sourced by scripts/validate.sh, not run directly.

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
print(f'{count} {valid} {correct_totals}')
" 2>/dev/null || echo "0 False False")
        json_count=$(echo "$json_result" | cut -d' ' -f1)
        json_valid=$(echo "$json_result" | cut -d' ' -f2)
        json_correct=$(echo "$json_result" | cut -d' ' -f3)

        if [ "$json_count" = "$jcount" ] && [ "$json_valid" = "True" ] && [ "$json_correct" = "True" ]; then
            :
        else
            fail_with_link "[GET /json/$jcount?m=$jm]: count=$json_count, schema=$json_valid, correct_totals=$json_correct" "$JSON_DOCS"
            json_fail=true
        fi
    done
    if [ "$json_fail" = "false" ]; then
        echo "  PASS [GET /json/{count}?m=X] (4 counts × multipliers + full item schema verified)"
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
    jc_params=("25:3" "40:7" "50:2")
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
print(f'{count} {valid} {correct_totals}')
" 2>/dev/null || echo "0 False False")
        jc_count=$(echo "$jc_result" | cut -d' ' -f1)
        jc_valid=$(echo "$jc_result" | cut -d' ' -f2)
        jc_correct=$(echo "$jc_result" | cut -d' ' -f3)

        if [ "$jc_count" = "$jccount" ] && [ "$jc_valid" = "True" ] && [ "$jc_correct" = "True" ]; then
            :
        else
            fail_with_link "[json-comp /json/$jccount?m=$jcm]: count=$jc_count, schema=$jc_valid, correct=$jc_correct" "$JSONCOMP_DOCS"
            jc_fail=true
        fi
    done
    if [ "$jc_fail" = "false" ]; then
        echo "  PASS [json-comp response] (3 counts × multipliers, compressed, full item schema)"
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
print(f'{count} {valid} {correct_totals}')
" 2>/dev/null || echo "0 False False")
        jt_count=$(echo "$jt_result" | cut -d' ' -f1)
        jt_valid=$(echo "$jt_result" | cut -d' ' -f2)
        jt_correct=$(echo "$jt_result" | cut -d' ' -f3)

        if [ "$jt_count" = "$jtcount" ] && [ "$jt_valid" = "True" ] && [ "$jt_correct" = "True" ]; then
            :
        else
            fail_with_link "[json-tls /json/$jtcount?m=$jtm]: count=$jt_count, schema=$jt_valid, correct=$jt_correct" "$JSONTLS_DOCS"
            jt_fail=true
        fi
    done
    if [ "$jt_fail" = "false" ]; then
        echo "  PASS [json-tls response] (3 (count, m) pairs over TLS, full item schema)"
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


# keep `source` exit status 0 so the orchestrator continues (set -e stays active inside)
true
