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
    # Async: GET /delay/{ms}, ms drawn per request from {RAND:10:30}. Held
    # connections (req_per_conn=0) so every one of them is a pending timer the
    # server has to carry. Ceiling is arithmetic — conns / mean(delay), i.e.
    # ~1.64M rps at 32768c and ~2.46M at 49152c — so a result above it is proof
    # the delay was skipped, not a fast server.
    #
    # 49152 rather than the 65536 this was scoped at: system_tune() widens
    # ip_local_port_range to 1024-65535, which is 64505 usable ephemeral ports
    # after ip_local_reserved_ports, and gcannon needs one per connection. 64K
    # connections do not fit; 48K leaves headroom for the TIME_WAIT the previous
    # run is still holding.
    [async]="1|0|0-31,64-95|32768,49152|async"
    [json]="1|0|0-31,64-95|4096|json"
    [json-comp]="1|0|0-31,64-95|512,4096,16384|json-compressed"
    [json-tls]="1|0|0-31,64-95|4096|json-tls"
    [upload]="1|0|0-31,64-95|32,256|upload"
    [api-4]="1|5|0-1,64-65|256|api-4"
    [api-16]="1|5|0-7,64-71|1024|api-16"
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
    upload api-4 api-16
    static static-tls async-db crud
    fortunes
    baseline-h2 static-h2
    baseline-h2c json-h2c
    baseline-h3 static-h3
    gateway-64 gateway-h3
    production-stack
    unary-grpc unary-grpc-tls
    echo-ws echo-ws-pipeline echo-ws-limited
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
# Returns one of: gcannon, wrk, h2load, h2load-h3
endpoint_tool() {
    case "$1" in
        # wrk (lua script rotation)
        static|static-tls|json-tls)         echo "wrk" ;;
        # h2load for all HTTP/2 variants (TLS via ALPN + h2c prior-knowledge)
        h2|static-h2|h2c|json-h2c|gateway-64|grpc|grpc-tls|production-stack)  echo "h2load" ;;
        # h2load built with ngtcp2 for HTTP/3
        h3|static-h3|gateway-h3)            echo "h2load-h3" ;;
        # gcannon for everything else (h1, upload, api-4, api-16, async-db,
        # async, ws, ...)
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
