# checks/upload.sh — upload
# Part of the validate.sh suite — sourced by scripts/validate.sh, not run directly.

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


# keep `source` exit status 0 so the orchestrator continues (set -e stays active inside)
true
