#!/bin/sh
# Julia fixes its thread count at startup, so the CPU count is read here and
# passed to the process that serves: one interactive thread per core, which is
# the pool HTTP.jl runs connections on. cgroup v2 quota wins over the affinity
# mask when it is the smaller of the two, same idea as koa's getCPUCount.
set -e

cpus=$(nproc)
if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r quota period </sys/fs/cgroup/cpu.max
    if [ "$quota" != "max" ] && [ -n "$period" ]; then
        q=$((quota / period))
        if [ "$q" -ge 1 ] && [ "$q" -lt "$cpus" ]; then
            cpus=$q
        fi
    fi
fi

exec julia --project=/app --startup-file=no --threads=1,"$cpus" /app/app.jl
