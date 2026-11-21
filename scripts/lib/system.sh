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
    # profiles that churn connections (static-tls with -r 200 retires sockets
    # continuously at 6800c) don't exhaust the default 28K-port range and
    # silently stall gcannon after the first iteration. TIME_WAIT duration
    # itself is hardcoded in the kernel (~60s) and cannot be shortened via
    # sysctl, so we rely on port-range + tw_reuse + between-iteration sleep
    # to recycle. Loopback-bench only — not settings for a public server.
    sudo sysctl -w net.ipv4.ip_local_port_range='1024 65535' >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_max_tw_buckets=131072        >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_tw_reuse=1                   >/dev/null 2>&1 || true

    # Widening the range above put every port a server binds inside the pool the
    # kernel draws outbound connections from, so a load generator can be sitting
    # on one when a later profile tries to listen on it. That is what killed
    # production-stack at the end of a full run: authsvc panicked with
    # "bind 0.0.0.0:9090: Address in use", and because the edge waits on it the
    # whole stack aborted. Running the same profile first, with no load behind
    # it, passed. tcp_tw_reuse does not help - it governs outbound reuse, not a
    # listening bind.
    #
    # ip_local_reserved_ports takes these out of ephemeral allocation while
    # leaving them bindable, which is exactly the case it exists for. Every
    # fixed port the harness or a stack listens on belongs here: 8080/8081/8082/
    # 8443 from common.sh, 9090 for the production-stack auth sidecar, 6379 and
    # 5432 for the Redis and Postgres sidecars.
    sudo sysctl -w net.ipv4.ip_local_reserved_ports='5432,6379,8080,8081,8082,8443,9090' \
        >/dev/null 2>&1 || warn "ip_local_reserved_ports"

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

# Raise a sysctl to at least `want`; never lowers one that is already higher.
_raise_sysctl() {
    local key="$1" want="$2" have
    have=$(sysctl -n "$key" 2>/dev/null) || { warn "sysctl $key is not available"; return 0; }
    [ "$have" -ge "$want" ] 2>/dev/null && return 0
    sudo sysctl -w "$key=$want" >/dev/null 2>&1 || warn "could not raise $key ($have < $want)"
}

