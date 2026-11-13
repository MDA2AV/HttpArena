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

h2load_check_version() {
    if [ "${H2LOAD_VERSION_CHECKED:-false}" = true ]; then return 0; fi
    local -a cmd
    local version
    mapfile -t cmd < <(_h2load_cmd)
    version=$("${cmd[@]}" --version) || return 1
    if [[ ! "$version" =~ nghttp2/([0-9]+)\.([0-9]+)\.([0-9]+) ]] \
        || (( BASH_REMATCH[1] < 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] < 69) )); then
        echo "h2load >= 1.69.0 is required: older clients can run forever after -D expires during connection setup. Update H2LOAD or build docker/h2load.Dockerfile." >&2
        return 1
    fi
    echo "[info] $version"
    H2LOAD_VERSION_CHECKED=true
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
        local exit_code=0
        timeout 45 taskset -c "$GCANNON_CPUS" "${args[@]}" 2>&1 || exit_code=$?
        return "$exit_code"
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

    local reads_exit=0 writes_exit=0
    wait "$reads_pid"  2>/dev/null || reads_exit=$?
    wait "$writes_pid" 2>/dev/null || writes_exit=$?

    # Emit combined output with sentinels so h2load_parse can sum the two
    # sections' completed requests and validate both runs.
    echo "=== h2load-reads ==="
    cat "$reads_log"
    echo "=== h2load-writes ==="
    cat "$writes_log"

    rm -f "$reads_log" "$writes_log"
    if [ "$reads_exit" -ne 0 ]; then return "$reads_exit"; fi
    return "$writes_exit"
}

# ── Parse output ────────────────────────────────────────────────────────────

h2load_parse() {
    python3 "${BASH_SOURCE[0]%/*}/h2load_parse.py" "$1" <<< "$2"
}
