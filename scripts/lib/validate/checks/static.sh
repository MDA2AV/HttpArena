# checks/static.sh — static (H1), static-h2
# Part of the validate.sh suite — sourced by scripts/validate.sh, not run directly.

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

    # Anti-pre-cache: mutate the file on disk mid-run and require the change to show.
    check_static_freshness "static freshness (no pre-caching)" "$STATIC_DOCS" "http://localhost:$PORT"
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

        # Anti-pre-cache: only run here if the H1 static test didn't already (h2-only entries).
        if ! has_test "static"; then
            check_static_freshness "static-h2 freshness (no pre-caching)" "$STATIC_H2_DOCS" "https://localhost:$H2PORT" -k --http2
        fi
    fi
fi


# keep `source` exit status 0 so the orchestrator continues (set -e stays active inside)
true
