# scripts/lib/stats.sh — docker CPU/memory sampling during a run.
#
# Uses `docker stats --no-stream` in a background polling loop. An earlier
# version tried to stream `docker stats` with `--no-stream` omitted for
# efficiency, but docker's CLI buffers pipe output and the log never
# flushes before we kill it — resulting in zero samples and CPU=0%.
# The polling approach is slightly less efficient (one docker CLI spawn
# per sample, ~2 Hz) but reliably produces clean line-oriented output.
#
# Usage:
#   stats_start <container...>    # starts background collector
#   stats_stop                    # stops, fills STATS_AVG_CPU / STATS_PEAK_MEM
#                                 # and (multi-container) STATS_BREAKDOWN

STATS_PID=""
STATS_LOG=""
STATS_AVG_CPU="0%"
STATS_PEAK_MEM="0MiB"
STATS_BREAKDOWN=""

# Start a background poller. Accepts one or more container names. Each
# sample writes one line per container, tagged with a snapshot counter so
# stats_stop can reconstruct both per-snapshot sums (aggregate) and
# per-container series (breakdown) without double-polling docker.
#
# Log line format: <snap> <container-name> <cpu%> <mem-MiB>
stats_start() {
    STATS_LOG=$(mktemp)
    local containers=("$@")
    (
        local snap=0
        while true; do
            snap=$((snap + 1))
            docker stats --no-stream \
                --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' \
                "${containers[@]}" 2>/dev/null \
                | awk -F'|' -v snap="$snap" '{
                    name = $1
                    cpu = $2; gsub(/%/, "", cpu)
                    # MemUsage is "1.234GiB / 16GiB" — split on " / ", keep first.
                    split($3, parts, " / ")
                    raw = parts[1]
                    unit = raw
                    gsub(/[0-9.]/, "", unit)
                    gsub(/[^0-9.]/, "", raw)
                    mem_mib = raw + 0
                    if (unit == "GiB") mem_mib *= 1024
                    else if (unit == "KiB") mem_mib /= 1024
                    else if (unit == "B")   mem_mib /= (1024 * 1024)
                    printf "%s %s %.2f %.2f\n", snap, name, cpu, mem_mib
                }'
        done
    ) >"$STATS_LOG" 2>/dev/null &
    STATS_PID=$!
}

