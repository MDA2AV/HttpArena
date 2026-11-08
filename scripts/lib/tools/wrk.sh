# scripts/lib/tools/wrk.sh — wrk dispatch + parse.
#
# Used for: static files (with a Lua rotation script for multi-URI workloads),
# json-tls and 8gbit (same pattern, TLS port). wrk is the sweet spot for
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
        static-tls)
            cmd+=(-t "$THREADS" -c "$conns" -d "$duration"
                  -s "$REQUESTS_DIR/static-rotate.lua"
                  "https://localhost:$H1TLS_PORT")
            ;;
        json-tls)
            cmd+=(-t "$THREADS" -c "$conns" -d "$duration"
                  -s "$REQUESTS_DIR/json-tls-rotate.lua"
                  "https://localhost:$H1TLS_PORT")
            ;;
        8gbit)
            # POST /echo, 100 KB in and the same 100 KB back. wrk reports only
            # the bytes it READ, so the Transfer/sec it prints is the download
            # half; the input half is reconstructed in benchmark.sh from
            # rps x ECHO_BODY_BYTES.
            cmd+=(-t "$THREADS" -c "$conns" -d "$duration"
                  -s "$REQUESTS_DIR/8gbit-rotate.lua"
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

    # "X requests in Ys, ZGB read", plus "Non-2xx or 3xx responses: N" when
    # any response had a status of 400 or above. wrk does not split those into
    # 4xx and 5xx, so they are all reported as 4xx.
    local total_reqs failed_reqs ok_reqs
    total_reqs=$(echo "$output" | grep -oP '(\d+) requests in' | grep -oP '\d+' | head -1 || true)
    total_reqs=${total_reqs:-0}
    failed_reqs=$(echo "$output" | grep -oP 'Non-2xx or 3xx responses:\s+\K\d+' | head -1 || true)
    failed_reqs=${failed_reqs:-0}
    ok_reqs=$(( total_reqs > failed_reqs ? total_reqs - failed_reqs : 0 ))

    # "Requests/sec: 1283707.14", which counts every response. Scaled down to
    # the successful share, the same rule h2load's rps follows: an entry that
    # answers 404 for a file it cannot find -- the percent-encoded one in
    # static-tls, say -- must not be paid for the cheap 404s.
    local raw_rps
    raw_rps=$(echo "$output" | grep -oP 'Requests/sec:\s+\K[\d.]+' | head -1 || true)
    echo "rps=$(awk -v r="${raw_rps:-0}" -v ok="$ok_reqs" -v t="$total_reqs" \
        'BEGIN { printf "%d", (t > 0 ? r * ok / t : r) }')"

    # "Latency   3.70ms    8.37ms 279.91ms   96.41%" — avg=$2, stdev=$3, max=$4.
    # wrk exposes no percentiles without --latency, so use max ($4) as the tail.
    local lat
    lat=$(echo "$output" | grep "Latency" | head -1)
    echo "avg_lat=$(echo "$lat" | awk '{print $2}')"
    echo "p99_lat=$(echo "$lat" | awk '{print $4}')"

    echo "reconnects=0"
    echo "bandwidth=$(echo "$output" | grep -oP 'Transfer/sec:\s+\K\S+' | head -1 || echo 0)"

    echo "status_2xx=$ok_reqs"
    echo "status_3xx=0"; echo "status_4xx=$failed_reqs"; echo "status_5xx=0"
}
