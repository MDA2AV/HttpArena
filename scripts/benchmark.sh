#!/usr/bin/env bash
# benchmark.sh — HttpArena benchmark driver.
#
# Split into composable library modules under scripts/lib/; the driver
# itself is short and reads top-to-bottom as orchestration rather than
# implementation. The pre-refactor monolithic version lives at
# scripts/old/benchmark-old.sh for reference.
#
# Usage:
#   ./scripts/benchmark.sh <framework> [profile]
#   ./scripts/benchmark.sh <framework> --save
#
# Environment overrides — see scripts/lib/common.sh for the full list.

set -euo pipefail

# Source every library module in dependency order.
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
source "$SOURCE_DIR/common.sh"
source "$SOURCE_DIR/system.sh"
source "$SOURCE_DIR/stats.sh"
source "$SOURCE_DIR/postgres.sh"
source "$SOURCE_DIR/gateway.sh"
source "$SOURCE_DIR/framework.sh"
source "$SOURCE_DIR/profiles.sh"
source "$SOURCE_DIR/tools/gcannon.sh"
source "$SOURCE_DIR/tools/h2load.sh"
source "$SOURCE_DIR/tools/h2load-h3.sh"
source "$SOURCE_DIR/tools/wrk.sh"
source "$SOURCE_DIR/tools/ghz.sh"

cd "$ROOT_DIR"
validate_profiles

# ── Argument parsing ────────────────────────────────────────────────────────

SAVE_RESULTS=false
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --save) SAVE_RESULTS=true ;;
        *)      POSITIONAL+=("$arg") ;;
    esac
done
FRAMEWORK_ARG="${POSITIONAL[0]:-}"
PROFILE_FILTER="${POSITIONAL[1]:-}"

[ -n "$FRAMEWORK_ARG" ] || fail "usage: benchmark.sh <framework> [profile] [--save]"

# ── Cleanup + tuning ────────────────────────────────────────────────────────

cleanup_all() {
    framework_stop
    # gateway_down reads the active-profile state tracked by gateway_up,
    # so it works correctly regardless of which gateway profile was last.
    gateway_down
    postgres_stop

    # Reclaim anything the compose / framework / postgres stop steps missed.
    # Specifically:
    #   - dangling anonymous volumes (compose creates one per service per
    #     project if the Dockerfile declares VOLUME anywhere; easily 100s
    #     of MB per benchmark iteration)
    #   - dangling images from earlier --build cycles (each iteration of
    #     aspnet-minimal_nginx rebuilds ~300 MB of image layers)
    # Both are idempotent and fast when there's nothing to clean.
    docker volume prune -f >/dev/null 2>&1 || true
    docker image prune  -f >/dev/null 2>&1 || true
}
trap 'cleanup_all; system_restore' EXIT

# Clean slate: stop any leftover benchmark containers from a previous
# crashed run, AND prune any leftover dangling volumes/images from the
# same source. Belt-and-suspenders vs. the cleanup_all at exit.
docker ps -q  --filter "name=httparena-" | xargs -r docker stop -t 5 2>/dev/null || true
docker ps -aq --filter "name=httparena-" | xargs -r docker rm -f -v 2>/dev/null || true
docker volume prune -f >/dev/null 2>&1 || true
docker image prune  -f >/dev/null 2>&1 || true

info "available CPUs: $(nproc 2>/dev/null || echo ?)"

# ── Docker-mode setup — BEFORE system_tune() ────────────────────────────────
#
# When LOADGEN_DOCKER=true we need to build/verify the load-generator images.
# This must happen BEFORE system_tune() because system_tune() restarts the
# Docker daemon, and buildkit's DNS resolution can be briefly broken for
# ~5-10 seconds after a daemon restart — enough to make `git clone` fail
# inside a build container. Running the builds first, while the daemon is
# still in its original known-good state, sidesteps the issue entirely.
if [ "$LOADGEN_DOCKER" = "true" ]; then
    info "load generators: docker mode"
    GCANNON_MODE=docker
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

    # Parallel arrays — images can't be packed into "img:dockerfile" strings
    # because image names already contain ':' (e.g. ghz:local, wrk:local).
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
fi

