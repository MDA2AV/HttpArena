# scripts/lib/tools/h2load-h3.sh — h2load built with ngtcp2 for HTTP/3.
#
# Shares the same binary family as h2load but runs with --alpn-list=h3 to
# negotiate HTTP/3 over QUIC. Output format differs from plain h2load — the
# latency table uses "request :" instead of "time for request:".

: "${H2LOAD_H3_CMD:=}"

_h2load_h3_cmd() {
    if [ -n "$H2LOAD_H3_CMD" ]; then
        printf '%s\n' $H2LOAD_H3_CMD
    else
        printf '%s\n' "$H2LOAD_H3"
    fi
}

# ── Build arguments ─────────────────────────────────────────────────────────

h2load_h3_build_args() {
    local endpoint="$1" conns="$2" pipeline="$3" duration="$4"
    local -a cmd
    mapfile -t cmd < <(_h2load_h3_cmd)
    cmd+=(--alpn-list=h3)

    case "$endpoint" in
        h3)
            cmd+=("https://localhost:$H2PORT/baseline2?a=1&b=1"
                  -c "$conns" -m 64 -t "$H3THREADS" -D "$duration")
            ;;
        static-h3)
            cmd+=(-i "$REQUESTS_DIR/static-h2-uris.txt"
                  -H "Accept-Encoding: br;q=1, gzip;q=0.8"
                  -c "$conns" -m 64 -t "$H3THREADS" -D "$duration")
            ;;
        gateway-h3)
            # Same URIs and mix as gateway-64 (30 static / 20 baseline /
            # 35 json / 15 async-db) — the only difference is we're pushing
            # it over QUIC through whatever h3-capable proxy the entry ships.
            cmd+=(-i "$REQUESTS_DIR/gateway-64-uris.txt"
                  -H "Accept-Encoding: br;q=1, gzip;q=0.8"
                  -c "$conns" -m 32 -t "$H3THREADS" -D "$duration")
            ;;
        *)
            fail "h2load_h3_build_args: unknown endpoint '$endpoint'"
            ;;
    esac

    printf '%s\n' "${cmd[@]}"
}

h2load_h3_run() {
    timeout 45 taskset -c "$GCANNON_CPUS" "$@" 2>&1 || true
}

# ── Parse output ────────────────────────────────────────────────────────────

h2load_h3_parse() {
    local output="$2"  # $1 = endpoint unused

    # rps from 2xx/duration — see h2load.sh for rationale (avoid inflating
    # rps when the server is serving 4xx/5xx responses).
    local duration_secs ok
    duration_secs=$(echo "$output" | grep -oP 'finished in \K[\d.]+' | head -1)
    duration_secs=${duration_secs:-1}
    ok=$(echo "$output" | grep -oP '\d+(?= 2xx)' | head -1)
    ok=${ok:-0}
    echo "rps=$(awk -v ok="$ok" -v dur="$duration_secs" \
        'BEGIN { if (dur+0 > 0) printf "%d", ok/dur; else print 0 }' 2>/dev/null || echo 0)"

    # h3 emits a tabular "request :" line with mean at column 8 and p99 at col 7.
    echo "avg_lat=$(echo "$output" | awk '/^\s*request\s*:/ { print $8; exit }')"
    echo "p99_lat=$(echo "$output" | awk '/^\s*request\s*:/ { print $7; exit }')"

    echo "reconnects=0"
    echo "bandwidth=$(echo "$output" | grep -oP 'finished in [\d.]+s, [\d.]+ req/s, \K[\d.]+[KMGT]?B/s' | head -1 || echo 0)"

    echo "status_2xx=$(echo "$output" | grep -oP '\d+(?= 2xx)' | head -1 || echo 0)"
    echo "status_3xx=$(echo "$output" | grep -oP '\d+(?= 3xx)' | head -1 || echo 0)"
    echo "status_4xx=$(echo "$output" | grep -oP '\d+(?= 4xx)' | head -1 || echo 0)"
    echo "status_5xx=$(echo "$output" | grep -oP '\d+(?= 5xx)' | head -1 || echo 0)"
}
