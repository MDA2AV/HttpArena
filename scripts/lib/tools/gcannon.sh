# scripts/lib/tools/gcannon.sh — gcannon (io_uring) dispatch + parse.
#
# gcannon handles HTTP/1.1, --raw multi-template rotation, --ws WebSocket,
# and gRPC plaintext (indirectly via -H and -d, though we use h2load for
# that in practice). This file owns the gcannon ↔ driver interface.

# connections-5m: five million keep-alive connections
# with 1.25M req/s paced over them, one request per connection every four
# seconds, so what is left to measure is what holding the rest of the fleet
# costs. Four seconds stays inside the 5s keep-alive default of Node, uvicorn
# and actix: at five (1M req/s) actix's timeouts raced every request, 51,410
# reconnects at 16,000 connections against none at four. Needs gcannon >= 0.8.2
# (--rate with every thread spread over the interval, --addr-span,
# --connect-limit, --warmup-max, --settle); scripts/conn_hold.py checks.
#
# One source address holds ~64.5K connections to one destination, so the
# fleet spans 127.0.0.1-127.0.0.CONN5M_ADDRS (31,250 on each of 160, the
# density the million-connection runs held). First connects are capped per
# thread so five million SYNs never land at once, and the warmup waits for all
# of them to open: up to CONN5M_WARMUP_MAX. The load then runs CONN5M_SETTLE
# more seconds before the 20s window opens: genhttp-ioxide's first 5M run,
# measured from the moment the last connection opened, answered 670K more
# requests in the window than were sent in it (p50 10 ms, p90 390 ms) - the
# connect phase's backlog, not the steady state.
GCANNON_RATE_CONNECTIONS_5M="${GCANNON_RATE_CONNECTIONS_5M:-1250000}"
CONN5M_ADDRS="${CONN5M_ADDRS:-160}"
CONN5M_CONNECT_LIMIT="${CONN5M_CONNECT_LIMIT:-64}"
CONN5M_WARMUP_MAX="${CONN5M_WARMUP_MAX:-300}"
CONN5M_SETTLE="${CONN5M_SETTLE:-30}"

# connections-1m-tls: the same over TLS 1.3, at a million connections and
# 250K req/s - the same four-second interval - over 127.0.0.1-.32, the same
# 31,250 per address. The warmup may take longer, since every connection also
# handshakes; gcannon >= 0.8.4 holds each --connect-limit slot until the
# handshake is done, so the server never has more than 64 per client thread
# waiting (MDA2AV/gcannon#33). It shares CONN5M_CONNECT_LIMIT and CONN5M_SETTLE.
GCANNON_RATE_CONNECTIONS_1M_TLS="${GCANNON_RATE_CONNECTIONS_1M_TLS:-250000}"
CONN1M_TLS_ADDRS="${CONN1M_TLS_ADDRS:-32}"
CONN1M_TLS_WARMUP_MAX="${CONN1M_TLS_WARMUP_MAX:-900}"

# connections-ramp-h1: a fleet that grows to 2M over two minutes, 95% of it
# idle. CONNRAMP_FLOOR active connections open in the warmup and carry the offered
# rate for CONNRAMP_SETTLE seconds, which warms the server up (JIT, caches, heaps)
# before anything counts: there is one run of it, not a best-of (benchmark.sh).
# Over CONNRAMP_UP seconds the rest of the active ones and all of the idle ones
# then open evenly,
# inside the measured window (CONNRAMP_WINDOW: the ramp, plus ten seconds that
# show the fleet standing). The active ones carry GCANNON_RATE_CONNECTIONS_RAMP
# throughout, paced by thread so the total does not depend on how many are
# open. The idle ones send one request and are never used or reopened, so a
# server that times them out shows it (gcannon >= 0.10.0: --ramp-up, --idle).
# The p99 limit is not gcannon's: conn_hold.py finds where the interval lines
# cross CONNRAMP_P99_US and reports how many connections it took to get there.
GCANNON_RATE_CONNECTIONS_RAMP="${GCANNON_RATE_CONNECTIONS_RAMP:-100000}"
CONNRAMP_FLOOR="${CONNRAMP_FLOOR:-4096}"
CONNRAMP_UP="${CONNRAMP_UP:-120}"
CONNRAMP_WINDOW="${CONNRAMP_WINDOW:-130}"
CONNRAMP_IDLE="${CONNRAMP_IDLE:-95%}"
CONNRAMP_ADDRS="${CONNRAMP_ADDRS:-64}"
CONNRAMP_P99_US="${CONNRAMP_P99_US:-2000}"
CONNRAMP_CONNECT_LIMIT="${CONNRAMP_CONNECT_LIMIT:-64}"
CONNRAMP_WARMUP_MAX="${CONNRAMP_WARMUP_MAX:-60}"
CONNRAMP_SETTLE="${CONNRAMP_SETTLE:-30}"

