#!/usr/bin/env bash
# benchmark-lite.sh — "lite" benchmark driver aimed at local development.
#
# Same module structure as benchmark.sh (sources lib/*.sh) but with
# different defaults:
#
#   • All load generators run in Docker (LOADGEN_DOCKER=true forced).
#     First run auto-builds every image from docker/*.Dockerfile.
#   • No CPU pinning — the framework container and load gens both use
#     whatever cores are available. Suits laptops / random CI runners.
#   • Threads default to nproc/2 (not 64), so a 4-core laptop gets 2
#     threads instead of 64.
#   • Fixed, reasonable connection counts per profile (mostly 512).
#   • Smaller profile subset — skips api-4/16, json-tls, gateway-64,
#     stream-grpc/stream-grpc-tls (they need either specific hardware
#     topology or extra setup).
#   • --load-threads <N>  override THREADS/H2THREADS/H3THREADS in one shot.
#
# The pre-refactor version lives at scripts/old/benchmark-lite-old.sh.
#
# Usage:
#   ./scripts/benchmark-lite.sh                     # every enabled framework
#   ./scripts/benchmark-lite.sh <framework>         # one framework, all profiles
#   ./scripts/benchmark-lite.sh <framework> <profile>
#   ./scripts/benchmark-lite.sh <framework> --save  # persist results
#   ./scripts/benchmark-lite.sh --load-threads 4 <framework>

set -euo pipefail

# ── Lite-mode docker switch — FORCED (no env override) ────────────────────
#
# Unlike benchmark.sh which respects LOADGEN_DOCKER / GCANNON_MODE from the
# environment, the lite variant always runs every load generator in Docker.
# That's the whole point of "lite": one command, no native tool install,
# reproducible across machines.
export LOADGEN_DOCKER=true
export GCANNON_MODE=docker

# All cores, no real pinning. tools/*.sh still wrap calls in taskset -c,
# but a cpuset covering every online CPU is effectively a no-op.
_AVAILABLE_CORES=$(nproc 2>/dev/null || echo 4)
export GCANNON_CPUS="${GCANNON_CPUS:-0-$((_AVAILABLE_CORES - 1))}"

# Modest thread counts — nproc/2 clamped to ≥1. User-overridable via env
# or --load-threads flag.
export THREADS="${THREADS:-$(( _AVAILABLE_CORES / 2 > 0 ? _AVAILABLE_CORES / 2 : 1 ))}"
export H2THREADS="${H2THREADS:-$THREADS}"
export H3THREADS="${H3THREADS:-$THREADS}"

# Source lib modules.
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
source "$SOURCE_DIR/common.sh"
source "$SOURCE_DIR/system.sh"
source "$SOURCE_DIR/stats.sh"
source "$SOURCE_DIR/postgres.sh"
source "$SOURCE_DIR/framework.sh"
source "$SOURCE_DIR/profiles.sh"
source "$SOURCE_DIR/tools/gcannon.sh"
source "$SOURCE_DIR/tools/h2load.sh"
source "$SOURCE_DIR/tools/h2load-h3.sh"
source "$SOURCE_DIR/tools/wrk.sh"
source "$SOURCE_DIR/tools/ghz.sh"

# ── Override PROFILES + PROFILE_ORDER with the lite subset ─────────────────
#
# Lite profile format is the same as the full one:
#   pipeline | req_per_conn | cpu_limit | connections | endpoint
#
# Differences vs the full set:
#   • cpu_limit is always empty (no pinning, container gets all cores)
#   • conn_list is one fixed value per profile (no 256,1024 sweeps)
#   • skipped profiles: api-4, api-16, json-tls, gateway-64, stream-grpc*

unset PROFILES PROFILE_ORDER
declare -A PROFILES=(
    [baseline]="1|0||512|"
    [pipelined]="16|0||512|pipeline"
    [limited-conn]="1|10||512|"
    [json]="1|0||512|json"
    [json-comp]="1|0||512|json-compressed"
    [upload]="1|0||128|upload"
    [static]="1|10||512|static"
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
    json json-comp
    upload static async-db
    baseline-h2 static-h2
    baseline-h3 static-h3
    unary-grpc unary-grpc-tls
    echo-ws
)

