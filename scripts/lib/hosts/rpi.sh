# scripts/lib/hosts/rpi.sh — host profile for a Raspberry Pi 4 (4x Cortex-A72,
# 4 GB, arm64). Selected with HOST_PROFILE=rpi; without it nothing here is read
# and the bench-host defaults in common.sh / profiles.sh apply unchanged.
#
# Sourced by benchmark.sh after profiles.sh and before the tool adapters, so it
# can replace profile definitions and generator settings alike.
#
# Layout: the server gets cores 0-1 and the load generator cores 2-3. Connection
# counts are scaled to what two A72 cores and 4 GB can hold, and the profile set
# is cut to the ones that still mean something at this size:
#
#   - latency-1m / latency-500k-8cpu / 8gbit pin a rate far above what the box
#     can offer, so they would measure the generator. latency-10k stays: 10K
#     req/s is a real load here, which is the point of that profile.
#   - h3, gateway and production-stack need images and sidecars that do not fit
#     next to the server on four cores.
#   - async-db and fortunes need Postgres on the same four cores, which would
#     compete with both sides of the measurement.

HOST_LABEL="Raspberry Pi 4 (arm64)"

SERVER_CPUS="0-1"
GCANNON_CPUS="2-3"
export GCANNON_CPUS

THREADS=2
ASYNC_THREADS=2
H2THREADS=2
H3THREADS=2

# Fixed-rate profiles that remain. 8gbit is not run, but keep its rate sane in
# case it is requested explicitly.
ZRK_RATE_LATENCY_10K=10000
ZRK_RATE_8GBIT=2000

# Raw results stay out of /results/ and site/data/ so a Pi run can never leak
# into the main board; scripts/build_host_round.py packages them as a round.
RESULTS_DIR="$ROOT_DIR/results-hosts/rpi"
LOGS_DIR="$RESULTS_DIR/_logs"

# Entries are overridden one by one rather than replacing the array: a
# framework's meta.json may still subscribe to a profile this host skips, and
# that has to stay a known profile (it is simply not in PROFILE_ORDER).
PROFILES[baseline]="1|0|$SERVER_CPUS|256|"
PROFILES[pipelined]="16|0|$SERVER_CPUS|256|pipeline"
PROFILES[limited-conn]="1|10|$SERVER_CPUS|256|"
# 10 ms wait, 4096 held connections: ceiling 409K rps, far above what two
# cores serve, so the ceiling never decides the result.
PROFILES[async]="1|0|$SERVER_CPUS|4096|async"
PROFILES[latency-10k]="1|0|$SERVER_CPUS|128|latency-10k"
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

# No HTTP/3 profile runs here, so the h2load-h3 image need not be built.
SKIP_H3_LOADGEN=true
# The generators run as containers: there are no native builds on the Pi.
LOADGEN_DOCKER=true