# ── Build arguments ─────────────────────────────────────────────────────────

# Usage: gcannon_build_args <endpoint> <conns> <pipeline> <duration> [req_per_conn]
# Emits one token per line — caller captures with `mapfile -t gc_args`.
#
# req_per_conn is only honored for endpoints that don't hardcode their own -r.
# Today that's the empty (baseline/limited-conn) and ws-echo (echo-ws-limited)
# cases.
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
        async-db)
            args=("http://localhost:$PORT"
                  --raw "$REQUESTS_DIR/async-db-5.raw,$REQUESTS_DIR/async-db-10.raw,$REQUESTS_DIR/async-db-20.raw,$REQUESTS_DIR/async-db-35.raw,$REQUESTS_DIR/async-db-50.raw"
                  -c "$conns" -t "$THREADS" -d 10s -p "$pipeline" -r 25)
            ;;
        async)
            # One template, a flat wait. The value still travels in the path, so
            # the handler has to parse it out of the route -- what a constant
            # delay gives up is the on-the-wire variation, which is why
            # validate.sh draws its own values and asserts the differential.
            #
            # No -r: connections are held for the whole run. That is the point.
            # Every held connection is one request the server is currently
            # sleeping on, so 32K connections means 32K live timers.
            #
            # 10s rather than the 5s default: long enough that establishing the
            # connections is a small share of the window, short enough to keep
            # three runs plus their cool-downs reasonable.
            #
            # ASYNC_THREADS overrides the generator's thread count for this
            # profile alone. It exists because the result moves with it: on a
            # 32-core box, holding the server fixed and changing only this took
            # throughput from 1.42M at 8 threads to 2.16M at 16, so some of what
            # the profile reports is the generator rather than the server. The
            # default stays at THREADS so nothing changes unless it is set.
            args=("http://localhost:$PORT"
                  --raw "$REQUESTS_DIR/async-delay.raw"
                  -c "$conns" -t "${ASYNC_THREADS:-$THREADS}" -d 10s -p "$pipeline")
            ;;
        fortunes)
            # Single endpoint, fixed 12-row seed + 1 runtime-injected row.
            # No --raw rotation: every request is the same GET; the per-request
            # variance lives inside the handler (sort + render).
            args=("http://localhost:$PORT/fortunes"
                  -c "$conns" -t "$THREADS" -d "$duration" -p "$pipeline")
            ;;
        json-compressed)
            args=("http://localhost:$PORT"
                  --raw "$REQUESTS_DIR/json-gzip-25.raw,$REQUESTS_DIR/json-gzip-40.raw,$REQUESTS_DIR/json-gzip-50.raw"
                  -c "$conns" -t "$THREADS" -d "$duration" -p "$pipeline" -r 25)
            ;;
        ws-echo)
            args=("http://localhost:$PORT/ws" --ws
                  -c "$conns" -t "$THREADS" -d "$duration" -p "$pipeline")
            # echo-ws-limited passes req_per_conn: gcannon's quota check sits
            # above its ws/http branch, so -r caps frames per connection and
            # retires the socket once drained. Each replacement connection
            # redoes the HTTP/1.1 upgrade, which is what that profile measures.
            [ "$req_per_conn" -gt 0 ] 2>/dev/null && args+=(-r "$req_per_conn")
            ;;
        connections-5m|connections-1m-tls)
            # The baseline GET: what varies here is how many connections are
            # held, so the request stays the one subscribers are already
            # validated on - plaintext on PORT, or TLS 1.3 on H1TLS_PORT
            # (https:// makes gcannon handshake, then hand the session to
            # kernel TLS). gcannon_run hands the --args-- part to
            # scripts/conn_hold.py, which owns everything around the load.
            local url="http://127.0.0.1:$PORT/baseline11?a=1&b=2"
            local hport="$PORT" warm="$CONN5M_WARMUP_MAX"
            local rate="$GCANNON_RATE_CONNECTIONS_5M" addrs="$CONN5M_ADDRS"
            if [ "$endpoint" = "connections-1m-tls" ]; then
                url="https://127.0.0.1:$H1TLS_PORT/baseline11?a=1&b=2"
                hport="$H1TLS_PORT" warm="$CONN1M_TLS_WARMUP_MAX"
                rate="$GCANNON_RATE_CONNECTIONS_1M_TLS" addrs="$CONN1M_TLS_ADDRS"
            fi
            args=(--hold-- "$endpoint" "$conns" "$rate" "$hport" "$warm" "$addrs"
                  --args-- "$url"
                  -c "$conns" -t "$THREADS" -d 20s
                  --rate "$rate" --addr-span "$addrs"
                  --connect-limit "$CONN5M_CONNECT_LIMIT"
                  --warmup-max "${warm}s" --settle "${CONN5M_SETTLE}s" --json)
            ;;
        connections-ramp-h1)
            # The same request as the other held profiles, and the same wrapper;
            # what differs is how the fleet comes up and what is read from the
            # result.
            args=(--hold-- "$endpoint" "$conns" "$GCANNON_RATE_CONNECTIONS_RAMP" "$PORT"
                  "$CONNRAMP_WARMUP_MAX" "$CONNRAMP_ADDRS"
                  --args-- "http://127.0.0.1:$PORT/baseline11?a=1&b=2"
                  -c "$conns" -t "$THREADS" -d "${CONNRAMP_WINDOW}s"
                  --rate "$GCANNON_RATE_CONNECTIONS_RAMP" --idle "$CONNRAMP_IDLE"
                  --ramp "$CONNRAMP_FLOOR" --ramp-up "${CONNRAMP_UP}s"
                  --addr-span "$CONNRAMP_ADDRS"
                  --connect-limit "$CONNRAMP_CONNECT_LIMIT"
                  --warmup-max "${CONNRAMP_WARMUP_MAX}s" --settle "${CONNRAMP_SETTLE}s" --json)
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
    if [ "${1:-}" = "--hold--" ]; then
        _gcannon_hold_run "${@:2}"
        return 0
    fi
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

