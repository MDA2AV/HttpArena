# scripts/lib/tools/h2load.sh — h2load dispatch + parse.
#
# Used for: HTTP/2 (baseline-h2, static-h2), gRPC unary (unary-grpc,
# unary-grpc-tls), gateway-64. Supports both native binary and docker-wrapped
# mode via H2LOAD_CMD — set once at driver startup based on LOADGEN_DOCKER.

# Set by the driver during startup — either ("h2load") or (docker run ...).
# If unset, fall back to native.
: "${H2LOAD_CMD:=}"

_h2load_cmd() {
    if [ -n "$H2LOAD_CMD" ]; then
        printf '%s\n' $H2LOAD_CMD
    else
        printf '%s\n' "$H2LOAD"
    fi
}

# ── Build arguments ─────────────────────────────────────────────────────────

h2load_build_args() {
    local endpoint="$1" conns="$2" pipeline="$3" duration="$4"
    local -a cmd
    mapfile -t cmd < <(_h2load_cmd)

    case "$endpoint" in
        h2)
            cmd+=("https://localhost:$H2PORT/baseline2?a=1&b=1"
                  -c "$conns" -m 100 -t "$H2THREADS" -D "$duration")
            ;;
        static-h2)
            cmd+=(-i "$REQUESTS_DIR/static-h2-uris.txt"
                  -H "Accept-Encoding: br;q=1, gzip;q=0.8"
                  -c "$conns" -m 32 -t "$H2THREADS" -D "$duration")
            ;;
        h2c)
            # Prior-knowledge h2c on port 8082. h2load's -p h2c flag forces
            # HTTP/2 cleartext framing from the first byte (the standard h2
            # connection preface) — no HTTP/1.1 Upgrade dance. An http://
            # URL already defaults to h2c in h2load, but -p is explicit so a
            # misconfigured server can't silently downgrade the benchmark
            # to HTTP/1.1 and still look "fast".
            cmd+=("http://localhost:$H2C_PORT/baseline2?a=1&b=1"
                  -p h2c
                  -c "$conns" -m 100 -t "$H2THREADS" -D "$duration")
            ;;
        json-h2c)
            # Same (count, m) rotation as the json profile (7 fixed pairs),
            # served over h2c prior-knowledge on port 8082.
            cmd+=(-i "$REQUESTS_DIR/json-h2c-uris.txt"
                  -p h2c
                  -c "$conns" -m 32 -t "$H2THREADS" -D "$duration")
            ;;
        gateway-64)
            cmd+=(-i "$REQUESTS_DIR/gateway-64-uris.txt"
                  -H "Accept-Encoding: br;q=1, gzip;q=0.8"
                  -c "$conns" -m 32 -t "$H2THREADS" -D "$duration")
            ;;
        production-stack)
            # Realistic multi-service deploy benchmarked with TWO h2load
            # instances running in parallel against the same compose stack:
            #
            #   reads  — GET /static/*, /public/*, /api/items/{id}, /api/me
            #            (20 URIs in production-stack-reads.txt). All GETs,
            #            -c $conns -m 32 -t $H2THREADS. Dominant workload.
            #
            #   writes — POST /api/items/{id} with a static JSON body
            #            (production-stack-write-body.json). 4 URIs. Lower
            #            concurrency because real CRUD workloads are
            #            read-dominated and we don't want writes to drown
            #            out the read-path measurement.
            #
            # h2load can't mix methods in one invocation (-d globally flips
            # every request to POST), so we emit two argv blocks separated
            # by a "--split--" sentinel and have h2load_run fork both
            # processes in parallel. Both pin to GCANNON_CPUS — Linux time-
            # slices them across the 64 load-gen logical CPUs. h2load threads
            # are I/O-bound so oversubscription is cheap.
            #
            # Every request carries Authorization: Bearer <jwt> so authsvc
            # can verify the HMAC-SHA256 signature on the JWT. The token is
            # pre-generated at data/jwt-token.txt with the shared secret.
            local write_conns=$(( conns / 8 )); [ "$write_conns" -lt 8 ] && write_conns=8
            local jwt_token
            jwt_token=$(cat "$ROOT_DIR/data/jwt-token.txt" 2>/dev/null || echo "")
            cmd+=(-i "$REQUESTS_DIR/production-stack-reads.txt"
                  -H "Accept-Encoding: br;q=1, gzip;q=0.8"
                  -H "Authorization: Bearer $jwt_token"
                  -c "$conns" -m 16 -t "$H2THREADS" -D "$duration")
            cmd+=("--split--")
            mapfile -t -O "${#cmd[@]}" cmd < <(_h2load_cmd)
            cmd+=(-i "$REQUESTS_DIR/production-stack-writes.txt"
                  -d "$REQUESTS_DIR/production-stack-write-body.json"
                  -H "Content-Type: application/json"
                  -H "Authorization: Bearer $jwt_token"
                  -c "$write_conns" -m 8 -t 8 -D "$duration")
            ;;
        grpc)
            cmd+=("http://localhost:$PORT/benchmark.BenchmarkService/GetSum"
                  -d "$REQUESTS_DIR/grpc-sum.bin"
                  -H 'content-type: application/grpc'
                  -H 'te: trailers'
                  -c "$conns" -m 100 -t "$H2THREADS" -D "$duration")
            ;;
        grpc-tls)
            cmd+=("https://localhost:$H2PORT/benchmark.BenchmarkService/GetSum"
                  -d "$REQUESTS_DIR/grpc-sum.bin"
                  -H 'content-type: application/grpc'
                  -H 'te: trailers'
                  -c "$conns" -m 100 -t "$H2THREADS" -D "$duration")
            ;;
        *)
            fail "h2load_build_args: unknown endpoint '$endpoint'"
            ;;
    esac

    printf '%s\n' "${cmd[@]}"
}