# ── Framework setup ────────────────────────────────────────────────────────
#
# Framework image build also runs before system_tune() so it isn't caught
# by the post-restart networking blip. meta.json is loaded here too.

framework_load_meta "$FRAMEWORK_ARG"
FRAMEWORK="$FRAMEWORK_ARG"

# Framework-level image build — skipped for compose-only entries because
# their compose files build the server image from the repo root context,
# not from frameworks/<fw>/. Covers gateway-64, gateway-h3, production-stack,
# and any combination thereof.
_has_isolated_test=false
for t in baseline pipelined limited-conn json json-comp json-tls upload \
         api-4 api-16 static async-db \
         baseline-h2 static-h2 baseline-h3 static-h3 \
         unary-grpc unary-grpc-tls stream-grpc stream-grpc-tls echo-ws; do
    if framework_subscribes_to "$t"; then _has_isolated_test=true; break; fi
done
$_has_isolated_test && framework_build

# ── System tuning — NOW, after all image builds are complete ───────────────

system_tune

# Start the postgres sidecar if any subscribed test needs it.
need_pg=false
for t in async-db api-4 api-16 gateway-64 gateway-h3 production-stack; do
    if framework_subscribes_to "$t"; then need_pg=true; break; fi
done
$need_pg && postgres_start

# ── Main benchmark loop ─────────────────────────────────────────────────────

# Pick the profiles to run.
if [ -n "$PROFILE_FILTER" ]; then
    profiles_to_run=("$PROFILE_FILTER")
else
    profiles_to_run=("${PROFILE_ORDER[@]}")
fi

# run_one — single (profile, conns) iteration. Returns non-zero if the
# server failed to start; main loop skips to the next profile in that case.
run_one() {
    local profile="$1" CONNS="$2"
    parse_profile "${PROFILES[$profile]}"
    local endpoint="$PROF_ENDPOINT"
    local tool
    tool=$(endpoint_tool "$endpoint")

    banner "$FRAMEWORK / $profile / ${CONNS}c (tool=$tool)"

    # Compose-orchestrated profiles (gateway-*, production-stack) use
    # a multi-container stack instead of a single framework container.
    local is_gateway=false
    case "$endpoint" in
        gateway-64|gateway-h3|production-stack)
            is_gateway=true
            gateway_up "$FRAMEWORK" "$profile"
            ;;
        *)
            framework_start "$endpoint" "$PROF_CPU"
            ;;
    esac

    if ! framework_wait_ready "$endpoint"; then
        warn "$FRAMEWORK did not come up for $profile; skipping"
        framework_stop
        $is_gateway && gateway_down
        return 1
    fi

    # Build the load-generator argument vector once up front. PROF_REQ is
    # only meaningful for gcannon baseline/limited-conn/api-4/api-16; other
    # tools ignore the extra positional argument.
    local -a gc_args
    mapfile -t gc_args < <("${tool//-/_}_build_args" "$endpoint" "$CONNS" "$PROF_PIPELINE" "$DURATION" "$PROF_REQ")

    # ghz needs a warm-up before the first measurement run.
    if [ "$tool" = "ghz" ]; then
        ghz_warmup "$CONNS"
    fi

    # ── Best-of-N runs ──────────────────────────────────────────────────
    #
    # best_rps starts at -1 so that the *first* measurement always wins,
    # even if its rps is 0 (ws-echo, zero-traffic regressions). Without this,
    # BEST_M would carry stale metrics from a previous profile.
    local best_rps=-1 best_output="" best_cpu="0%" best_mem="0MiB"
    BEST_M=()
    local run

    for run in $(seq 1 "$RUNS"); do
        echo ""; echo "[run $run/$RUNS]"

        if $is_gateway; then
            # shellcheck disable=SC2086
            stats_start $GATEWAY_CONTAINERS
        else
            stats_start "$CONTAINER_NAME"
        fi

        local output
        output=$("${tool//-/_}_run" "${gc_args[@]}")
        stats_stop

        # Print trimmed output (drop ghz/h2load-h3 per-thread spawn chatter).
        echo "$output" | grep -Ev '^(Warm-up|Main benchmark duration|Stopped all clients|progress: [0-9]+% of clients started|spawning thread #[0-9]+|[0-9]*Warm-up phase is over for thread #[0-9]+)' || true
        info "CPU $STATS_AVG_CPU | Mem $STATS_PEAK_MEM"
        [ -n "$STATS_BREAKDOWN" ] && info "  $STATS_BREAKDOWN"

        # Parse into an associative array.
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

    # ── Save results (--save) ───────────────────────────────────────────
    if [ "$SAVE_RESULTS" = "true" ]; then
        save_result "$profile" "$CONNS" "$best_rps" "$best_cpu" "$best_mem"
    else
        info "dry-run — not saving (use --save to persist)"
    fi

    # Tear down between iterations.
    if $is_gateway; then
        gateway_down
    else
        framework_stop
    fi
    return 0
}