stats_stop() {
    [ -n "$STATS_PID" ] && kill "$STATS_PID" 2>/dev/null
    wait "$STATS_PID" 2>/dev/null || true

    STATS_AVG_CPU="0%"
    STATS_PEAK_MEM="0MiB"
    STATS_BREAKDOWN=""

    if [ ! -s "$STATS_LOG" ]; then
        rm -f "$STATS_LOG"
        STATS_PID=""; STATS_LOG=""
        return
    fi

    # ── Aggregate (stack-wide) — mean of per-snapshot CPU sums, max of
    #    per-snapshot mem sums. Preserves the existing single-number shape
    #    that the result JSON writer expects.
    STATS_AVG_CPU=$(awk '
        { cpu[$1] += $3 }
        END {
            n = 0; sum = 0
            for (s in cpu) { sum += cpu[s]; n++ }
            if (n > 0) printf "%.1f%%", sum / n; else print "0%"
        }
    ' "$STATS_LOG")

    STATS_PEAK_MEM=$(awk '
        { mem[$1] += $4 }
        END {
            max = 0
            for (s in mem) if (mem[s] > max) max = mem[s]
            if (max >= 1024) printf "%.1fGiB", max / 1024
            else printf "%.0fMiB", max
        }
    ' "$STATS_LOG")

    # ── Per-container breakdown — average CPU and peak mem per container,
    #    rendered as "proxy: 4200% 1.2GiB | server: 1200% 512MiB". Skipped
    #    entirely when only one container was sampled (the breakdown would
    #    be identical to the aggregate and adds noise).
    local n_containers
    n_containers=$(awk '{ names[$2]=1 } END { n=0; for (k in names) n++; print n }' "$STATS_LOG")
    if [ "$n_containers" -gt 1 ]; then
        STATS_BREAKDOWN=$(awk '
            {
                cpu_sum[$2] += $3; cpu_n[$2]++
                if ($4 > mem_max[$2]) mem_max[$2] = $4
            }
            END {
                # Short-name heuristic: strip a numeric trailing suffix
                # (compose index like "-1") and keep the last hyphen-
                # separated token (service name). Works for the
                # compose pattern "httparena-<fw>-<service>-<n>" and for
                # plain container names like "httparena-bench-<fw>".
                first = 1
                for (name in cpu_sum) {
                    n = split(name, parts, "-")
                    if (parts[n] ~ /^[0-9]+$/ && n > 1) short = parts[n-1]
                    else short = parts[n]

                    avg = cpu_sum[name] / cpu_n[name]
                    mem = mem_max[name]
                    if (!first) printf " | "
                    if (mem >= 1024) printf "%s: %.0f%% %.1fGiB", short, avg, mem / 1024
                    else             printf "%s: %.0f%% %.0fMiB", short, avg, mem
                    first = 0
                }
            }
        ' "$STATS_LOG")
    fi

    rm -f "$STATS_LOG"
    STATS_PID=""
    STATS_LOG=""
}

# ── Exact CPU accounting (cgroup v2) ────────────────────────────────────────
#
# The sampler above averages an instantaneous percentage taken at ~2Hz. That is
# fine where CPU is context for a throughput number. It is not fine where CPU
# *is* the number: the error is whatever the container happened to be doing on
# each tick, and a 20s run only gets ~40 of them.
#
# The kernel already has the exact figure. cgroup v2's cpu.stat carries a
# monotonic usage_usec for the container's own cgroup, so the difference across
# a run is the CPU time it actually consumed, to the microsecond, with no
# sampling in the path at all.
#
# Sets CPU_ACCT_USEC to that delta, or leaves it empty when the cgroup file is
# not readable — cgroup v1, rootless docker, or a container that already exited.
# Callers must treat empty as "not measured" rather than as zero.
CPU_ACCT_USEC=""
_CPU_ACCT_START=""
_CPU_ACCT_PATH=""

_cgroup_cpu_path() {
    local id
    id=$(docker inspect -f '{{.Id}}' "$1" 2>/dev/null) || return 1
    [ -n "$id" ] || return 1
    local p
    for p in "/sys/fs/cgroup/system.slice/docker-$id.scope/cpu.stat" \
             "/sys/fs/cgroup/docker/$id/cpu.stat"; do
        if [ -r "$p" ]; then printf '%s' "$p"; return 0; fi
    done
    return 1
}

_cgroup_cpu_usec() {
    awk '/^usage_usec/ { print $2; exit }' "$1" 2>/dev/null
}

cpu_acct_start() {
    CPU_ACCT_USEC=""
    _CPU_ACCT_START=""
    _CPU_ACCT_PATH=$(_cgroup_cpu_path "$1") || _CPU_ACCT_PATH=""
    [ -n "$_CPU_ACCT_PATH" ] || return 0
    _CPU_ACCT_START=$(_cgroup_cpu_usec "$_CPU_ACCT_PATH")
}

cpu_acct_stop() {
    CPU_ACCT_USEC=""
    [ -n "$_CPU_ACCT_PATH" ] && [ -n "$_CPU_ACCT_START" ] || return 0
    local end
    end=$(_cgroup_cpu_usec "$_CPU_ACCT_PATH")
    [ -n "$end" ] || return 0
    CPU_ACCT_USEC=$(( end - _CPU_ACCT_START ))
    # A container restarted mid-run resets the counter; a negative delta is a
    # measurement that did not happen, not a measurement of zero.
    [ "$CPU_ACCT_USEC" -ge 0 ] 2>/dev/null || CPU_ACCT_USEC=""
}
