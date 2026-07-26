# scripts/lib/system.sh — host-level tuning: CPU governor, loopback MTU,
# kernel socket limits, docker daemon restart, page cache drop. Everything
# that affects measurement stability lives here.
#
# Usage:
#   system_tune      # apply all settings
#   system_restore   # revert per-run state (loopback MTU) on EXIT trap

# Apply system tuning. Safe to call multiple times.
system_tune() {
    info "tuning host for benchmark runs"

    # CPU governor → performance. Intentionally NOT reverted afterwards (see
    # system_restore): this is a dedicated bench host, and the old
    # revert-to-powersave was drifting the box off performance between runs.
    if command -v cpupower &>/dev/null; then
        # cpupower prints "Setting cpu: N" for every core — silence stdout,
        # keep stderr. Check exit code to report success/failure.
        if sudo cpupower frequency-set -g performance >/dev/null 2>&1; then
            info "CPU governor → performance"
        else
            warn "could not set CPU governor (no sudo?)"
        fi
    else
        for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            sudo sh -c "echo performance > $g" 2>/dev/null || true
        done
    fi

    info "setting kernel socket limits"
    sudo sysctl -w net.core.somaxconn=65535          >/dev/null 2>&1 || warn "somaxconn"
    sudo sysctl -w net.ipv4.tcp_max_syn_backlog=65535 >/dev/null 2>&1 || true
    sudo sysctl -w net.core.netdev_max_backlog=65535  >/dev/null 2>&1 || true

    # Widen the ephemeral port range and cap TIME_WAIT bucket count so
    # profiles that churn connections (crud with -r 25 does ~40K reconnects
    # per iteration at 4096c) don't exhaust the default 28K-port range and
    # silently stall gcannon after the first iteration. TIME_WAIT duration
    # itself is hardcoded in the kernel (~60s) and cannot be shortened via
    # sysctl, so we rely on port-range + tw_reuse + between-iteration sleep
    # to recycle. Loopback-bench only — not settings for a public server.
    sudo sysctl -w net.ipv4.ip_local_port_range='1024 65535' >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_max_tw_buckets=131072        >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_tw_reuse=1                   >/dev/null 2>&1 || true

    info "setting UDP buffer sizes for QUIC"
    sudo sysctl -w net.core.rmem_max=7500000 >/dev/null 2>&1 || true
    sudo sysctl -w net.core.wmem_max=7500000 >/dev/null 2>&1 || true

    info "setting loopback MTU to 1500 (realistic Ethernet)"
    sudo ip link set lo mtu 1500 2>/dev/null || warn "could not set loopback MTU"

    info "restarting docker daemon"
    if sudo systemctl restart docker 2>/dev/null; then
        # Wait for daemon + networking + buildkit to come back. A plain
        # `sleep 3` is too short — buildkit DNS can still be broken. Poll
        # `docker info` (fast, daemon-only) up to 15s, then an extra 2s
        # of slack for network namespace creation to settle.
        local i
        for i in $(seq 1 15); do
            if docker info >/dev/null 2>&1; then
                sleep 2
                break
            fi
            sleep 1
        done
    else
        warn "could not restart docker daemon (no sudo?)"
    fi

    info "dropping kernel caches"
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
    sync
}

# Revert everything we touched. Call from EXIT trap.
system_restore() {
    info "restoring loopback MTU to 65536"
    sudo ip link set lo mtu 65536 2>/dev/null || true

    # CPU governor is deliberately left on performance — not restored to the
    # box default (powersave). Keeps boost residency stable across runs.
}