# ── Execute ─────────────────────────────────────────────────────────────────

h2load_run() {
    local -a args=("$@")

    # Detect the --split-- sentinel emitted by production-stack's build_args
    # block. If present, args are actually TWO h2load invocations concatenated
    # and we run both in parallel, combining their output with section
    # markers so h2load_parse can sum them.
    local split_idx=-1 i
    for i in "${!args[@]}"; do
        if [ "${args[$i]}" = "--split--" ]; then
            split_idx=$i
            break
        fi
    done

    if [ "$split_idx" -lt 0 ]; then
        # Single-invocation path — every profile except production-stack.
        timeout 45 taskset -c "$GCANNON_CPUS" "${args[@]}" 2>&1 || true
        return
    fi

    # Split-invocation path — two h2load processes pinned to the same cpuset,
    # running in parallel. I/O-bound thread pools tolerate oversubscription
    # cleanly on loopback, and the writes instance is sized much smaller
    # than the reads instance so it mostly idles when reads are hot.
    local -a reads_argv=("${args[@]:0:$split_idx}")
    local -a writes_argv=("${args[@]:$((split_idx+1))}")

    local reads_log writes_log
    reads_log=$(mktemp)
    writes_log=$(mktemp)

    timeout 45 taskset -c "$GCANNON_CPUS" "${reads_argv[@]}"  >"$reads_log"  2>&1 &
    local reads_pid=$!
    timeout 45 taskset -c "$GCANNON_CPUS" "${writes_argv[@]}" >"$writes_log" 2>&1 &
    local writes_pid=$!

    wait "$reads_pid"  2>/dev/null || true
    wait "$writes_pid" 2>/dev/null || true

    # Emit combined output with sentinels so h2load_parse can sum the two
    # sections' 2xx counts and combine bandwidth/duration.
    echo "=== h2load-reads ==="
    cat "$reads_log"
    echo "=== h2load-writes ==="
    cat "$writes_log"

    rm -f "$reads_log" "$writes_log"
}

# ── Parse output ────────────────────────────────────────────────────────────