# save_result — write results/<profile>/<conns>/<framework>.json + docker logs.
#
# The leaderboard "composite score" for api-4 / api-16 / gateway-* is built
# from per-template response counts (tpl_baseline / tpl_json / tpl_async_db /
# tpl_static). Without these fields the site renders rps correctly but the
# score column collapses to 0. For api-4/16 gcannon_parse already computes
# them; for gateway-64 / gateway-h3 we split the load-generator's total 2xx
# proportionally across the 20-URI mix (6 static, 4 baseline, 7 json, 3 db).
save_result() {
    local profile="$1" CONNS="$2" best_rps="$3" best_cpu="$4" best_mem="$5"
    local dir="$RESULTS_DIR/$profile/$CONNS"
    mkdir -p "$dir"

    local tpl_extra=""
    if [ "$profile" = "api-4" ] || [ "$profile" = "api-16" ]; then
        tpl_extra=",
  \"tpl_baseline\": ${BEST_M[tpl_baseline]:-0},
  \"tpl_json\": ${BEST_M[tpl_json]:-0},
  \"tpl_db\": 0,
  \"tpl_upload\": 0,
  \"tpl_static\": 0,
  \"tpl_async_db\": ${BEST_M[tpl_async_db]:-0}"
    elif { [ "$profile" = "gateway-64" ] || [ "$profile" = "gateway-h3" ]; } \
         && [ "${BEST_M[status_2xx]:-0}" -gt 0 ] 2>/dev/null; then
        # Gateway mix: 6 static / 4 baseline / 7 json / 3 async-db = 30 / 20 / 35 / 15 %.
        # Both gateway profiles share requests/gateway-64-uris.txt, so the
        # split is identical — only the edge protocol (h2 vs h3) differs.
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

    # Persist container logs alongside results for post-mortem.
    local log_dir="$ROOT_DIR/site/static/logs/$profile/$CONNS"
    mkdir -p "$log_dir"
    docker logs "$CONTAINER_NAME" >"$log_dir/${FRAMEWORK}.log" 2>&1 || true
}

# Iterate profiles × conns.
declare -A BEST_M
for profile in "${profiles_to_run[@]}"; do
    if [ -z "${PROFILES[$profile]+x}" ]; then
        warn "unknown profile: $profile"
        continue
    fi
    framework_subscribes_to "$profile" || { info "skip: $FRAMEWORK does not subscribe to $profile"; continue; }

    parse_profile "${PROFILES[$profile]}"
    IFS=',' read -ra CONN_COUNTS <<< "$PROF_CONNS"
    for CONNS in "${CONN_COUNTS[@]}"; do
        run_one "$profile" "$CONNS" || continue
    done
done

# ── Rebuild site data ───────────────────────────────────────────────────────

if [ "$SAVE_RESULTS" = "true" ]; then
    info "rebuilding site/data/*.json"
    python3 "$SCRIPT_DIR/rebuild_site_data.py" --root "$ROOT_DIR"
fi

info "done"
