# scripts/lib/tools/gcannon.sh — gcannon (io_uring) dispatch + parse.
#
# gcannon handles HTTP/1.1, --raw multi-template rotation, --ws WebSocket,
# and gRPC plaintext (indirectly via -H and -d, though we use h2load for
# that in practice). This file owns the gcannon ↔ driver interface.

# ── Build arguments ─────────────────────────────────────────────────────────

# Usage: gcannon_build_args <endpoint> <conns> <pipeline> <duration> [req_per_conn]
# Emits one token per line — caller captures with `mapfile -t gc_args`.
#
# req_per_conn is only honored for endpoints that don't hardcode their own -r.
# Today that's the empty (baseline/limited-conn) and api-4/api-16 cases.
gcannon_build_args() {
    local endpoint="$1" conns="$2" pipeline="$3" duration="$4" req_per_conn="${5:-0}"
    local -a args

    case "$endpoint" in
        "")  # default: baseline / limited-conn
            # Mixed GET / POST-Content-Length / POST-Transfer-Encoding:chunked
            # rotation, matching the "Mixed GET/POST with query parsing" README
            # description and validate.sh's three-shape correctness suite.
            args=("http://localhost:$PORT"
                  --raw "$REQUESTS_DIR/get.raw,$REQUESTS_DIR/post_cl.raw,$REQUESTS_DIR/post_chunked.raw"
                  -c "$conns" -t "$THREADS" -d "$duration" -p "$pipeline")
            [ "$req_per_conn" -gt 0 ] 2>/dev/null && args+=(-r "$req_per_conn")
            ;;
        pipeline)
            args=("http://localhost:$PORT/pipeline"
                  -c "$conns" -t "$THREADS" -d "$duration" -p "$pipeline")
            ;;
        upload)
            args=("http://localhost:$PORT"
                  --raw "$REQUESTS_DIR/upload-500k.raw,$REQUESTS_DIR/upload-2m.raw,$REQUESTS_DIR/upload-10m.raw,$REQUESTS_DIR/upload-20m.raw"
                  -c "$conns" -t "$THREADS" -d "$duration" -p "$pipeline" -r 5)
            ;;
        api-4|api-16)
            args=("http://localhost:$PORT"
                  --raw "$REQUESTS_DIR/get.raw,$REQUESTS_DIR/get.raw,$REQUESTS_DIR/get.raw,$REQUESTS_DIR/json-get.raw,$REQUESTS_DIR/json-get.raw,$REQUESTS_DIR/json-get.raw,$REQUESTS_DIR/async-db-get.raw,$REQUESTS_DIR/async-db-get.raw"
                  -c "$conns" -t 64 -d 15s -p "$pipeline")
            [ "$req_per_conn" -gt 0 ] 2>/dev/null && args+=(-r "$req_per_conn")
            ;;
        async-db)
            args=("http://localhost:$PORT"
                  --raw "$REQUESTS_DIR/async-db-5.raw,$REQUESTS_DIR/async-db-10.raw,$REQUESTS_DIR/async-db-20.raw,$REQUESTS_DIR/async-db-35.raw,$REQUESTS_DIR/async-db-50.raw"
                  -c "$conns" -t "$THREADS" -d 10s -p "$pipeline" -r 25)
            ;;
        json)
            args=("http://localhost:$PORT"
                  --raw "$REQUESTS_DIR/json-1.raw,$REQUESTS_DIR/json-5.raw,$REQUESTS_DIR/json-10.raw,$REQUESTS_DIR/json-15.raw,$REQUESTS_DIR/json-25.raw,$REQUESTS_DIR/json-40.raw,$REQUESTS_DIR/json-50.raw"
                  -c "$conns" -t "$THREADS" -d "$duration" -p "$pipeline" -r 25)
            ;;
        json-compressed)
            args=("http://localhost:$PORT"
                  --raw "$REQUESTS_DIR/json-gzip-1.raw,$REQUESTS_DIR/json-gzip-5.raw,$REQUESTS_DIR/json-gzip-10.raw,$REQUESTS_DIR/json-gzip-15.raw,$REQUESTS_DIR/json-gzip-25.raw,$REQUESTS_DIR/json-gzip-40.raw,$REQUESTS_DIR/json-gzip-50.raw"
                  -c "$conns" -t "$THREADS" -d "$duration" -p "$pipeline" -r 25)
            ;;
        ws-echo)
            args=("http://localhost:$PORT/ws" --ws
                  -c "$conns" -t "$THREADS" -d "$duration" -p "$pipeline")
            ;;
        crud)
            # CRUD mix: 75% single-item read + 15% update + 5% list + 5% create.
            # Template counts (20 total): 15 gets, 3 updates, 1 list, 1 create.
            # Create path uses {SEQ:100001} monotonic IDs; iteration 1 is pure
            # INSERT, iterations 2+ become upserts via ON CONFLICT DO UPDATE
            # because gcannon's SEQ counter resets per invocation.
            # List queries always hit DB (two queries: data + count). Single-item
            # reads are cached in-process with 1s TTL. Uses {RAND} and {SEQ}
            # placeholders for realistic ID distribution. -r req_per_conn forces
            # reconnection every N requests so gcannon rotates through the
            # template list — without it, fast templates dominate because each
            # keep-alive connection sticks to one template.
            local _crud_files=""
            for f in $(ls "$REQUESTS_DIR"/crud-list-*.raw "$REQUESTS_DIR"/crud-get-*.raw \
                         "$REQUESTS_DIR"/crud-create-*.raw "$REQUESTS_DIR"/crud-update-*.raw 2>/dev/null | sort); do
                _crud_files="${_crud_files:+$_crud_files,}$f"
            done
            args=("http://localhost:$PORT"
                  --raw "$_crud_files"
                  -c "$conns" -t "$THREADS" -d 15s -p "$pipeline")
            [ "$req_per_conn" -gt 0 ] 2>/dev/null && args+=(-r "$req_per_conn")
            ;;
        *)
            fail "gcannon_build_args: unknown endpoint '$endpoint'"
            ;;
    esac

    printf '%s\n' "${args[@]}"
}

