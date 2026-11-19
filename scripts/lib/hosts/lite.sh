# scripts/lib/hosts/lite.sh — host profile for local development on any machine
# with Docker (HOST_PROFILE=lite; scripts/benchmark-lite.sh sets it).
#
# No CPU pinning: the server and the load generators share every core, so the
# numbers are for comparing frameworks on one machine, not with the leaderboard.
# The profile set skips what needs native tools, sidecars or a large host:
# TLS-over-wrk, fixed-rate latency, gateway / production-stack, fortunes, async,
# h2c and the WebSocket variants.

# ── Load generators ─────────────────────────────────────────────────────────
LOADGEN_DOCKER=true

_LITE_CORES=$(nproc 2>/dev/null || echo 4)
GCANNON_CPUS="0-$((_LITE_CORES - 1))"
export GCANNON_CPUS

# Half the cores; benchmark-lite.sh passes --load-threads (or THREADS) as LITE_THREADS.
THREADS="${LITE_THREADS:-$(( _LITE_CORES / 2 > 0 ? _LITE_CORES / 2 : 1 ))}"
ASYNC_THREADS="$THREADS"
H2THREADS="$THREADS"
H3THREADS="$THREADS"

# ── Profiles ────────────────────────────────────────────────────────────────
# Entries are overridden one by one: profiles this host skips stay defined so
# a meta.json subscribing to them still validates; PROFILE_ORDER decides what runs.
PROFILES[baseline]="1|0||512|"
PROFILES[pipelined]="16|0||512|pipeline"
PROFILES[limited-conn]="1|10||512|"
PROFILES[json-comp]="1|0||512|json-compressed"
PROFILES[8gbit]="1|0||128|8gbit"
PROFILES[async-db]="1|0||512|async-db"
PROFILES[baseline-h2]="1|0||512|h2"
PROFILES[static-h2]="1|0||512|static-h2"
PROFILES[baseline-h3]="1|0||64|h3"
PROFILES[static-h3]="1|0||64|static-h3"
PROFILES[unary-grpc]="1|0||512|grpc"
PROFILES[unary-grpc-tls]="1|0||512|grpc-tls"
PROFILES[echo-ws]="1|0||512|ws-echo"

PROFILE_ORDER=(
    baseline pipelined limited-conn
    json-comp
    8gbit async-db
    baseline-h2 static-h2
    baseline-h3 static-h3
    unary-grpc unary-grpc-tls
    echo-ws
)
