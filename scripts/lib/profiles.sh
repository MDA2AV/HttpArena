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
    [json]="1|0|0-31,64-95|4096|json"
    [json-comp]="1|0|0-31,64-95|512,4096,16384|json-compressed"
    [json-tls]="1|0|0-31,64-95|4096|json-tls"
    [upload]="1|0|0-31,64-95|32,256|upload"
    [api-4]="1|5|0-3|256|api-4"
    [api-16]="1|5|0-7,64-71|1024|api-16"
    [static]="1|200|0-31,64-95|1024,4096,6800|static"
    [async-db]="1|0|0-31,64-95|1024|async-db"
    [crud]="1|200|1-31,65-95|4096|crud"
    [baseline-h2]="1|0|0-31,64-95|256,1024|h2"
    [static-h2]="1|0|0-31,64-95|256,1024|static-h2"
    [baseline-h2c]="1|0|0-31,64-95|256,1024|h2c"
    [json-h2c]="1|0|0-31,64-95|4096|json-h2c"
    [baseline-h3]="1|0|0-31,64-95|64|h3"
    [static-h3]="1|0|0-31,64-95|64|static-h3"
    [unary-grpc]="1|0|0-31,64-95|256,1024|grpc"
    [unary-grpc-tls]="1|0|0-31,64-95|256,1024|grpc-tls"
    [stream-grpc]="1|0|0-31,64-95|64|grpc-stream"
    [stream-grpc-tls]="1|0|0-31,64-95|64|grpc-stream-tls"
    [gateway-64]="1|0|0-31,64-95|512,1024|gateway-64"
    [gateway-h3]="1|0|0-31,64-95|64,256|gateway-h3"
    [production-stack]="1|0|0-31,64-95|256,1024|production-stack"
    [echo-ws]="1|0|0-31,64-95|512,4096,16384|ws-echo"
)

PROFILE_ORDER=(
    baseline pipelined limited-conn
    json json-comp json-tls
    upload api-4 api-16
    static async-db crud
    baseline-h2 static-h2
    baseline-h2c json-h2c
    baseline-h3 static-h3
    gateway-64 gateway-h3
    production-stack
    unary-grpc unary-grpc-tls
    stream-grpc stream-grpc-tls
    echo-ws
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
# Returns one of: gcannon, wrk, h2load, h2load-h3, ghz, oha
endpoint_tool() {
    case "$1" in
        # wrk (lua script rotation)
        static|json-tls)                    echo "wrk" ;;
        # h2load for all HTTP/2 variants (TLS via ALPN + h2c prior-knowledge)
        h2|static-h2|h2c|json-h2c|gateway-64|grpc|grpc-tls|production-stack)  echo "h2load" ;;
        # h2load built with ngtcp2 for HTTP/3
        h3|static-h3|gateway-h3)            echo "h2load-h3" ;;
        # ghz for real gRPC (streaming especially)
        grpc-stream|grpc-stream-tls)        echo "ghz" ;;
        # gcannon for everything else (h1, upload, api-4, api-16, async-db, ws, ...)
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
