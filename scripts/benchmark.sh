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
source "$SOURCE_DIR/redis.sh"
source "$SOURCE_DIR/gateway.sh"
source "$SOURCE_DIR/framework.sh"
source "$SOURCE_DIR/profiles.sh"
source "$SOURCE_DIR/tools/gcannon.sh"
source "$SOURCE_DIR/tools/h2load.sh"
source "$SOURCE_DIR/tools/h2load-h3.sh"
source "$SOURCE_DIR/tools/wrk.sh"
source "$SOURCE_DIR/tools/zrk.sh"

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

# crud-only experiment: carve 16 physical cores out of gcannon's cpuset and
# hand them to postgres. Leaves gcannon with 16 phys (still plenty — gcannon
# was using ~10 cores at 300K+ rps) and bounds PG's CPU so its consumption
# is explicit and attributable. SMT pairs preserved: N and N+64 always go
# to the same consumer. Applied only when the user filtered to crud exactly,
# and BEFORE the LOADGEN_DOCKER block below so docker-mode DOCKER_FLAGS
# captures the narrowed GCANNON_CPUS if it's the active mode.
if [ "$PROFILE_FILTER" = "crud" ]; then
    # Reshape the server's cpuset inside the PROFILES dict so run_one's
    # parse_profile picks up the widened range; pair with the pinned
    # redis/gcannon cpusets below. Postgres left unpinned — the kernel
    # scheduler naturally co-locates PG backends with the server on the
    # same socket's L3, and forcing a cpuset hurt rps in earlier runs.
    # SMT pairs preserved (N, N+64) for all pinned consumers.
    PROFILES[crud]="1|200|1-31,65-95|4096|crud"             # server:  31 phys / 62 threads
    export GCANNON_CPUS="32-63,96-127"                      # gcannon: 32 phys / 64 threads
    export REDIS_CPUSET="0,64"                              # redis:    1 phys /  2 threads
    unset PG_CPUSET                                         # postgres unpinned (kernel-scheduled)
    info "crud experiment CPU layout: redis=$REDIS_CPUSET | server=1-31,65-95 | gcannon=$GCANNON_CPUS | postgres=unpinned"
fi

# ── Cleanup + tuning ────────────────────────────────────────────────────────

