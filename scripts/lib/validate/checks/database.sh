# checks/database.sh — async-db, fortunes, crud
# Part of the validate.sh suite — sourced by scripts/validate.sh, not run directly.

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

# ───── Fortunes (GET /fortunes) — template-engine benchmark ─────
#
# Feature-based validation, not byte-exact. Engines disagree on whitespace
# and attribute formatting; what matters is that the rendered HTML actually
# loops the DB rows, includes the runtime-injected row, escapes user
# content, and is sized like a real page (not stripped to win the bench).

if has_test "fortunes"; then
    FORTUNES_DOCS="$DOCS_BASE/h1/isolated/fortunes/validation"
    echo "[test] fortunes endpoint"

    body=$(curl -s --max-time 30 "http://localhost:$PORT/fortunes" || true)

    check_header "GET /fortunes Content-Type" "Content-Type" "text/html" "$FORTUNES_DOCS" \
        "http://localhost:$PORT/fortunes"

    if echo "$body" | grep -qi '<!doctype html>'; then
        echo "  PASS [GET /fortunes <!DOCTYPE html>]"
        PASS=$((PASS + 1))
    else
        fail_with_link "[GET /fortunes <!DOCTYPE html>]: missing — layout/partial likely not rendered" "$FORTUNES_DOCS"
    fi

    # Each row in the rendered table must produce a <tr>. 201 data rows are
    # required (200 seeded + 1 runtime-injected); a header row is allowed
    # but not required, so the band is 201–210 to absorb implementation-
    # specific extras (footer rows, etc.).
    tr_count=$(echo "$body" | grep -oi '<tr' | wc -l)
    if [ "$tr_count" -ge 201 ] && [ "$tr_count" -le 210 ]; then
        echo "  PASS [GET /fortunes <tr> count=$tr_count]"
        PASS=$((PASS + 1))
    else
        fail_with_link "[GET /fortunes <tr> count]: expected 201–210, got $tr_count" "$FORTUNES_DOCS"
    fi

    # Runtime-injected row text — proves the handler appended id=0 in memory
    # rather than caching a pre-rendered page from the DB rows alone.
    if echo "$body" | grep -qF 'Additional fortune added at request time.'; then
        echo "  PASS [GET /fortunes runtime-injected row]"
        PASS=$((PASS + 1))
    else
        fail_with_link "[GET /fortunes runtime-injected row]: missing 'Additional fortune added at request time.'" "$FORTUNES_DOCS"
    fi

    # XSS escape — load-bearing check. Row 11 contains a raw <script> tag
    # in the DB; the rendered output must encode it as &lt;script&gt; and
    # must NOT contain the raw <script>alert sequence anywhere.
    if echo "$body" | grep -qF '&lt;script&gt;' && ! echo "$body" | grep -qF '<script>alert'; then
        echo "  PASS [GET /fortunes XSS escape]"
        PASS=$((PASS + 1))
    else
        fail_with_link "[GET /fortunes XSS escape]: <script> in row 11 not properly HTML-escaped" "$FORTUNES_DOCS"
    fi

    # Size sanity — catches stripped pages and empty bodies. A 201-row
    # table plus a layout typically lands between 18 KB and 40 KB; the band
    # is generous to absorb whitespace and per-engine formatting, but
    # rejects empty / fragment / pathologically-large outputs.
    size=${#body}
    if [ "$size" -ge 18432 ] && [ "$size" -le 65536 ]; then
        echo "  PASS [GET /fortunes body size=${size}B]"
        PASS=$((PASS + 1))
    else
        fail_with_link "[GET /fortunes body size]: expected 18432–65536 bytes, got $size" "$FORTUNES_DOCS"
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


# keep `source` exit status 0 so the orchestrator continues (set -e stays active inside)
true
