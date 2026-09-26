#!/usr/bin/env bash
# Why libioxd costs 131 us of CPU a request on 8gbit here while the same images,
# the same paced load and the same cgroup accounting cost it 12 us on an 8-core
# desktop - where it is 22% cheaper than edixoi, not 3.1x dearer.
#
# The profile hands the entry 64 CPUs for a load paced at 50k rps, so it starts
# 64 workers, each serving ~770 rps and sleeping between requests: nearly every
# request has to wake a thread on an idle core. This runs the profile unchanged -
# same generator, same connection count, same cpusets, same cgroup CPU window -
# varying only the worker count, which the entry already takes as its first
# argument. Every row is otherwise the same run.
#
# How to read it:
#   CPU a request falls sharply as workers drop  -> the cost is wake-ups, the
#       server is sized wrong for a paced profile, and the fix belongs in the
#       library (workers sized to load, or parking idle ones).
#   CPU a request stays flat                     -> worker count is a red
#       herring; the cost is per request inside the server on this hardware and
#       only a profiled run will find it.
#
# Measured on an 8-core i9 for reference, TLS, 512 conns: 780 rps a worker costs
# 18.85 us a request against 13.67 at 3100 rps a worker - 28%. If that is the
# whole story here, 64 -> 16 workers should recover far more than 28%, because
# on this machine a wake-up also crosses chiplets.
#
#   ./scripts/diagnose-libioxd-workers.sh
#   WORKER_COUNTS="64 16" ./scripts/diagnose-libioxd-workers.sh
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
source "$SOURCE_DIR/common.sh"
source "$SOURCE_DIR/system.sh"
source "$SOURCE_DIR/stats.sh"
source "$SOURCE_DIR/framework.sh"
source "$SOURCE_DIR/profiles.sh"
source "$SOURCE_DIR/tools/zrk.sh"

cd "$ROOT_DIR"

PROFILE="${PROFILE:-8gbit}"
WORKER_COUNTS="${WORKER_COUNTS:-64 32 16 8}"

[ -n "${PROFILES[$PROFILE]+x}" ] || fail "unknown profile: $PROFILE"
parse_profile "${PROFILES[$PROFILE]}"
CONNS="$PROF_CONNS"

framework_load_meta libioxd
framework_build

# The same host state a scored run measures under: governor on performance and
# the loopback MTU the profile expects. Restored on the way out, as benchmark.sh
# does it.
trap 'unset FRAMEWORK_CMD_ARGS; framework_stop 2>/dev/null || true; system_restore' EXIT
system_tune

banner "libioxd / $PROFILE / ${CONNS}c — CPU a request against worker count"
printf '%-8s %-9s %-16s %-13s %-11s\n' workers rps cpu_us_per_req avg_latency p99
for W in $WORKER_COUNTS; do
    export FRAMEWORK_CMD_ARGS="/server $W"
    framework_start "$PROF_ENDPOINT" "$PROF_CPU"
    unset FRAMEWORK_CMD_ARGS
    framework_wait_ready "$PROF_ENDPOINT"

    mapfile -t cmd < <(zrk_build_args "$PROF_ENDPOINT" "$CONNS" "$PROF_PIPELINE" "$DURATION")
    cpu_acct_start "$CONTAINER_NAME"
    output=$(zrk_run "${cmd[@]}")
    cpu_acct_stop

    declare -A m=()
    while IFS= read -r line; do
        [[ "$line" == *=* ]] && m["${line%%=*}"]="${line#*=}"
    done < <(zrk_parse "$PROF_ENDPOINT" "$output")

    served=${m[status_2xx]:-0}
    if [ -n "${CPU_ACCT_USEC:-}" ] && [ "$served" -gt 0 ] 2>/dev/null; then
        cpu_per_req=$(awk -v u="$CPU_ACCT_USEC" -v n="$served" 'BEGIN { printf "%.2f", u / n }')
    else
        cpu_per_req="not measured"          # cgroup v1, rootless docker, or no 2xx
    fi
    printf '%-8s %-9s %-16s %-13s %-11s\n' \
        "$W" "${m[rps]:-0}" "$cpu_per_req" "${m[avg_lat]:-?}" "${m[p99_lat]:-?}"

    # The server's own line reports the ring it built; keep it beside the row.
    docker logs "$CONTAINER_NAME" 2>&1 | grep -m1 'listening on' || true
    framework_stop >/dev/null          # it echoes the container name; keep the table readable
done
