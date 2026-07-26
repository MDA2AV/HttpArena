# scripts/lib/tools/ghz.sh — ghz dispatch + parse.
#
# Used for: gRPC server-streaming (stream-grpc, stream-grpc-tls). Unlike
# h2load (which ships raw h2 frames with pre-serialized gRPC bodies), ghz
# is a real gRPC client that marshals protobuf per call — giving us
# protocol-correct numbers for streaming workloads.
#
# The reported rps is **messages per second**, not calls per second:
# rps = (OK_calls / duration_seconds) × msgs_per_call.
# That normalizes streaming throughput against unary call counts.

# Configured by the dispatcher — read by other functions in this module.
GHZ_MSGS_PER_CALL=5000
GHZ_TARGET=""
GHZ_TLS_FLAG=""
GHZ_WORKERS=0

# Set by the driver in docker mode to a full `docker run ...` prefix.
# Empty in native mode — we fall back to the $GHZ binary.
: "${GHZ_CMD:=}"

_ghz_cmd() {
    if [ -n "$GHZ_CMD" ]; then
        printf '%s\n' $GHZ_CMD
    else
        printf '%s\n' "$GHZ"
    fi
}

# ── Build arguments ─────────────────────────────────────────────────────────

ghz_build_args() {
    local endpoint="$1" conns="$2" _pipeline="$3" duration="$4"

    # 4 streams multiplexed per TCP connection; empirically the cleanest
    # shape under TLS with count=5000 (~8.6M msgs/sec, <2% error rate).
    GHZ_WORKERS=$((conns * 4))
    GHZ_MSGS_PER_CALL=5000

    if [[ "$endpoint" == *-tls ]]; then
        GHZ_TARGET="localhost:$H2PORT"
        GHZ_TLS_FLAG="--skipTLS"
    else
        GHZ_TARGET="localhost:$PORT"
        GHZ_TLS_FLAG="--insecure"
    fi

    local -a cmd
    mapfile -t cmd < <(_ghz_cmd)
    cmd+=(
        "$GHZ_TLS_FLAG"
        --proto "$REQUESTS_DIR/benchmark.proto"
        --call benchmark.BenchmarkService/StreamSum
        -d "{\"a\":1,\"b\":2,\"count\":$GHZ_MSGS_PER_CALL}"
        --connections "$conns" -c "$GHZ_WORKERS"
        -z "$duration"
        "$GHZ_TARGET"
    )
    printf '%s\n' "${cmd[@]}"
}

# Warm-up run before the real best-of-N loop. Lets Kestrel's thread pool
# and accept loop come up to temperature so run 1 doesn't burst into a
# cold backlog. Output is discarded.
ghz_warmup() {
    info "ghz warm-up 2s"
    local -a cmd
    mapfile -t cmd < <(_ghz_cmd)
    cmd+=(
        "$GHZ_TLS_FLAG"
        --proto "$REQUESTS_DIR/benchmark.proto"
        --call benchmark.BenchmarkService/StreamSum
        -d "{\"a\":1,\"b\":2,\"count\":$GHZ_MSGS_PER_CALL}"
        --connections "$1" -c "$GHZ_WORKERS"
        -z 2s "$GHZ_TARGET"
    )
    taskset -c "$GCANNON_CPUS" "${cmd[@]}" >/dev/null 2>&1 || true
}

ghz_run() {
    timeout 45 taskset -c "$GCANNON_CPUS" "$@" 2>&1 || true
}

# ── Parse output ────────────────────────────────────────────────────────────

ghz_parse() {
    local output="$2"
    local dur_s=${DURATION%s}

    # Count ONLY successful calls. ghz's own "Requests/sec" counts everything
    # including [Unavailable] / [Canceled] errors which inflates during burst
    # overloads. Using [OK] N / duration × msgs_per_call gives an honest number.
    local ok_count
    ok_count=$(echo "$output" | grep -oP '\[OK\]\s+\K\d+' | head -1 || echo 0)

    if [ "$dur_s" -gt 0 ] 2>/dev/null; then
        echo "rps=$(awk "BEGIN { printf \"%d\", ($ok_count / $dur_s) * $GHZ_MSGS_PER_CALL }")"
    else
        echo "rps=0"
    fi

    echo "avg_lat=$(echo "$output" | awk '/^\s*Average:/ { print $2 $3; exit }')"
    # ghz reports real percentiles; use the 99th line, falling back to Slowest (max).
    local p99
    p99=$(echo "$output" | awk '/^[[:space:]]*99(\.[0-9]+)? % in /{print $4 $5; exit}')
    [ -z "$p99" ] && p99=$(echo "$output" | awk '/^[[:space:]]*Slowest:/{print $2 $3; exit}')
    echo "p99_lat=$p99"
    echo "reconnects=0"
    echo "bandwidth=0"

    echo "status_2xx=$ok_count"
    echo "status_3xx=0"; echo "status_4xx=0"
    echo "status_5xx=$(echo "$output" | grep -oP '\[Unavailable\]\s+\K\d+' | head -1 || echo 0)"
}
