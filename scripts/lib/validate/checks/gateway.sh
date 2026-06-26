# checks/gateway.sh — gateway-64, gateway-h3, production-stack
# Part of the validate.sh suite — sourced by scripts/validate.sh, not run directly.

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
        local gw_json_response gw_json_result gw_json_count gw_json_valid gw_json_correct
        gw_json_response=$(curl -sk --max-time 30 --http2 "https://localhost:$GW_PORT/json/50" || true)
        gw_json_result=$(echo "$gw_json_response" | python3 -c "
import sys, json
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
    expected = round(item.get('price', 0) * item.get('quantity', 0), 2)
    if abs(item.get('total', 0) - expected) > 0.02:
        correct_totals = False
        break
print(f'{count} {valid} {correct_totals}')
" 2>/dev/null || echo "0 False False")
        gw_json_count=$(echo "$gw_json_result" | cut -d' ' -f1)
        gw_json_valid=$(echo "$gw_json_result" | cut -d' ' -f2)
        gw_json_correct=$(echo "$gw_json_result" | cut -d' ' -f3)

        if [ "$gw_json_count" = "50" ] && [ "$gw_json_valid" = "True" ] && [ "$gw_json_correct" = "True" ]; then
            echo "  PASS [gateway /json] (50 items, full schema, totals correct)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[gateway /json]: count=$gw_json_count, schema=$gw_json_valid, correct=$gw_json_correct" "$gateway_docs"
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
        "$DOCS_BASE/gateway/gateway-h2/validation"
fi

# ───── Gateway H3 (h3/QUIC at the edge) ─────

if has_test "gateway-h3"; then
    _validate_gateway "gateway-h3" \
        "$ROOT_DIR/frameworks/$FRAMEWORK/compose.gateway-h3.yml" \
        "$DOCS_BASE/gateway/gateway-h3/validation"
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
        local gw_json_response gw_json_result gw_json_count gw_json_valid gw_json_correct
        gw_json_response=$(curl -sk --max-time 30 --http2 "https://localhost:$GW_PORT/public/json/25" || true)
        gw_json_result=$(echo "$gw_json_response" | python3 -c "
import sys, json
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
    expected = round(item.get('price', 0) * item.get('quantity', 0), 2)
    if abs(item.get('total', 0) - expected) > 0.02:
        correct_totals = False
        break
print(f'{count} {valid} {correct_totals}')
" 2>/dev/null || echo "0 False False")
        gw_json_count=$(echo "$gw_json_result" | cut -d' ' -f1)
        gw_json_valid=$(echo "$gw_json_result" | cut -d' ' -f2)
        gw_json_correct=$(echo "$gw_json_result" | cut -d' ' -f3)

        if [ "$gw_json_count" = "25" ] && [ "$gw_json_valid" = "True" ] && [ "$gw_json_correct" = "True" ]; then
            echo "  PASS [$profile /public/json/25] (25 items, full schema, totals correct)"
            PASS=$((PASS + 1))
        else
            fail_with_link "[$profile /public/json/25]: count=$gw_json_count, schema=$gw_json_valid, correct=$gw_json_correct" "$docs_url"
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
        "$DOCS_BASE/gateway/production-stack/validation"
fi


# keep `source` exit status 0 so the orchestrator continues (set -e stays active inside)
true