# ── Execute ─────────────────────────────────────────────────────────────────

# Run gcannon with the given args, return output on stdout.
# Honors GCANNON_MODE=native|docker.
gcannon_run() {
    local -a args=("$@")
    if [ "$GCANNON_MODE" = "native" ]; then
        timeout 45 taskset -c "$GCANNON_CPUS" \
            env LD_LIBRARY_PATH=/usr/lib "$GCANNON" "${args[@]}" 2>&1 || true
    else
        timeout 45 docker run --rm --network host \
            --cpuset-cpus="$GCANNON_CPUS" \
            --security-opt seccomp=unconfined \
            --ulimit memlock=-1:-1 --ulimit nofile=1048576:1048576 \
            -v "$REQUESTS_DIR:$REQUESTS_DIR:ro" \
            "$GCANNON_IMAGE" "${args[@]}" 2>&1 || true
    fi
}

# ── Parse output ────────────────────────────────────────────────────────────

# Usage: gcannon_parse <endpoint> <output>
# Echoes KEY=VALUE lines. Caller reads into an assoc array.
gcannon_parse() {
    local endpoint="$1" output="$2"

    # rps — compute from 2xx (or 3xx for caching, or WS frames for ws-echo)
    # divided by the actual measured duration ghz-style.
    #
    # grep + head don't fail on empty input, so their fallbacks never fire —
    # the `:-` default on the variable itself is what guarantees a number.
    #
    # The "summary" line is the single source of truth across gcannon
    # versions and modes. Its shape is one of:
    #
    #   <req>  requests     in <dur>s, <resp>  responses       (plain http)
    #   <req>  frames sent  in <dur>s, <resp>  frames received (--ws, new gcannon)
    #
    # We pull <dur> from the middle field and <resp> (the *second* number on
    # the line) from the tail. For ws-echo we use <resp> directly as the
    # received-frame count; for everything else we take 2xx/3xx as before.
    local duration_secs ok
    duration_secs=$(echo "$output" | grep -oP '(?:requests|frames sent) in \K[\d.]+' | head -1)
    duration_secs=${duration_secs:-1}

    case "$endpoint" in
        caching)
            ok=$(echo "$output" | grep -oP '3xx=\K\d+' | head -1)
            ;;
        ws-echo)
            # Prefer the "N (responses|frames received)" tail of the summary
            # line — present in every gcannon version. Fall back to the
            # explicit "WS frames:" / "2xx=" counters if that regex misses.
            ok=$(echo "$output" | grep -oP '\d+\s+(?:responses|frames received)' | head -1 | grep -oP '\d+')
            [ -z "$ok" ] && ok=$(echo "$output" | grep -oP 'WS frames:\s*\K\d+' | head -1)
            [ -z "$ok" ] && ok=$(echo "$output" | grep -oP '2xx=\K\d+' | head -1)
            ;;
        *)
            ok=$(echo "$output" | grep -oP '2xx=\K\d+' | head -1)
            ;;
    esac
    ok=${ok:-0}

    echo "rps=$(awk -v ok="$ok" -v dur="$duration_secs" \
        'BEGIN { if (dur+0 > 0) printf "%d", ok/dur; else print 0 }' 2>/dev/null || echo 0)"
    echo "avg_lat=$(echo "$output" | grep "Latency" | head -1 | awk '{print $2}')"
    echo "p99_lat=$(echo "$output" | grep "Latency" | head -1 | awk '{print $5}')"
    echo "reconnects=$(echo "$output" | grep -oP 'Reconnects: \K\d+' | head -1 || echo 0)"
    echo "bandwidth=$(echo "$output" | grep -oP 'Bandwidth:\s+\K\S+' | head -1 || echo 0)"

    if [ "$endpoint" = "ws-echo" ]; then
        # Reuse the same "responses|frames received" fallback cascade used
        # above for the rps computation.
        local ws_total
        ws_total=$(echo "$output" | grep -oP '\d+\s+(?:responses|frames received)' | head -1 | grep -oP '\d+')
        [ -z "$ws_total" ] && ws_total=$(echo "$output" | grep -oP 'WS frames:\s*\K\d+' | head -1)
        [ -z "$ws_total" ] && ws_total=$(echo "$output" | grep -oP '2xx=\K\d+' | head -1)
        echo "status_2xx=${ws_total:-0}"
        echo "status_3xx=0"; echo "status_4xx=0"; echo "status_5xx=0"
    else
        echo "status_2xx=$(echo "$output" | grep -oP '2xx=\K\d+' | head -1 || echo 0)"
        echo "status_3xx=$(echo "$output" | grep -oP '3xx=\K\d+' | head -1 || echo 0)"
        echo "status_4xx=$(echo "$output" | grep -oP '4xx=\K\d+' | head -1 || echo 0)"
        echo "status_5xx=$(echo "$output" | grep -oP '5xx=\K\d+' | head -1 || echo 0)"
    fi

    # Per-template response counts — only gcannon emits these, and today
    # only api-4 / api-16 read them (mixed-template workload). The template
    # order here must stay in sync with gcannon_build_args for api-4/api-16:
    #   get, get, get, json-get, json-get, json-get, async-db-get, async-db-get
    if [ "$endpoint" = "api-4" ] || [ "$endpoint" = "api-16" ]; then
        local tpl_line
        tpl_line=$(echo "$output" | grep -oP 'Per-template-ok: \K.*' | head -1)
        if [ -n "$tpl_line" ]; then
            IFS=',' read -ra _tpl <<< "$tpl_line"
            echo "tpl_baseline=$(( ${_tpl[0]:-0} + ${_tpl[1]:-0} + ${_tpl[2]:-0} ))"
            echo "tpl_json=$(( ${_tpl[3]:-0} + ${_tpl[4]:-0} + ${_tpl[5]:-0} ))"
            echo "tpl_async_db=$(( ${_tpl[6]:-0} + ${_tpl[7]:-0} ))"
        fi
    fi
}
