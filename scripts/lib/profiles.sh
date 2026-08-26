# scripts/lib/profiles.sh — profile definitions and parsing.
#
# Profile format: "pipeline|req_per_conn|cpu_limit|connections|endpoint"
#   pipeline      — gcannon -p value (1 for non-pipelined)
#   req_per_conn  — gcannon -r value (0 = unlimited)
#   cpu_limit     — container cpuset (e.g. "0-31,64-95") or cpu count
#   connections   — comma-separated list; each value is a separate run
#   endpoint      — dispatch key; tells the driver which tool + shape to use
#
# Adding a profile: add a line to PROFILES and append to PROFILE_ORDER.

declare -A PROFILES=(
    [baseline]="1|0|0-31,64-95|512,4096|"
    [pipelined]="16|0|0-31,64-95|512,4096|pipeline"
    [limited-conn]="1|10|0-31,64-95|512,4096|"
    # Async: GET /delay/15, a flat 15ms wait. Held connections (req_per_conn=0)
    # so every one of them is a pending timer the server has to carry.
    #
    # History, since the delay is the knob everything else hangs off:
    #   10-30ms draw, 32768/49152c  ceiling 1.64M/2.46M, tokio at 93%/83%
    #   flat 10ms,    64000c        ceiling 6.4M,        tokio 2240622 (35%)
    #   flat 15ms,    64000c        ceiling 4.27M
    # tokio gained 10% for a ceiling that had more than doubled, which is what
    # capacity-bound looks like — the delay stopped being the limiter at 10ms.
    #
    # Which is why 15 and not 5. The delay cuts both ways: an async server is
    # capped at conns/delay, a blocking one at threads/delay, so shortening it
    # frees a blocked thread sooner and narrows the gap this profile exists to
    # show. At 15ms a 64-thread blocking server tops out at 4267 rps against
    # tokio's measured 2.24M. It also leaves the 3-4ms a sloppy timer costs at
    # about a quarter of the wait rather than most of it.
    #
    # 4.27M sits just under the ~4.4M baseline peak, which puts the ceiling back
    # in play as a correctness check: nothing can beat conns/delay while
    # honouring the delay, so a result above it did not wait.
    #
    # 64000 rather than 65536: system_tune() widens ip_local_port_range to
    # 1024-65535 and gcannon needs one ephemeral port per connection, so 64505
    # are usable after ip_local_reserved_ports. 65536 connections to one
    # localhost:8080 cannot be established at all — the whole 16-bit port space
    # is smaller than that. 64000 fits with ~500 ports to spare; if the ramp
    # ever shows up as connect errors, 61440 is the next stop down.
    [async]="1|0|0-31,64-95|64000|async"
    # Latency-1M: the offered rate is pinned at 1M req/s (see ZRK_FIXED_RATE
    # in tools/zrk.sh) and the measurement is what the server spent to serve
    # it, read exactly out of the container's cgroup rather than sampled.
    #
    # Every other profile here asks how fast a server can go. Real servers
    # spend almost all of their time nowhere near that, so this asks the
    # question from the other end: at a load everybody can carry, who carries
    # it cheaply. 1024 connections because the socket count is part of the
    # workload — 500K req/s needs only ~15 in flight, so the rest of them are
    # there to be polled, which is exactly the cost being compared.
    [latency-1m]="1|0|0-31,64-95|1024|latency-1m"
    [json]="1|0|0-31,64-95|4096|json"
    [json-comp]="1|0|0-31,64-95|512,4096,16384|json-compressed"
    [json-tls]="1|0|0-31,64-95|4096|json-tls"
    [upload]="1|0|0-31,64-95|32,256|upload"
    [static]="1|200|0-31,64-95|1024,4096,6800|static"
    [static-tls]="1|200|0-31,64-95|1024,4096,6800|static-tls"
    [async-db]="1|0|0-31,64-95|1024|async-db"
    [crud]="1|200|1-31,65-95|4096|crud"
    [fortunes]="1|0|0-31,64-95|1024|fortunes"
    [baseline-h2]="1|0|0-31,64-95|256,1024|h2"
    [static-h2]="1|0|0-31,64-95|256,1024|static-h2"
    [baseline-h2c]="1|0|0-31,64-95|256,1024,4096|h2c"
    [json-h2c]="1|0|0-31,64-95|1024,4096|json-h2c"
    [baseline-h3]="1|0|0-31,64-95|64|h3"
    [static-h3]="1|0|0-31,64-95|64|static-h3"
    [unary-grpc]="1|0|0-31,64-95|256,1024|grpc"
    [unary-grpc-tls]="1|0|0-31,64-95|256,1024|grpc-tls"
    [gateway-64]="1|0|0-31,64-95|512,1024|gateway-64"
    [gateway-h3]="1|0|0-31,64-95|64,256|gateway-h3"
    [production-stack]="1|0|0-31,64-95|256,1024|production-stack"
    [echo-ws]="1|0|0-31,64-95|512,4096,16384|ws-echo"
    [echo-ws-pipeline]="16|0|0-31,64-95|512,4096,16384|ws-echo"
    [echo-ws-limited]="1|10|0-31,64-95|512,4096|ws-echo"
)