# The limits millions of held connections run into, raised only when the run
# includes a held-connection profile (connections-5m, connections-1m-tls,
# connections-1m). Each one is a ceiling rather than a setting, so a host
# left with them raised measures every other profile exactly as before; like
# the governor, they are not put back.
#
#   fs.nr_open                  the most fds a process may be given, and the
#                               ceiling on RLIMIT_NOFILE. Five million sockets
#                               in one server, and five million more in one
#                               gcannon, need 8M (CONN5M_NOFILE) to be allowed
#   vm.max_map_count            zrk (connections-1m) maps a stack plus a
#                               guard per coroutine: ~4 maps a connection,
#                               ~125K for one process's 31,250, against a
#                               65,530 default
#   net.netfilter.nf_conntrack_max
#                               docker's rules switch conntrack on for the
#                               host, loopback included, and a full table drops
#                               SYNs. Five million live entries plus the last
#                               run's five million in TIME_WAIT (120s) need
#                               room for both
#   nf_conntrack hashsize       so those entries are not chained deep in a
#                               table sized for a quarter of a million
system_tune_held_connections() {
    info "raising host limits for the held-connection profiles"
    _raise_sysctl fs.nr_open 16777216
    _raise_sysctl vm.max_map_count 4194304
    if [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
        _raise_sysctl net.netfilter.nf_conntrack_max 16777216
        local hs=/sys/module/nf_conntrack/parameters/hashsize
        if [ -r "$hs" ] && [ "$(cat "$hs" 2>/dev/null || echo 0)" -lt 4194304 ] 2>/dev/null; then
            sudo sh -c "echo 4194304 > $hs" 2>/dev/null || warn "could not raise the conntrack hash size"
        fi
    fi
}

# ── Held connections: wait out the last fleet ───────────────────────────────
#
# A held-connection run ends with millions of sockets to close, and a process
# exiting does not close them by itself: gcannon before 0.8.3 leaves its whole
# fleet to one kernel worker after it exits, and a server stopped while still
# holding its side hands that to the kernel the same way. On the bench host a
# 60 s cool-down was shorter than that: runs 2 and 3 of connections-5m
# connected in 178 s and 300 s against run 1's 63 s, with 28-31 GiB less memory
# available, and measured p50 6.0 / 7.5 ms against 0.35 ms. So the harness
# waits for the socket count to come back down rather than for a fixed time.

# TCP sockets the kernel holds in any state but TIME_WAIT (kept apart, capped by
# tcp_max_tw_buckets): "alloc" in /proc/net/sockstat. A socket counts until it
# is freed, so a fleet still being closed after its process exited counts too.
host_tcp_sockets() {
    awk '$1 == "TCP:" { for (i = 2; i < NF; i += 2) if ($i == "alloc") { print $(i + 1); exit } }' \
        /proc/net/sockstat 2>/dev/null || true
}

# What a drain waits to get under: the host's count with nothing of ours
# running, plus HELD_CONN_DRAIN_SLACK. Taken once, before the first profile; a
# host still closing someone else's fleet counts as holding 20,000 at most.
HELD_CONN_DRAIN_TARGET=""
held_conn_baseline() {
    local base
    base=$(host_tcp_sockets)
    [ -n "$base" ] || return 0
    if [ "$base" -gt 20000 ]; then
        warn "the host already holds $base TCP sockets; held-connection runs wait for it to get under $((20000 + HELD_CONN_DRAIN_SLACK))"
        base=20000
    fi
    HELD_CONN_DRAIN_TARGET=$((base + HELD_CONN_DRAIN_SLACK))
}

# held_conn_drain <when>: wait until the host is back under
# HELD_CONN_DRAIN_TARGET. Gives up, and says so, when the count has not fallen
# by a thousand in HELD_CONN_DRAIN_STALL seconds (a server that never closes its
# side: stopping it hands the rest to the kernel, and the next drain waits for
# that) or after HELD_CONN_DRAIN_TIMEOUT seconds in all.
held_conn_drain() {
    local when="$1" cur
    [ -n "$HELD_CONN_DRAIN_TARGET" ] || return 0
    cur=$(host_tcp_sockets)
    [ -n "$cur" ] || return 0
    [ "$cur" -le "$HELD_CONN_DRAIN_TARGET" ] && return 0
    local from=$cur start=$SECONDS best=$cur best_at=$SECONDS
    while [ "$cur" -gt "$HELD_CONN_DRAIN_TARGET" ]; do
        if [ $((SECONDS - start)) -ge "$HELD_CONN_DRAIN_TIMEOUT" ]; then
            warn "teardown $when: $cur TCP sockets still open after ${HELD_CONN_DRAIN_TIMEOUT}s (from $from); going on"
            return 0
        fi
        if [ $((SECONDS - best_at)) -ge "$HELD_CONN_DRAIN_STALL" ]; then
            warn "teardown $when: stuck at $cur TCP sockets for ${HELD_CONN_DRAIN_STALL}s (from $from); going on"
            return 0
        fi
        sleep 1
        cur=$(host_tcp_sockets)
        [ -n "$cur" ] || return 0
        if [ "$cur" -lt $((best - 1000)) ]; then best=$cur; best_at=$SECONDS; fi
    done
    info "teardown $when: $from -> $cur TCP sockets in $((SECONDS - start))s"
}

# Revert everything we touched. Call from EXIT trap.
system_restore() {
    info "restoring loopback MTU to 65536"
    sudo ip link set lo mtu 65536 2>/dev/null || true

    # CPU governor is deliberately left on performance — not restored to the
    # box default (powersave). Keeps boost residency stable across runs.
}