# connections-5m / connections-1m-tls / connections-ramp-h1: gcannon under
# scripts/conn_hold.py, which probes the listener, refuses a run the host cannot
# hold, raises the open-file limit for the fleet, and reads the server cgroup's
# CPU at gcannon's window markers. stdout is the wrapper's JSON summary; stderr
# (gcannon's own lines, the interval lines of a ramp included) goes straight to
# the log.
_gcannon_hold_run() {
    local profile="$1" conns="$2" rate="$3" hport="$4" warm="$5" addrs="$6"
    shift 6
    [ "${1:-}" = "--args--" ] && shift
    local nofile mem
    read -r nofile mem <<< "$(held_conn_limits "$profile")"
    local -a prefix
    if [ "$GCANNON_MODE" = "native" ]; then
        prefix=(taskset -c "$GCANNON_CPUS" env LD_LIBRARY_PATH=/usr/lib "$GCANNON")
    else
        prefix=(docker run --rm --network host --cpuset-cpus="$GCANNON_CPUS"
                --security-opt seccomp=unconfined
                --ulimit memlock=-1:-1 --ulimit nofile="$nofile:$nofile"
                -v "$REQUESTS_DIR:$REQUESTS_DIR:ro" "$GCANNON_IMAGE")
    fi
    local cpu_stat=""
    if [ -n "${CONTAINER_NAME:-}" ]; then
        cpu_stat=$(_cgroup_cpu_path "$CONTAINER_NAME" 2>/dev/null) || cpu_stat=""
    fi
    # Kernel memory per connection: both sockets and a conntrack entry, and
    # over TLS a kernel TLS context on each side that uses one (gcannon's
    # always, the server's when it offloads too).
    local kernel_kib=8 window=20
    local -a extra=()
    [ "$profile" = "connections-1m-tls" ] && kernel_kib=16
    if [ "$profile" = "connections-ramp-h1" ]; then
        window="$CONNRAMP_WINDOW"
        extra=(--ramp-p99-us "$CONNRAMP_P99_US")
    fi
    timeout $(( warm + CONN5M_SETTLE + window + 300 )) python3 "$SCRIPT_DIR/conn_hold.py" \
        --profile "$profile" --conns "$conns" --rate "$rate" --port "$hport" \
        --probe "127.0.0.2,127.0.0.$addrs" --span "127.0.0.1-127.0.0.$addrs" \
        ${cpu_stat:+--cpu-stat "$cpu_stat"} --server-mem "${FRAMEWORK_MEM_LIMIT:-$mem}" \
        --kib-per-conn 4 --kernel-kib-per-conn "$kernel_kib" "${extra[@]}" \
        -- "${prefix[@]}" --args-- "$@" || true
}