PROFILE_ORDER=(
    baseline pipelined limited-conn
    json json-comp json-tls
    upload
    static static-tls async-db crud
    fortunes
    baseline-h2 static-h2
    baseline-h2c json-h2c
    baseline-h3 static-h3
    gateway-64 gateway-h3
    production-stack
    unary-grpc unary-grpc-tls
    echo-ws echo-ws-pipeline echo-ws-limited
    latency-1m
    # Last on purpose. It closes ~49K sockets at exit and every one sits in
    # TIME_WAIT for the kernel's fixed ~60s, so anything scheduled after it
    # starts against a nearly full port table.
    async
)

# ── Parsing + validation ────────────────────────────────────────────────────

# Parse a profile spec string into global fields. Exits on malformed input.
# Globals set: PROF_PIPELINE, PROF_REQ, PROF_CPU, PROF_CONNS, PROF_ENDPOINT
parse_profile() {
    local spec="$1"
    local n_pipes
    n_pipes=$(echo "$spec" | tr -cd '|' | wc -c)
    if [ "$n_pipes" -ne 4 ]; then
        fail "profile spec '$spec' must have exactly 4 '|' separators, got $n_pipes"
    fi
    IFS='|' read -r PROF_PIPELINE PROF_REQ PROF_CPU PROF_CONNS PROF_ENDPOINT <<< "$spec"
}

# Map an endpoint to the tool name that handles it.
# Returns one of: gcannon, wrk, zrk, h2load, h2load-h3
endpoint_tool() {
    case "$1" in
        # wrk (lua script rotation)
        static|static-tls|json-tls)         echo "wrk" ;;
        # zrk — the only paced generator; holds a fixed offered rate
        latency-1m)                        echo "zrk" ;;
        # h2load for all HTTP/2 variants (TLS via ALPN + h2c prior-knowledge)
        h2|static-h2|h2c|json-h2c|gateway-64|grpc|grpc-tls|production-stack)  echo "h2load" ;;
        # h2load built with ngtcp2 for HTTP/3
        h3|static-h3|gateway-h3)            echo "h2load-h3" ;;
        # gcannon for everything else (h1, upload, async-db, async, ws, ...)
        *)                                  echo "gcannon" ;;
    esac
}

# Validate at startup that every PROFILE_ORDER entry has a PROFILES definition.
# Call this in benchmark.sh before the main loop.
validate_profiles() {
    local p ok=true
    for p in "${PROFILE_ORDER[@]}"; do
        if [ -z "${PROFILES[$p]+x}" ]; then
            echo "[profiles] MISSING definition: $p" >&2
            ok=false
        fi
    done
    $ok || fail "PROFILE_ORDER references profiles that aren't in PROFILES"
}