cd "$ROOT_DIR"
validate_profiles

# ── Argument parsing (--save + --load-threads + positional) ────────────────

SAVE_RESULTS=false
LOAD_THREADS=""
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --save)              SAVE_RESULTS=true ;;
        --load-threads)      LOAD_THREADS="$2"; shift ;;
        --load-threads=*)    LOAD_THREADS="${1#*=}" ;;
        *)                   POSITIONAL+=("$1") ;;
    esac
    shift
done

if [ -n "$LOAD_THREADS" ]; then
    THREADS="$LOAD_THREADS"
    H2THREADS="$LOAD_THREADS"
    H3THREADS="$LOAD_THREADS"
    info "load-threads override: THREADS=$THREADS"
fi

FRAMEWORK_ARG="${POSITIONAL[0]:-}"
PROFILE_FILTER="${POSITIONAL[1]:-}"

# ── Cleanup + tuning ────────────────────────────────────────────────────────

cleanup_all() {
    [ -n "${FRAMEWORK:-}" ] && framework_stop 2>/dev/null || true
    postgres_stop
    # Reclaim anonymous volumes + dangling images from this run. Idempotent
    # and fast when there's nothing to clean. See scripts/benchmark.sh for
    # the reasoning — without this, every lite run leaks ~70MB+ per iteration.
    docker volume prune -f >/dev/null 2>&1 || true
    docker image prune  -f >/dev/null 2>&1 || true
}
trap 'cleanup_all; system_restore' EXIT

docker ps -q  --filter "name=httparena-" | xargs -r docker stop -t 5 2>/dev/null || true
docker ps -aq --filter "name=httparena-" | xargs -r docker rm -f -v 2>/dev/null || true
docker volume prune -f >/dev/null 2>&1 || true
docker image prune  -f >/dev/null 2>&1 || true

info "available cores: $_AVAILABLE_CORES | threads: $THREADS"

# ── Docker load generator mode: build images BEFORE system_tune() ──────────
#
# system_tune() restarts the Docker daemon, which briefly breaks DNS inside
# buildkit worker containers. Any `git clone` or package fetch during a
# build run in that window fails with "Could not resolve host". We build
# all load-gen images first, while the daemon is still in its original
# known-good state. The restart later doesn't affect already-built images.

DOCKER_FLAGS=(
    --rm --network host
    --cpuset-cpus="$GCANNON_CPUS"
    --security-opt seccomp=unconfined
    --ulimit memlock=-1:-1 --ulimit nofile=1048576:1048576
    -v "$REQUESTS_DIR:$REQUESTS_DIR:ro"
)
H2LOAD_CMD="docker run ${DOCKER_FLAGS[*]} $H2LOAD_IMAGE"
H2LOAD_H3_CMD="docker run ${DOCKER_FLAGS[*]} $H2LOAD_H3_IMAGE"
WRK_CMD="docker run ${DOCKER_FLAGS[*]} $WRK_IMAGE"
GHZ_CMD="docker run ${DOCKER_FLAGS[*]} $GHZ_IMAGE"

# Parallel arrays — image names contain ':' (e.g. ghz:local), so packing
# them into "img:dockerfile" strings breaks `${pair%%:*}` parsing.
_loadgen_images=("$GCANNON_IMAGE" "$H2LOAD_IMAGE" "$H2LOAD_H3_IMAGE" "$WRK_IMAGE" "$GHZ_IMAGE")
_loadgen_files=("gcannon.Dockerfile" "h2load.Dockerfile" "h2load-h3.Dockerfile" "wrk.Dockerfile" "ghz.Dockerfile")
for i in "${!_loadgen_images[@]}"; do
    img="${_loadgen_images[$i]}"
    df="${_loadgen_files[$i]}"
    if ! docker image inspect "$img" >/dev/null 2>&1; then
        info "building $img from docker/$df"
        docker build -t "$img" -f "$ROOT_DIR/docker/$df" "$ROOT_DIR/docker" \
            || fail "$img build failed"
    fi
done

