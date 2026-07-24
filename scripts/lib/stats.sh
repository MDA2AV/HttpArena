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
#                                 # and STATS_MEM_DETAIL
#
# `docker stats` reports memory.current minus inactive_file, so it already
# excludes most page cache - but that single number says nothing about what
# the memory actually is. #1015 asks whether the published figures are really
# the application's memory; answering it needs the composition, not another
# opinion. So alongside the existing number we record the cgroup's own
# accounting (anon, file, sock, slab, kernel) at the moment of peak usage and
# store it on the result row for later analysis. Nothing consumes it yet: the
# leaderboard still reads `memory`.

STATS_PID=""
STATS_LOG=""
STATS_CG_LOG=""
STATS_AVG_CPU="0%"
STATS_PEAK_MEM="0MiB"
STATS_BREAKDOWN=""
STATS_MEM_DETAIL=""

# Fields worth keeping from cgroup v2 memory.stat. anon is application memory,
# file is page cache (active_file is the part docker still counts), sock is
# kernel socket buffers - which at 4096 connections is not a rounding error -
# and slab/kernel are kernel structures charged to the container.
STATS_CG_FIELDS="anon file active_file inactive_file sock slab kernel"

# Resolve a container's cgroup directory. Layout varies with the cgroup driver
# (systemd vs cgroupfs) and version, so try the known shapes and give up
# quietly - this is supplementary data, never a reason to fail a run.
_cg_dir() {
    local id="$1" p
    for p in "/sys/fs/cgroup/system.slice/docker-$id.scope" \
             "/sys/fs/cgroup/docker/$id" \
             "/sys/fs/cgroup/memory/docker/$id"; do
        [ -r "$p/memory.stat" ] && { echo "$p"; return 0; }
    done
    return 1
}

# Start a background poller. Accepts one or more container names. Each
# sample writes one line per container, tagged with a snapshot counter so
# stats_stop can reconstruct both per-snapshot sums (aggregate) and
# per-container series (breakdown) without double-polling docker.
#
# Log line format: <snap> <container-name> <cpu%> <mem-MiB>
stats_start() {
    STATS_LOG=$(mktemp)
    STATS_CG_LOG=$(mktemp)
    local containers=("$@")

    # Resolve cgroup paths once; container ids don't change mid-run.
    local _cg_paths=() _c _id _dir
    for _c in "${containers[@]}"; do
        _id=$(docker inspect -f '{{.Id}}' "$_c" 2>/dev/null) || continue
        _dir=$(_cg_dir "$_id") || continue
        _cg_paths+=("$_dir")
    done

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

            # cgroup accounting for the same snapshot, summed across containers
            for _d in "${_cg_paths[@]}"; do
                awk -v snap="$snap" -v want="$STATS_CG_FIELDS" '
                    BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) keep[w[i]] = 1 }
                    keep[$1] { printf "%s %s %s\n", snap, $1, $2 }
                ' "$_d/memory.stat" 2>/dev/null
                awk -v snap="$snap" '{ printf "%s current %s\n", snap, $1 }' \
                    "$_d/memory.current" 2>/dev/null
            done >>"$STATS_CG_LOG"
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

    # ── cgroup composition at the peak snapshot ─────────────────────────
    #    Reported as MiB per field. The snapshot is chosen by total memory so
    #    the breakdown describes the same moment STATS_PEAK_MEM reports,
    #    rather than being a max-per-field mixture of different instants.
    STATS_MEM_DETAIL=""
    if [ -s "${STATS_CG_LOG:-/dev/null}" ]; then
        STATS_MEM_DETAIL=$(awk '
            { v[$1 SUBSEP $2] += $3; if (!($1 in seen)) { seen[$1]=1 } }
            END {
                best = ""; bestv = -1
                for (k in v) {
                    split(k, a, SUBSEP)
                    if (a[2] == "current" && v[k] > bestv) { bestv = v[k]; best = a[1] }
                }
                if (best == "") exit
                n = split("current anon file active_file inactive_file sock slab kernel", f, " ")
                out = ""
                for (i = 1; i <= n; i++) {
                    key = best SUBSEP f[i]
                    if (key in v) {
                        if (out != "") out = out ","
                        out = out sprintf("\"%s\":%.1f", f[i], v[key] / 1048576)
                    }
                }
                print out
            }
        ' "$STATS_CG_LOG")
    fi
    rm -f "${STATS_CG_LOG:-}" 2>/dev/null || true
    STATS_CG_LOG=""

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
