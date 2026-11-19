# scripts/lib/hosts/rpi.sh — host profile for a Raspberry Pi 4 (4x Cortex-A72,
# 4 GB, arm64; HOST_PROFILE=rpi).
#
# The server gets cores 0-1 and the load generators cores 2-3. Connection counts
# are scaled to what two A72 cores and 4 GB can hold, and the profile set is cut
# to the ones that still mean something at this size:
#
#   - latency-1m / latency-500k-8cpu / 8gbit pin a rate far above what the box
#     can offer, so they would measure the generator. latency-10k stays: 10K
#     req/s is a real load here, which is the point of that profile.
#   - h3, gateway and production-stack need images and sidecars that do not fit
#     next to the server on four cores.
#   - async-db and fortunes need Postgres on the same four cores, which would
#     compete with both sides of the measurement.

# ── Load generators ─────────────────────────────────────────────────────────
LOADGEN_DOCKER=true
# No HTTP/3 profile runs here, so the h2load-h3 image need not be built.
SKIP_H3_LOADGEN=true

SERVER_CPUS="0-1"
GCANNON_CPUS="2-3"
export GCANNON_CPUS

THREADS=2
ASYNC_THREADS=2
H2THREADS=2
H3THREADS=2

ZRK_RATE_LATENCY_10K=10000

# ── Profiles ────────────────────────────────────────────────────────────────
# Entries are overridden one by one: profiles this host skips stay defined so
# a meta.json subscribing to them still validates; PROFILE_ORDER decides what runs.
PROFILES[baseline]="1|0|$SERVER_CPUS|256|"
PROFILES[pipelined]="16|0|$SERVER_CPUS|256|pipeline"
PROFILES[limited-conn]="1|10|$SERVER_CPUS|256|"
PROFILES[json-comp]="1|0|$SERVER_CPUS|256|json-compressed"
PROFILES[json-tls]="1|0|$SERVER_CPUS|256|json-tls"
PROFILES[static-tls]="1|200|$SERVER_CPUS|128|static-tls"
PROFILES[baseline-h2]="1|0|$SERVER_CPUS|64|h2"
PROFILES[static-h2]="1|0|$SERVER_CPUS|64|static-h2"
PROFILES[baseline-h2c]="1|0|$SERVER_CPUS|64,256|h2c"
PROFILES[json-h2c]="1|0|$SERVER_CPUS|256|json-h2c"
PROFILES[unary-grpc]="1|0|$SERVER_CPUS|64|grpc"
PROFILES[unary-grpc-tls]="1|0|$SERVER_CPUS|64|grpc-tls"
PROFILES[echo-ws]="1|0|$SERVER_CPUS|256,1024|ws-echo"
PROFILES[echo-ws-pipeline]="16|0|$SERVER_CPUS|256|ws-echo"
PROFILES[echo-ws-limited]="1|10|$SERVER_CPUS|256|ws-echo"
PROFILES[latency-10k]="1|0|$SERVER_CPUS|128|latency-10k"
# 10 ms wait, 4096 held connections: ceiling 409K rps, far above what two
# cores serve, so the ceiling never decides the result.
PROFILES[async]="1|0|$SERVER_CPUS|4096|async"

PROFILE_ORDER=(
    baseline pipelined limited-conn
    json-comp json-tls
    static-tls
    baseline-h2 static-h2
    baseline-h2c json-h2c
    unary-grpc unary-grpc-tls
    echo-ws echo-ws-pipeline echo-ws-limited
    latency-10k
    async
)

# ── Run behaviour ───────────────────────────────────────────────────────────
# JVM and Clojure servers take well over the default 30 s to answer on two
# cores at 1.2 GHz; a server that is merely slow to start is not a failure.
READY_TIMEOUT=120
# Stop a framework at the first profile its server does not come up for.
FAIL_FAST=true
