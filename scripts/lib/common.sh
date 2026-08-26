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

H2LOAD="${H2LOAD:-h2load}"
H2LOAD_IMAGE="${H2LOAD_IMAGE:-h2load:latest}"

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
# Container logs are written to site/static/logs/ only by save_result(), which
# a server that never became ready never reaches — and framework_stop() runs
# `docker rm -f` moments later, so the evidence is gone. These print it while
# it still exists. Bounded by FAIL_LOG_TAIL: a crash-looping server can emit
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