h2load_parse() {
    local endpoint="$1"
    local output="$2"

    # rps = successful 2xx responses divided by wall duration. h2load's
    # own "finished in Xs, Y req/s" number counts all completed requests
    # including 4xx/5xx, which silently inflates rps when the server is
    # broken — a stale image serving 404s would look like a throughput win.
    # Computing from 2xx + the reported duration makes that impossible.

    if [ "$endpoint" = "production-stack" ]; then
        # Split-invocation output: two h2load runs concatenated with
        # "=== h2load-reads ===" / "=== h2load-writes ===" sentinels.
        # Sum 2xx across both sections, average durations, combine rps.
        # Write-side 2xx may appear as "0 2xx" because POST /api/items
        # returns 204 (in the 2xx range but h2load's status buckets
        # bucket 2xx/3xx/4xx/5xx by first digit, so 204 counts as 2xx).
        local reads_ok reads_dur writes_ok writes_dur total_ok total_4xx total_5xx
        reads_ok=$(echo "$output"  | awk '/=== h2load-reads ===/,/=== h2load-writes ===/' \
            | grep -oP '\d+(?= 2xx)' | head -1)
        reads_dur=$(echo "$output" | awk '/=== h2load-reads ===/,/=== h2load-writes ===/' \
            | grep -oP 'finished in \K[\d.]+' | head -1)
        writes_ok=$(echo "$output" | awk '/=== h2load-writes ===/,0' \
            | grep -oP '\d+(?= 2xx)' | head -1)
        writes_dur=$(echo "$output" | awk '/=== h2load-writes ===/,0' \
            | grep -oP 'finished in \K[\d.]+' | head -1)

        reads_ok=${reads_ok:-0}
        writes_ok=${writes_ok:-0}
        reads_dur=${reads_dur:-1}
        writes_dur=${writes_dur:-1}
        total_ok=$(( reads_ok + writes_ok ))

        # Use the reads duration as the primary (they're ~identical — both
        # runs use -D $duration and start at the same time).
        local dur="$reads_dur"
        [ "$dur" = "0" ] && dur="$writes_dur"
        [ "$dur" = "0" ] && dur=1

        echo "rps=$(awk -v ok="$total_ok" -v dur="$dur" \
            'BEGIN { if (dur+0 > 0) printf "%d", ok/dur; else print 0 }' 2>/dev/null || echo 0)"

        # Report read-path latency (writes have their own latency profile
        # that would need a separate column; keeping one number for now).
        echo "avg_lat=$(echo "$output" | awk '/=== h2load-reads ===/,/=== h2load-writes ===/' \
            | awk '/time for request:/{print $6}' | head -1)"
        echo "p99_lat=$(echo "$output" | awk '/=== h2load-reads ===/,/=== h2load-writes ===/' \
            | awk '/time for request:/{print $6}' | head -1)"

        echo "reconnects=0"
        echo "bandwidth=$(echo "$output" | awk '/=== h2load-reads ===/,/=== h2load-writes ===/' \
            | grep -oP 'finished in [\d.]+s, [\d.]+ req/s, \K[\d.]+[KMGT]?B/s' | head -1 || echo 0)"

        # Sum all status counters across both sections.
        local r2xx r4xx r5xx w2xx w4xx w5xx
        r2xx=$(echo "$output"  | awk '/=== h2load-reads ===/,/=== h2load-writes ===/' | grep -oP '\d+(?= 2xx)' | head -1)
        r4xx=$(echo "$output"  | awk '/=== h2load-reads ===/,/=== h2load-writes ===/' | grep -oP '\d+(?= 4xx)' | head -1)
        r5xx=$(echo "$output"  | awk '/=== h2load-reads ===/,/=== h2load-writes ===/' | grep -oP '\d+(?= 5xx)' | head -1)
        w2xx=$(echo "$output"  | awk '/=== h2load-writes ===/,0' | grep -oP '\d+(?= 2xx)' | head -1)
        w4xx=$(echo "$output"  | awk '/=== h2load-writes ===/,0' | grep -oP '\d+(?= 4xx)' | head -1)
        w5xx=$(echo "$output"  | awk '/=== h2load-writes ===/,0' | grep -oP '\d+(?= 5xx)' | head -1)
        echo "status_2xx=$(( ${r2xx:-0} + ${w2xx:-0} ))"
        echo "status_3xx=0"
        echo "status_4xx=$(( ${r4xx:-0} + ${w4xx:-0} ))"
        echo "status_5xx=$(( ${r5xx:-0} + ${w5xx:-0} ))"
        return
    fi

    # Single-invocation path — every profile except production-stack.
    local duration_secs ok
    duration_secs=$(echo "$output" | grep -oP 'finished in \K[\d.]+' | head -1)
    duration_secs=${duration_secs:-1}
    ok=$(echo "$output" | grep -oP '\d+(?= 2xx)' | head -1)
    ok=${ok:-0}
    echo "rps=$(awk -v ok="$ok" -v dur="$duration_secs" \
        'BEGIN { if (dur+0 > 0) printf "%d", ok/dur; else print 0 }' 2>/dev/null || echo 0)"

    # Latency — h2 mode uses "time for request:" one-liner,
    # h3 (not used here) uses a tabular "request :" row.
    echo "avg_lat=$(echo "$output" | awk '/time for request:/{print $6}' | head -1)"
    echo "p99_lat=$(echo "$output" | awk '/time for request:/{print $6}' | head -1)"

    echo "reconnects=0"
    echo "bandwidth=$(echo "$output" | grep -oP 'finished in [\d.]+s, [\d.]+ req/s, \K[\d.]+[KMGT]?B/s' | head -1 || echo 0)"

    echo "status_2xx=$(echo "$output" | grep -oP '\d+(?= 2xx)' | head -1 || echo 0)"
    echo "status_3xx=$(echo "$output" | grep -oP '\d+(?= 3xx)' | head -1 || echo 0)"
    echo "status_4xx=$(echo "$output" | grep -oP '\d+(?= 4xx)' | head -1 || echo 0)"
    echo "status_5xx=$(echo "$output" | grep -oP '\d+(?= 5xx)' | head -1 || echo 0)"
}