cleanup_all() {
    framework_stop
    # gateway_down reads the active-profile state tracked by gateway_up,
    # so it works correctly regardless of which gateway profile was last.
    gateway_down
    postgres_stop
    redis_stop

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
if [ "${SKIP_TUNE:-}" != "true" ]; then
    trap 'cleanup_all; system_restore' EXIT
else
    trap 'cleanup_all' EXIT
fi

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
    ZRK_CMD="docker run ${DOCKER_FLAGS[*]} $ZRK_IMAGE"

    # Parallel arrays — images can't be packed into "img:dockerfile" strings
    # because image names already contain ':' (e.g. wrk:local, h2load:local).
    _loadgen_images=("$GCANNON_IMAGE" "$H2LOAD_IMAGE" "$H2LOAD_H3_IMAGE" "$WRK_IMAGE" "$ZRK_IMAGE")
    _loadgen_files=("gcannon.Dockerfile" "h2load.Dockerfile" "h2load-h3.Dockerfile" "wrk.Dockerfile" "zrk.Dockerfile")
    for i in "${!_loadgen_images[@]}"; do
        img="${_loadgen_images[$i]}"
        df="${_loadgen_files[$i]}"
        if ! docker image inspect "$img" >/dev/null 2>&1; then
            info "building $img from docker/$df"
            _build_args=""
            # gcannon: bust the git-clone cache so we always get the
            # latest source from the repo. Other images are version-
            # pinned and don't need this.
            if [ "$df" = "gcannon.Dockerfile" ]; then
                _build_args="--build-arg CACHE_BUST=$(date +%s)"
            fi
            docker build $_build_args -t "$img" -f "$ROOT_DIR/docker/$df" "$ROOT_DIR/docker" \
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
         static static-tls async-db async latency-1m \
         baseline-h2 static-h2 baseline-h2c json-h2c \
         baseline-h3 static-h3 \
         unary-grpc unary-grpc-tls \
         echo-ws echo-ws-pipeline echo-ws-limited; do
    if framework_subscribes_to "$t"; then _has_isolated_test=true; break; fi
done
$_has_isolated_test && framework_build

# zrk is the one load generator with no native install on the bench host.
# gcannon, wrk and h2load are all on PATH there, so the adapters can call them
# bare when LOADGEN_DOCKER is false -- zrk cannot, and a `command not found`
# inside a tool adapter reads downstream as a server that answered nothing.
# That is exactly how the first board-wide latency-1m run failed: every entry
# reported 0 req/s and a rate_ratio of 0, and the run looked like 103 broken
# frameworks instead of one missing binary.
#
# Built here rather than in the LOADGEN_DOCKER block because that block is
# gated on a mode the bench host does not use, and built *before* system_tune()
# for the reason the framework build above is: this Dockerfile needs DNS to
# reach github.com, and the daemon restart in system_tune() breaks resolution
# inside build containers for several seconds afterwards.
if framework_subscribes_to "latency-1m" && [ -z "${ZRK_CMD:-}" ]    && ! command -v "$ZRK" >/dev/null 2>&1; then
    if ! docker image inspect "$ZRK_IMAGE" >/dev/null 2>&1; then
        info "building $ZRK_IMAGE from docker/zrk.Dockerfile (no native zrk on PATH)"
        docker build -t "$ZRK_IMAGE" -f "$ROOT_DIR/docker/zrk.Dockerfile" "$ROOT_DIR/docker"             || fail "$ZRK_IMAGE build failed — latency-1m cannot run without it"
    fi
    ZRK_CMD="docker run --rm --network host --cpuset-cpus=$GCANNON_CPUS --security-opt seccomp=unconfined --ulimit memlock=-1:-1 --ulimit nofile=1048576:1048576 $ZRK_IMAGE"
    info "zrk: docker mode ($ZRK_IMAGE)"
fi

# ── System tuning — NOW, after all image builds are complete ───────────────

if [ "${SKIP_TUNE:-}" != "true" ]; then
    system_tune
else
    info "skipping system tuning as requested (SKIP_TUNE=true)"
fi

# Start the postgres sidecar if any subscribed test needs it.
need_pg=false
for t in async-db crud gateway-64 gateway-h3 production-stack fortunes; do
    if framework_subscribes_to "$t"; then need_pg=true; break; fi
done
if $need_pg; then postgres_start; fi

# Redis sidecar — started whenever crud is in play so multi-process
# frameworks can use it as a shared cache. Single-heap frameworks
# (aspnet-minimal, Go, etc.) just ignore REDIS_URL and keep using their
# in-process IMemoryCache/sync.Map equivalents. The sidecar is cheap to
# leave running if unused.
need_redis=false
for t in crud; do
    if framework_subscribes_to "$t"; then need_redis=true; break; fi
done
if $need_redis; then redis_start; fi

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

    # Reset Postgres before each DB profile so it sees the same clean,
    # freshly-seeded server a standalone `benchmark.sh <fw> <profile>` run gets.
    # Postgres is started once and shared across the whole run, so otherwise the
    # previous profile's warm buffers / planner stats / table bloat bleed into
    # this one. That contamination is severe: after async-db's seq-scan load
    # leaves every page resident, crud's cached-read backends all become
    # runnable at once and Postgres spins ~120 cores on snapshot/buffer
    # contention, collapsing crud from ~680k to ~210k rps. The first DB profile
    # already has a fresh server from the upfront postgres_start, so skip it.
    case "$endpoint" in
        async-db|crud|fortunes)
            if [ "${PG_DIRTY:-false}" = true ]; then
                info "resetting postgres for a clean per-profile baseline"
                postgres_start
            fi
            PG_DIRTY=true
            ;;
    esac

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
        if $is_gateway; then
            dump_compose_logs "$GATEWAY_PROJECT"
        else
            dump_container_logs "$CONTAINER_NAME" "$FRAMEWORK"
        fi
        framework_stop
        $is_gateway && gateway_down
        return 1
    fi

    # Build the load-generator argument vector once up front. PROF_REQ is
    # only meaningful for gcannon baseline/limited-conn and ws-echo; other
    # tools ignore the extra positional argument.
    local -a gc_args
    mapfile -t gc_args < <("${tool//-/_}_build_args" "$endpoint" "$CONNS" "$PROF_PIPELINE" "$DURATION" "$PROF_REQ")

    # ── Best-of-N runs ──────────────────────────────────────────────────
    #
    # best_rps starts at -1 so that the *first* measurement always wins,
    # even if its rps is 0 (ws-echo, zero-traffic regressions). Without this,
    # BEST_M would carry stale metrics from a previous profile.
    local best_rps=-1 best_output="" best_cpu="0%" best_mem="0MiB" best_breakdown=""
    local best_cpu_usec="" best_rate_ratio=""

    # Latency-1M picks its winner after the loop instead of during it: the run
    # score normalises each metric against the best of this framework's own
    # three runs, which is not known until all three have happened. Every run is
    # recorded here and the choice is made below.
    local _mdir=""
    [ "$endpoint" = "latency-1m" ] && _mdir=$(mktemp -d)

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
        # Exact cgroup CPU across exactly the window the load is applied in.
        # Cheap enough to take on every profile — two file reads — and it is
        # the measurement on the latency-1m profile rather than context.
        cpu_acct_start "$CONTAINER_NAME"
        output=$("${tool//-/_}_run" "${gc_args[@]}")
        cpu_acct_stop
        stats_stop

        # Print trimmed output (drop h2load-h3 per-thread spawn chatter).
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

        # Best-of-N keeps the fastest run — except on a fixed-rate profile,
        # where every run delivers the same rps by construction, so picking on
        # rps is a coin flip between them. There the run to keep is the cheapest
        # one, which also discards the warm-up for free: an unsettled JIT or GC
        # heap shows up as CPU, and run 1 is the one carrying it.
        local better=false
        if [ "$endpoint" = "latency-1m" ] && [ -n "${CPU_ACCT_USEC:-}" ]; then
            if [ -z "$best_cpu_usec" ] || [ "$CPU_ACCT_USEC" -lt "$best_cpu_usec" ]; then
                better=true
            fi
        elif [ "$rps_int" -gt "$best_rps" ] 2>/dev/null; then
            better=true
        fi

        if [ -n "$_mdir" ]; then
            "${tool//-/_}_parse" "$endpoint" "$output" > "$_mdir/$run.kv"
            printf '%s' "$output" > "$_mdir/$run.out"
            {
                printf 'cpu_usec=%s\n' "${CPU_ACCT_USEC:-}"
                printf 'stats_cpu=%s\n' "$STATS_AVG_CPU"
                printf 'stats_mem=%s\n' "$STATS_PEAK_MEM"
                printf 'stats_bd=%s\n' "$STATS_BREAKDOWN"
            } > "$_mdir/$run.meta"
        fi

        if $better; then
            best_rps=$rps_int
            best_cpu_usec="${CPU_ACCT_USEC:-}"
            best_rate_ratio="${m[rate_ratio]:-}"
            best_output="$output"
            best_cpu="$STATS_AVG_CPU"
            best_mem="$STATS_PEAK_MEM"
            best_breakdown="$STATS_BREAKDOWN"
            BEST_M=()
            for k in "${!m[@]}"; do BEST_M[$k]="${m[$k]}"; done
        fi

        # Cool-down between iterations. gcannon closes every connection when it
        # exits and the active closer holds the port for the kernel's fixed
        # ~60s TIME_WAIT, so a profile running tens of thousands of connections
        # hands the next iteration a port table that is already mostly spoken
        # for. tcp_tw_reuse lets those be recycled, but at 48K of a 64.5K-port
        # range the connect path starts scanning and the ramp lands inside the
        # measured window. Two seconds is plenty below that.
        if [ "$CONNS" -ge 32768 ]; then sleep 15; else sleep 2; fi
    done

    # ── Latency-1M: pick the run by score, not by any single metric ─────
    #
    # The published score weights rate, CPU and both latency tails together, so
    # choosing the run on CPU alone could keep a cheap run with a wrecked tail.
    # Each metric is normalised against the best of this framework's own three
    # runs -- self-contained, because the rest of the field does not exist yet
    # while this entry is being measured, and monotonic in the same direction as
    # the published score.
    if [ -n "$_mdir" ]; then
        local _win
        _win=$(python3 "$SCRIPT_DIR/latency_1m_score.py" --pick "$_mdir" 2>/dev/null || echo "")
        if [ -n "$_win" ] && [ -f "$_mdir/$_win.kv" ]; then
            info "run $_win wins on score"
            BEST_M=()
            while IFS= read -r line; do
                [[ "$line" == *=* ]] && BEST_M["${line%%=*}"]="${line#*=}"
            done < "$_mdir/$_win.kv"
            best_rps=${BEST_M[rps]:-0}
            best_rate_ratio="${BEST_M[rate_ratio]:-}"
            best_output=$(cat "$_mdir/$_win.out")
            best_cpu_usec=$(sed -n 's/^cpu_usec=//p' "$_mdir/$_win.meta")
            best_cpu=$(sed -n 's/^stats_cpu=//p' "$_mdir/$_win.meta")
            best_mem=$(sed -n 's/^stats_mem=//p' "$_mdir/$_win.meta")
            best_breakdown=$(sed -n 's/^stats_bd=//p' "$_mdir/$_win.meta")
        else
            warn "could not score the runs — keeping the cheapest by CPU"
        fi
        rm -rf "$_mdir"
    fi

    echo ""; echo "=== Best: ${best_rps} req/s (CPU: $best_cpu, Mem: $best_mem) ==="

    # The latency-1m profile's headline number, and the check that it counts.
    if [ "$endpoint" = "latency-1m" ]; then
        # Two different failures that used to print the same line. "No CPU
        # reading" is a cgroup problem; "no requests" is a generator or server
        # problem, and saying the former when it is the latter sent the first
        # board-wide run looking in the wrong place entirely.
        if [ "${BEST_M[status_2xx]:-0}" -eq 0 ] 2>/dev/null; then
            warn "no requests were served — there is nothing to measure here."
            warn "  this is a load-generator or server failure, not a CPU one; see the zrk output above"
        elif [ -z "$best_cpu_usec" ]; then
            warn "no cgroup CPU reading for this run — the latency-1m metric is missing"
        else
            info "exact CPU: $(awk -v c="$best_cpu_usec" 'BEGIN{printf "%.2f", c/1e6}') core-seconds \
| $(awk -v c="$best_cpu_usec" -v r="${BEST_M[status_2xx]}" 'BEGIN{printf "%.3f", c/r}') us/req"
        fi
        # Below ~0.98 the client never delivered the rate the profile is defined
        # by, so the CPU figure describes a different, lighter workload than
        # every other entry's. Louder than a note: it invalidates the comparison.
        if [ -n "$best_rate_ratio" ] \
           && awk -v r="$best_rate_ratio" 'BEGIN{exit !(r+0 < 0.98)}'; then
            warn "offered rate fell short: rate_ratio=$best_rate_ratio (target ${BEST_M[target_rate]:-?}/s)"
            warn "  the CPU number is not comparable with runs that held the rate"
        fi
    fi

    # Input bandwidth — bytes the server ingests per second. Matters for
    # profiles where the *request* body dominates (upload fixtures, crud writes) and where the response bandwidth alone
    # understates the actual work done. Computed as
    #    rps × mean(--raw fixture size)
    # which is the avg bytes/request sent by gcannon. Skipped when the
    # endpoint doesn't use --raw (baseline, pipeline, ws-echo, grpc, h2/h3
    # via other tools).
    local raw_arg=""
    local prev_was_raw=false
    local arg
    for arg in "${gc_args[@]}"; do
        if [ "$prev_was_raw" = "true" ]; then
            raw_arg="$arg"
            break
        fi
        [ "$arg" = "--raw" ] && prev_was_raw=true || prev_was_raw=false
    done
    if [ -n "$raw_arg" ] && [ "$best_rps" -gt 0 ] 2>/dev/null; then
        local avg_tpl_size
        avg_tpl_size=$(IFS=','; total=0; count=0
            for f in $raw_arg; do
                s=$(wc -c < "$f" 2>/dev/null || echo 0)
                total=$((total + s))
                count=$((count + 1))
            done
            [ "$count" -gt 0 ] && echo "$((total / count))" || echo "0")
        BEST_M[input_bw]=$(python3 -c "
bps = $best_rps * $avg_tpl_size
if bps >= 1073741824: print(f'{bps/1073741824:.2f}GB/s')
elif bps >= 1048576: print(f'{bps/1048576:.2f}MB/s')
elif bps >= 1024: print(f'{bps/1024:.2f}KB/s')
else: print(f'{bps}B/s')
" 2>/dev/null || echo "")
        [ -n "${BEST_M[input_bw]}" ] && info "input BW: ${BEST_M[input_bw]} (avg template: ${avg_tpl_size} bytes)"
    fi

    # ── Save results (--save) ───────────────────────────────────────────
    if [ "$SAVE_RESULTS" = "true" ]; then
        save_result "$profile" "$CONNS" "$best_rps" "$best_cpu" "$best_mem" \
                    "$best_cpu_usec" "$best_rate_ratio"
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
# gateway-64 / gateway-h3 carry per-template response counts (tpl_baseline /
# tpl_json / tpl_async_db / tpl_static), split from the load generator's total
# 2xx proportionally across the 20-URI mix (6 static, 4 baseline, 7 json, 3 db).
# The board does not read them today -- the only consumer was the api-4/api-16
# template mix, which went with those profiles -- but they are the record of
# what the gateway run was actually made of, so they keep being written.
save_result() {
    local profile="$1" CONNS="$2" best_rps="$3" best_cpu="$4" best_mem="$5"
    local best_cpu_usec="${6:-}" best_rate_ratio="${7:-}"
    local dir="$RESULTS_DIR/$profile/$CONNS"
    mkdir -p "$dir"

    # Latency-1M publishes what the profile is about. `cpu` above is still the
    # sampled percentage every profile carries; these are the exact figures:
    # CPU microseconds out of the container's own cgroup, the same number per
    # request, and the evidence that the offered rate was actually delivered.
    # rate_ratio is the one that decides whether the rest means anything — a run
    # that fell short of 500K did not measure this profile, because the load was
    # not the load, so the reason ships with the row rather than being inferred
    # from an rps that looks merely slow.
    local eff_extra=""
    if [ "$profile" = "latency-1m" ]; then
        local _eff_reqs=${BEST_M[status_2xx]:-0}
        local _eff_per_req="null"
        if [ -n "$best_cpu_usec" ] && [ "$_eff_reqs" -gt 0 ] 2>/dev/null; then
            _eff_per_req=$(awk -v c="$best_cpu_usec" -v r="$_eff_reqs" 'BEGIN{printf "%.4f", c/r}')
        fi
        eff_extra=",
  \"cpu_usec\": ${best_cpu_usec:-null},
  \"cpu_per_req_us\": $_eff_per_req,
  \"target_rate\": ${BEST_M[target_rate]:-0},
  \"rate_ratio\": ${best_rate_ratio:-0},
  \"p99_9_latency\": \"${BEST_M[p999_lat]:-}\""
    fi

    local cpu_extra=""
    if [ -n "$best_breakdown" ]; then
        cpu_extra=",
  \"cpu_breakdown\": \"$best_breakdown\""
    fi

    local tpl_extra=""
    if { [ "$profile" = "gateway-64" ] || [ "$profile" = "gateway-h3" ]; } \
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
    elif [ "$profile" = "production-stack" ] \
         && [ "${BEST_M[status_2xx]:-0}" -gt 0 ] 2>/dev/null; then
        # Production-stack mix from reads file (20K URIs):
        # 6000 static (30%) / 2000 baseline (10%) / 10000 items (50%) / 2000 me (10%).
        # Writes (POST /api/items) add to items but are small (~5% of traffic).
        local total=${BEST_M[status_2xx]}
        tpl_extra=",
  \"tpl_static\": $(( total * 30 / 100 )),
  \"tpl_baseline\": $(( total * 10 / 100 )),
  \"tpl_items\": $(( total * 50 / 100 )),
  \"tpl_me\": $(( total * 10 / 100 ))"
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
  "duration": "${BEST_M[duration]:-$DURATION}",
  "pipeline": $PROF_PIPELINE,
  "bandwidth": "${BEST_M[bandwidth]:-0}",$([ -n "${BEST_M[input_bw]:-}" ] && printf '\n  "input_bw": "%s",' "${BEST_M[input_bw]}")
  "reconnects": ${BEST_M[reconnects]:-0},
  "status_2xx": ${BEST_M[status_2xx]:-0},
  "status_3xx": ${BEST_M[status_3xx]:-0},
  "status_4xx": ${BEST_M[status_4xx]:-0},
  "status_5xx": ${BEST_M[status_5xx]:-0}${tpl_extra}${eff_extra}${cpu_extra}
}
EOF
    info "saved results/$profile/$CONNS/${FRAMEWORK}.json"

    # Persist container logs alongside results for post-mortem.
    local log_dir="$ROOT_DIR/site/static/logs/$profile/$CONNS"
    mkdir -p "$log_dir"
    # Cap what a noisy container can write. A framework that logs per request
    # produces a log proportional to throughput: sanic's static run emitted a
    # traceback on every request and reached 240MB, which GitHub then refused to
    # accept - the push is rejected over the 100MB file limit, after the whole
    # benchmark has already run. Keep the tail, which is where a post-mortem
    # looks anyway, and say so in the file when it was cut.
    local log_max=${HTTPARENA_MAX_LOG_BYTES:-8000000}
    local log_file="$log_dir/${FRAMEWORK}.log"
    docker logs "$CONTAINER_NAME" >"$log_file" 2>&1 || true
    local log_size
    log_size=$(stat -c %s "$log_file" 2>/dev/null || echo 0)
    if [ "$log_size" -gt "$log_max" ] 2>/dev/null; then
        tail -c "$log_max" "$log_file" >"$log_file.tail" 2>/dev/null || true
        {
            echo "[httparena] container log was ${log_size} bytes and has been"
            echo "[httparena] truncated to the last ${log_max}; a framework that"
            echo "[httparena] logs per request is usually the cause."
            echo
            cat "$log_file.tail"
        } >"$log_file"
        rm -f "$log_file.tail"
        warn "$FRAMEWORK $profile/$CONNS: container log was ${log_size} bytes, truncated to ${log_max}"
    fi
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
