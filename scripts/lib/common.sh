# scripts/lib/common.sh — shared constants, paths, env vars, logging helpers.
# Sourced by benchmark.sh / benchmark-lite.sh and every lib module. No side
# effects beyond variable assignment and function declaration.

# Resolve repository root from the script location once.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Paths — every tool + framework reads from these.
REQUESTS_DIR="$ROOT_DIR/requests"
RESULTS_DIR="$ROOT_DIR/results"
CERTS_DIR="$ROOT_DIR/certs"
DATA_DIR="$ROOT_DIR/data"

# Framework container ports. Used by every framework's Dockerfile too.
PORT=8080         # h1 plaintext, also h2c for gRPC
H2PORT=8443       # h2 TLS, h3 QUIC
H1TLS_PORT=8081   # h1 + TLS (json-tls profile)
H2C_PORT=8082     # h2c prior-knowledge (baseline-h2c, json-h2c profiles)

# Run settings — can be overridden via env vars at invocation time.
DURATION="${DURATION:-5s}"
RUNS="${RUNS:-3}"
THREADS="${THREADS:-64}"
# The async profile's generator thread count, separately settable. It gets its own
# knob because the profile is closed-loop - every connection holds one request for
# the length of its wait - so what it reports is latency divided into connections,
# and the generator contributes to that latency. Holding the server fixed on a
# 32-core box and changing only this moved the result from 1.42M at 8 threads to
# 2.16M at 16, so the number is not the server's alone.
ASYNC_THREADS="${ASYNC_THREADS:-64}"
H2THREADS="${H2THREADS:-64}"
H3THREADS="${H3THREADS:-64}"

# Load generator binaries + docker images.
GCANNON="${GCANNON:-gcannon}"
GCANNON_IMAGE="${GCANNON_IMAGE:-gcannon:latest}"
GCANNON_MODE="${GCANNON_MODE:-native}"

_AVAIL_CORES=$(nproc 2>/dev/null || echo 1)
if [ -z "${GCANNON_CPUS:-}" ]; then
    if [ "$_AVAIL_CORES" -ge 128 ]; then
        GCANNON_CPUS="32-63,96-127"
    else
        # For smaller machines, just use the second half of cores for load gen, 
        # or all cores if we only have 1 or 2.
        if [ "$_AVAIL_CORES" -le 2 ]; then
            GCANNON_CPUS="0-$((_AVAIL_CORES - 1))"
        else
            _HALF=$((_AVAIL_CORES / 2))
            GCANNON_CPUS="$_HALF-$((_AVAIL_CORES - 1))"
        fi
    fi
fi
export GCANNON_CPUS

_H2LOAD_EXPLICIT="${H2LOAD:+true}"
H2LOAD="${H2LOAD:-h2load}"
H2LOAD_IMAGE="${H2LOAD_IMAGE:-h2load:1.69.0}"

H2LOAD_H3="${H2LOAD_H3:-h2load-h3}"
H2LOAD_H3_IMAGE="${H2LOAD_H3_IMAGE:-h2load-h3:local}"

WRK="${WRK:-wrk}"
WRK_IMAGE="${WRK_IMAGE:-wrk:local}"

# zrk — constant-throughput generator for the latency-1m profile.
ZRK="${ZRK:-zrk}"
ZRK_IMAGE="${ZRK_IMAGE:-zrk:local}"


LOADGEN_DOCKER="${LOADGEN_DOCKER:-false}"

# Raise our own fd limit; guard against "unlimited" which Docker rejects.
HARD_NOFILE=$(ulimit -Hn 2>/dev/null || echo 1048576)
[[ "$HARD_NOFILE" =~ ^[0-9]+$ ]] || HARD_NOFILE=1048576
ulimit -n "$HARD_NOFILE" 2>/dev/null || true

# The held-connection profiles' server container. HARD_NOFILE is whatever the
# shell running the harness was given, which can be below the fleet; these
# profiles need a socket per connection plus the server's own, so the container
# gets these instead (capped at fs.nr_open, which system_tune_held_connections
# raises). The memory cap keeps an entry from taking the host down with it: it
# is OOM-killed and the run reports what it held.
#
# The 5M caps are what the 251 GiB bench host has left after the fleet itself:
# ~4 KiB of gcannon and ~8 KiB of kernel (both sockets and a conntrack entry)
# per connection is ~57 GiB at five million; a server spending ~25 KiB per
# connection fits in 128g. The million-connection profiles (connections-1m-tls,
# connections-1m) get the 1M caps. Over TLS the kernel adds ~4 KiB of TLS
# state per socket on each side that uses it, so the fleet costs ~20 KiB a
# connection, ~19 GiB at a million, besides the server.
CONN1M_NOFILE="${CONN1M_NOFILE:-2097152}"
CONN1M_MEM_LIMIT="${CONN1M_MEM_LIMIT:-96g}"
CONN5M_NOFILE="${CONN5M_NOFILE:-8388608}"
CONN5M_MEM_LIMIT="${CONN5M_MEM_LIMIT:-128g}"

