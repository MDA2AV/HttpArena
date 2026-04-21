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
GCANNON_CPUS="${GCANNON_CPUS:-32-63,96-127}"

H2LOAD="${H2LOAD:-h2load}"
H2LOAD_IMAGE="${H2LOAD_IMAGE:-h2load:latest}"

H2LOAD_H3="${H2LOAD_H3:-h2load-h3}"
H2LOAD_H3_IMAGE="${H2LOAD_H3_IMAGE:-h2load-h3:local}"

WRK="${WRK:-wrk}"
WRK_IMAGE="${WRK_IMAGE:-wrk:local}"

GHZ="${GHZ:-ghz}"
GHZ_IMAGE="${GHZ_IMAGE:-ghz:local}"

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