# ── System tuning — after image builds ────────────────────────────────────

system_tune

# ── Single-framework runner (called once per framework) ────────────────────

run_framework() {
    local fw="$1"
    framework_load_meta "$fw"
    FRAMEWORK="$fw"

    # Honor the `enabled` flag in meta.json (silently skip if false).
    local meta="$ROOT_DIR/frameworks/$fw/meta.json"
    local enabled
    enabled=$(python3 -c "
import json; print(str(json.load(open('$meta')).get('enabled', True)).lower())" 2>/dev/null || echo "true")
    if [ "$enabled" = "false" ]; then
        info "skip: $fw (disabled)"
        return 0
    fi

    framework_build

    local need_pg=false
    if framework_subscribes_to async-db; then need_pg=true; fi
    $need_pg && postgres_start

    local profiles_to_run
    if [ -n "$PROFILE_FILTER" ]; then
        profiles_to_run=("$PROFILE_FILTER")
    else
        profiles_to_run=("${PROFILE_ORDER[@]}")
    fi

    local profile
    for profile in "${profiles_to_run[@]}"; do
        [ -n "${PROFILES[$profile]+x}" ] || { warn "unknown profile: $profile"; continue; }
        framework_subscribes_to "$profile" || { info "skip: $fw does not subscribe to $profile"; continue; }

        parse_profile "${PROFILES[$profile]}"
        IFS=',' read -ra CONN_COUNTS <<< "$PROF_CONNS"
        local CONNS
        for CONNS in "${CONN_COUNTS[@]}"; do
            run_one "$profile" "$CONNS" || continue
        done
    done

    $need_pg && postgres_stop
}

# ── Single (profile, conns) iteration ──────────────────────────────────────

declare -A BEST_M

run_one() {
    local profile="$1" CONNS="$2"
    parse_profile "${PROFILES[$profile]}"
    local endpoint="$PROF_ENDPOINT"
    local tool
    tool=$(endpoint_tool "$endpoint")

    banner "$FRAMEWORK / $profile / ${CONNS}c (tool=$tool)"

    framework_start "$endpoint" "$PROF_CPU"
    if ! framework_wait_ready "$endpoint"; then
        warn "$FRAMEWORK did not come up for $profile; skipping"
        framework_stop
        return 1
    fi

    local -a gc_args
    mapfile -t gc_args < <("${tool//-/_}_build_args" "$endpoint" "$CONNS" "$PROF_PIPELINE" "$DURATION" "$PROF_REQ")

    [ "$tool" = "ghz" ] && ghz_warmup "$CONNS"

    # Start at -1 so the first measurement always seeds BEST_M, even for
    # endpoints that legitimately report 0 in rps-like counters.
    local best_rps=-1 best_output="" best_cpu="0%" best_mem="0MiB"
    BEST_M=()
    local run

    for run in $(seq 1 "$RUNS"); do
        echo ""; echo "[run $run/$RUNS]"
        stats_start "$CONTAINER_NAME"

        local output
        output=$("${tool//-/_}_run" "${gc_args[@]}")
        stats_stop

        echo "$output" | grep -Ev '^(Warm-up|Main benchmark duration|Stopped all clients|progress: [0-9]+% of clients started|spawning thread #[0-9]+|[0-9]*Warm-up phase is over for thread #[0-9]+)' || true
        info "CPU $STATS_AVG_CPU | Mem $STATS_PEAK_MEM"
        [ -n "$STATS_BREAKDOWN" ] && info "  $STATS_BREAKDOWN"

        declare -A m=()
        local line
        while IFS= read -r line; do
            [[ "$line" == *=* ]] && m["${line%%=*}"]="${line#*=}"
        done < <("${tool//-/_}_parse" "$endpoint" "$output")

        local rps_int=${m[rps]:-0}
        if [ "$rps_int" -gt "$best_rps" ] 2>/dev/null; then
            best_rps=$rps_int
            best_output="$output"
            best_cpu="$STATS_AVG_CPU"
            best_mem="$STATS_PEAK_MEM"
            BEST_M=()
            for k in "${!m[@]}"; do BEST_M[$k]="${m[$k]}"; done
        fi
        sleep 2
    done

    echo ""; echo "=== Best: ${best_rps} req/s (CPU: $best_cpu, Mem: $best_mem) ==="

    if [ "$SAVE_RESULTS" = "true" ]; then
        save_result "$profile" "$CONNS" "$best_rps" "$best_cpu" "$best_mem"
    else
        info "dry-run — not saving (use --save to persist)"
    fi

    framework_stop
    return 0
}

# ── Save result JSON + docker logs ─────────────────────────────────────────

save_result() {
    local profile="$1" CONNS="$2" best_rps="$3" best_cpu="$4" best_mem="$5"
    local dir="$RESULTS_DIR/$profile/$CONNS"
    mkdir -p "$dir"

    # Composite-score support — api-4/16 + gateway-64 need per-template splits
    # or the website scores them as 0. See save_result in benchmark.sh.
    local tpl_extra=""
    if [ "$profile" = "api-4" ] || [ "$profile" = "api-16" ]; then
        tpl_extra=",
  \"tpl_baseline\": ${BEST_M[tpl_baseline]:-0},
  \"tpl_json\": ${BEST_M[tpl_json]:-0},
  \"tpl_db\": 0,
  \"tpl_upload\": 0,
  \"tpl_static\": 0,
  \"tpl_async_db\": ${BEST_M[tpl_async_db]:-0}"
    elif [ "$profile" = "gateway-64" ] && [ "${BEST_M[status_2xx]:-0}" -gt 0 ] 2>/dev/null; then
        # Gateway mix: 6 static / 4 baseline / 7 json / 3 async-db = 30 / 20 / 35 / 15 %.
        # Must stay in sync with requests/gateway-64-uris.txt.
        local total=${BEST_M[status_2xx]}
        tpl_extra=",
  \"tpl_static\": $(( total * 6 / 20 )),
  \"tpl_baseline\": $(( total * 4 / 20 )),
  \"tpl_json\": $(( total * 7 / 20 )),
  \"tpl_async_db\": $(( total * 3 / 20 ))"
    fi

    cat > "$dir/${FRAMEWORK}.json" <<EOF
{
  "framework": "$DISPLAY_NAME",
  "language": "$LANGUAGE",
  "rps": $best_rps,
  "avg_latency": "${BEST_M[avg_lat]:-}",
  "p99_latency": "${BEST_M[p99_lat]:-}",
  "cpu": "$best_cpu",
  "memory": "$best_mem",
  "connections": $CONNS,
  "threads": $THREADS,
  "duration": "$DURATION",
  "pipeline": $PROF_PIPELINE,
  "bandwidth": "${BEST_M[bandwidth]:-0}",
  "reconnects": ${BEST_M[reconnects]:-0},
  "status_2xx": ${BEST_M[status_2xx]:-0},
  "status_3xx": ${BEST_M[status_3xx]:-0},
  "status_4xx": ${BEST_M[status_4xx]:-0},
  "status_5xx": ${BEST_M[status_5xx]:-0}${tpl_extra}
}
EOF
    info "saved results/$profile/$CONNS/${FRAMEWORK}.json"

    local log_dir="$ROOT_DIR/site/static/logs/$profile/$CONNS"
    mkdir -p "$log_dir"
    docker logs "$CONTAINER_NAME" >"$log_dir/${FRAMEWORK}.log" 2>&1 || true
}

# ── Driver: either one framework, or loop through every enabled one ────────

FRAMEWORK=""
if [ -z "$FRAMEWORK_ARG" ]; then
    info "no framework argument — running every enabled framework"
    for fw_dir in "$ROOT_DIR"/frameworks/*/; do
        [ -d "$fw_dir" ] || continue
        fw=$(basename "$fw_dir")
        run_framework "$fw" || warn "$fw run failed, continuing"
    done
else
    run_framework "$FRAMEWORK_ARG"
fi

if [ "$SAVE_RESULTS" = "true" ]; then
    info "rebuilding site/data/*.json"
    python3 "$SCRIPT_DIR/rebuild_site_data.py" --root "$ROOT_DIR"
fi

info "done"
