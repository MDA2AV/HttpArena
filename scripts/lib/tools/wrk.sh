# scripts/lib/tools/wrk.sh — wrk dispatch + parse.
#
# Used for: static files (with a Lua rotation script for multi-URI workloads)
# and json-tls (same pattern, TLS port). wrk is the sweet spot for
# multi-URI HTTP/1.1 tests because its Lua scripting is tiny and the output
# parser is trivial.

: "${WRK_CMD:=}"

_wrk_cmd() {
    if [ -n "$WRK_CMD" ]; then
        printf '%s\n' $WRK_CMD
    else
        printf '%s\n' "$WRK"
    fi
}

# ── Build arguments ─────────────────────────────────────────────────────────

wrk_build_args() {
    local endpoint="$1" conns="$2" pipeline="$3" duration="$4"
    local -a cmd
    mapfile -t cmd < <(_wrk_cmd)

    case "$endpoint" in
        static)
            cmd+=(-t "$THREADS" -c "$conns" -d "$duration"
                  -s "$REQUESTS_DIR/static-rotate.lua"
                  "http://localhost:$PORT")
            ;;
        json-tls)
            cmd+=(-t "$THREADS" -c "$conns" -d "$duration"
                  -s "$REQUESTS_DIR/json-tls-rotate.lua"
                  "https://localhost:$H1TLS_PORT")
            ;;
        *)
            fail "wrk_build_args: unknown endpoint '$endpoint'"
            ;;
    esac

    printf '%s\n' "${cmd[@]}"
}

wrk_run() {
    timeout 45 taskset -c "$GCANNON_CPUS" "$@" 2>&1 || true
}

# ── Parse output ────────────────────────────────────────────────────────────

wrk_parse() {
    local output="$2"

    # "Requests/sec: 1283707.14"
    echo "rps=$(echo "$output" | grep -oP 'Requests/sec:\s+\K[\d.]+' | cut -d. -f1 || echo 0)"

    # "Latency   3.70ms    8.37ms 279.91ms   96.41%" — avg=$2, stdev=$3, max=$4.
    # wrk exposes no percentiles without --latency, so use max ($4) as the tail.
    local lat
    lat=$(echo "$output" | grep "Latency" | head -1)
    echo "avg_lat=$(echo "$lat" | awk '{print $2}')"
    echo "p99_lat=$(echo "$lat" | awk '{print $4}')"

    echo "reconnects=0"
    echo "bandwidth=$(echo "$output" | grep -oP 'Transfer/sec:\s+\K\S+' | head -1 || echo 0)"

    # wrk only knows "X requests in Ys, ZGB read" — all are treated as 2xx.
    local total_reqs
    total_reqs=$(echo "$output" | grep -oP '(\d+) requests in' | grep -oP '\d+' | head -1 || echo 0)
    echo "status_2xx=$total_reqs"
    echo "status_3xx=0"; echo "status_4xx=0"; echo "status_5xx=0"
}
