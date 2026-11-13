# scripts/lib/tools/h2load-h3.sh — h2load built with ngtcp2 for HTTP/3.
#
# Shares the same binary family as h2load but runs with --alpn-list=h3 to
# negotiate HTTP/3 over QUIC. The shared parser accepts both old summary
# tables and the newer tables with latency percentiles.

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
    timeout 45 taskset -c "$GCANNON_CPUS" "$@" 2>&1
}

# ── Parse output ────────────────────────────────────────────────────────────

h2load_h3_parse() {
    python3 "${BASH_SOURCE[0]%/*}/h2load_parse.py" "$1" <<< "$2"
}
