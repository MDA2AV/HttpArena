# scripts/lib/hosts/lite.sh — host profile for local development (HOST_PROFILE=lite,
# used by scripts/benchmark-lite.sh): load generators in Docker, no CPU pinning,
# half the cores as generator threads and a smaller profile set.

LOADGEN_DOCKER=true

_LITE_CORES=$(nproc 2>/dev/null || echo 4)
GCANNON_CPUS="0-$((_LITE_CORES - 1))"
export GCANNON_CPUS

THREADS="${LITE_THREADS:-$(( _LITE_CORES / 2 > 0 ? _LITE_CORES / 2 : 1 ))}"
H2THREADS="$THREADS"
H3THREADS="$THREADS"

# pipeline | req_per_conn | cpu_limit (empty: no pinning) | connections | endpoint
unset PROFILES PROFILE_ORDER
declare -A PROFILES=(
    [baseline]="1|0||512|"
    [pipelined]="16|0||512|pipeline"
    [limited-conn]="1|10||512|"
    [json-comp]="1|0||512|json-compressed"
    [8gbit]="1|0||128|8gbit"
    [async-db]="1|0||512|async-db"
    [baseline-h2]="1|0||512|h2"
    [static-h2]="1|0||512|static-h2"
    [baseline-h3]="1|0||64|h3"
    [static-h3]="1|0||64|static-h3"
    [unary-grpc]="1|0||512|grpc"
    [unary-grpc-tls]="1|0||512|grpc-tls"
    [echo-ws]="1|0||512|ws-echo"
)
PROFILE_ORDER=(
    baseline pipelined limited-conn
    json-comp
    8gbit async-db
    baseline-h2 static-h2
    baseline-h3 static-h3
    unary-grpc unary-grpc-tls
    echo-ws
)