# ── Parse output ────────────────────────────────────────────────────────────

# connections-5m / connections-1m-tls: the fixed-rate keys benchmark.sh reads (the same ones
# zrk_parse emits for the latency profiles), from conn_hold.py's summary.
_gcannon_hold_parse() {
    python3 - "$1" <<'PY'
import json, sys
raw = sys.argv[1]
s, e = raw.find("{"), raw.rfind("}")
try:
    d = json.loads(raw[s:e + 1]) if s >= 0 and e > s else {}
except ValueError:
    d = {}
if not d:
    sys.stderr.write("[gcannon] no held-connection summary in the output:\n%s\n" % (raw[:2000] or "<empty>"))
lat = d.get("latency_us") or {}
codes = d.get("status_codes") or {}
print("rps=%d" % round(d.get("rps") or 0))
print("avg_lat=%.1fus" % (lat.get("mean") or 0))
# The median, which the held-connection score weighs (latency_score.HELD).
print("p50_lat=%.1fus" % (lat.get("p50") or 0))
print("p99_lat=%.1fus" % (lat.get("p99") or 0))
print("p999_lat=%.1fus" % (lat.get("p99_9") or 0))
print("reconnects=%d" % (d.get("reconnects") or 0))
print("bandwidth=%.2fMB/s" % ((d.get("bytes_per_sec") or 0) / 1e6))
for k in ("2xx", "3xx", "4xx", "5xx"):
    print("status_%s=%d" % (k, codes.get(k) or 0))
print("rate_ratio=%.4f" % (d.get("rate_ratio") or 0))
print("duration=%.0fs" % (d.get("duration_s") or 0))
print("target_rate=%d" % (d.get("target_rate") or 0))
print("max_schedule_lag_us=%d" % (d.get("max_schedule_lag_us") or 0))
if d.get("connections_open") is not None:
    print("connections_open=%d" % d["connections_open"])
# connections-ramp-h1: how far the ramp got before the active connections' p99
# went over the limit, and why it ended there (conn_hold.py ramp_summary).
ramp = d.get("ramp")
if ramp:
    print("ramp_reached=%d" % (ramp.get("reached") or 0))
    print("ramp_stop=%s" % (ramp.get("stop") or ""))
    print("idle_closed=%d" % (ramp.get("idle_closed") or 0))
print("connect_errors=%d" % ((d.get("errors") or {}).get("connect") or 0))
if d.get("server_cpu_usec") is not None:
    print("cpu_usec_window=%d" % d["server_cpu_usec"])
if d.get("hold_error"):
    print("hold_error=%s" % " ".join(str(d["hold_error"]).split()))
PY
}

# Usage: gcannon_parse <endpoint> <output>
# Echoes KEY=VALUE lines. Caller reads into an assoc array.
gcannon_parse() {
    local endpoint="$1" output="$2"

    case "$endpoint" in
        connections-5m|connections-1m-tls|connections-ramp-h1)
            _gcannon_hold_parse "$output"
            return 0
            ;;
    esac

    # rps — compute from 2xx (or 3xx for caching, or WS frames for ws-echo)
    # divided by the actual measured duration.
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
}