# Between held-connection runs the harness waits for the host's TCP socket
# count to come back down (system.sh, held_conn_drain) instead of sleeping: to
# within HELD_CONN_DRAIN_SLACK of what it held before the first profile, giving
# up after HELD_CONN_DRAIN_STALL seconds without progress or
# HELD_CONN_DRAIN_TIMEOUT seconds in all.
HELD_CONN_DRAIN_SLACK="${HELD_CONN_DRAIN_SLACK:-50000}"
HELD_CONN_DRAIN_STALL="${HELD_CONN_DRAIN_STALL:-30}"
HELD_CONN_DRAIN_TIMEOUT="${HELD_CONN_DRAIN_TIMEOUT:-600}"

# "<nofile> <memory cap>" for a held-connection profile's server container.
held_conn_limits() {
    case "$1" in
        connections-5m)     echo "$CONN5M_NOFILE $CONN5M_MEM_LIMIT" ;;
        *)                  echo "$CONN1M_NOFILE $CONN1M_MEM_LIMIT" ;;
    esac
}

# Postgres sidecar.
PG_CONTAINER="httparena-postgres"
DATABASE_URL="postgres://bench:bench@localhost:5432/benchmark"

# ── Logging helpers ─────────────────────────────────────────────────────────

log()   { echo "[$(date +%H:%M:%S)] $*"; }
info()  { echo "[info] $*"; }
warn()  { echo "[warn] $*" >&2; }
fail()  { echo "[FAIL] $*" >&2; exit 1; }
banner() {
    echo ""
    echo "=============================================="
    echo "=== $* ==="
    echo "=============================================="
}

# ── Failure diagnostics ─────────────────────────────────────────────────────
#
# Print diagnostics before teardown removes the containers. Bounded by
# FAIL_LOG_TAIL: a crash-looping server can emit
# megabytes, and this output is also what lands in the PR comment, which
# quotes the last 200 lines of the run.

dump_container_logs() {
    local ref="$1" label="${2:-$1}" n="${FAIL_LOG_TAIL:-120}" state logs
    echo ""
    # No container at all means an earlier step (build, or `docker run` itself)
    # failed; asking for its logs would just echo docker's own error back.
    if ! state=$(docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}}' \
                 "$ref" 2>/dev/null); then
        echo "─── $label — no such container: it was never created, so an earlier build or start step is what failed"
        return 0
    fi
    echo "─── $label — $state"
    if [ "$n" = all ]; then
        docker logs "$ref" 2>&1 || true
        return 0
    fi
    logs=$(docker logs --tail "$n" "$ref" 2>&1) || true
    if [ -n "$logs" ]; then
        echo "─── $label — last $n log lines ───"
        printf '%s\n' "$logs" | sed 's/^/  | /'
        echo "─── $label — end of logs ───"
    else
        echo "─── $label — the container produced no output at all"
    fi
}

# Every container in a compose project. `docker ps -a`, not `docker ps`: the
# service that died is exactly the one missing from the running list.
dump_compose_logs() {
    local project="$1" id name
    [ -n "$project" ] || return 0
    for id in $(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null); do
        name=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')
        dump_container_logs "$id" "${name:-$id}"
    done
}

dump_benchmark_logs() {
    if [ -n "${GATEWAY_PROJECT:-}" ]; then
        dump_compose_logs "$GATEWAY_PROJECT"
    else
        dump_container_logs "$CONTAINER_NAME" "$FRAMEWORK"
    fi
}

save_benchmark_logs() {
    local profile="$1" conns="$2"
    local log_dir="${LOGS_DIR:-$ROOT_DIR/site/static/logs}/$profile/$conns"
    mkdir -p "$log_dir"
    local log_file="$log_dir/${FRAMEWORK}.log"
    if [ -n "${GATEWAY_PROJECT:-}" ]; then
        FAIL_LOG_TAIL=all dump_compose_logs "$GATEWAY_PROJECT" >"$log_file" 2>&1
    else
        docker logs "$CONTAINER_NAME" >"$log_file" 2>&1 || true
    fi

    # Keep noisy containers below GitHub's file-size limit.
    local log_max=${HTTPARENA_MAX_LOG_BYTES:-8000000} log_size
    log_size=$(wc -c < "$log_file")
    if [ "$log_size" -gt "$log_max" ] 2>/dev/null; then
        tail -c "$log_max" "$log_file" >"$log_file.tail"
        {
            echo "[httparena] container log was ${log_size} bytes; keeping the last ${log_max}."
            cat "$log_file.tail"
        } >"$log_file"
        rm -f "$log_file.tail"
        warn "$FRAMEWORK $profile/$conns: container log was ${log_size} bytes, truncated to ${log_max}"
    fi
}
