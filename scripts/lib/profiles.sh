# scripts/lib/profiles.sh — profile definitions and parsing.
#
# Profile format: "pipeline|req_per_conn|cpu_limit|connections|endpoint"
#   pipeline      — gcannon -p value (1 for non-pipelined)
#   req_per_conn  — gcannon -r value (0 = unlimited)
#   cpu_limit     — container cpuset (e.g. "0-31,64-95") or cpu count
#   connections   — comma-separated list; each value is a separate run
#   endpoint      — dispatch key; tells the driver which tool + shape to use
#
# Adding a profile: add a line to PROFILES and append to PROFILE_ORDER.

# The database profiles split the box three ways instead of two, because Postgres
# does real work on them and needs CPUs of its own: 32 logical CPUs for the server,
# 32 for the load generator and the rest for Postgres. Each is a run of cores plus
# their SMT siblings (N and N+64 on the bench host), the way every other profile
# pairs them. The other profiles give the server and the generator 64 each, which
# leaves Postgres nowhere to run but on top of them.
DB_SERVER_CPUS="${DB_SERVER_CPUS:-0-15,64-79}"
DB_LOADGEN_CPUS="${DB_LOADGEN_CPUS:-16-31,80-95}"
DB_POSTGRES_CPUS="${DB_POSTGRES_CPUS:-32-63,96-127}"
DB_THREADS="${DB_THREADS:-32}"

declare -A PROFILES=(
    [baseline]="1|0|0-31,64-95|4096|"
    [pipelined]="16|0|0-31,64-95|4096|pipeline"
    [limited-conn]="1|10|0-31,64-95|4096|"
    # Async: GET /delay/10 (requests/async-delay.raw), a flat 10ms wait over
    # 32000 held connections (req_per_conn=0), so every one of them is a
    # pending timer the server has to carry. #1341 settled it there after the
    # 15ms/64000 round below; the ceiling is conns/delay = 3.2M rps.
    #
    # History, since the delay is the knob everything else hangs off:
    #   10-30ms draw, 32768/49152c  ceiling 1.64M/2.46M, tokio at 93%/83%
    #   flat 10ms,    64000c        ceiling 6.4M,        tokio 2240622 (35%)
    #   flat 15ms,    64000c        ceiling 4.27M
    # tokio gained 10% for a ceiling that had more than doubled, which is what
    # capacity-bound looks like — the delay stopped being the limiter at 10ms.
    #
    # Which is why 15 and not 5. The delay cuts both ways: an async server is
    # capped at conns/delay, a blocking one at threads/delay, so shortening it
    # frees a blocked thread sooner and narrows the gap this profile exists to
    # show. At 15ms a 64-thread blocking server tops out at 4267 rps against
    # tokio's measured 2.24M. It also leaves the 3-4ms a sloppy timer costs at
    # about a quarter of the wait rather than most of it.
    #
    # 4.27M sits just under the ~4.4M baseline peak, which puts the ceiling back
    # in play as a correctness check: nothing can beat conns/delay while
    # honouring the delay, so a result above it did not wait.
    #
    # 64000 rather than 65536: system_tune() widens ip_local_port_range to
    # 1024-65535 and gcannon needs one ephemeral port per connection, so 64505
    # are usable after ip_local_reserved_ports. 65536 connections to one
    # localhost:8080 cannot be established at all — the whole 16-bit port space
    # is smaller than that. 64000 fits with ~500 ports to spare; if the ramp
    # ever shows up as connect errors, 61440 is the next stop down.
    [async]="1|0|0-31,64-95|32000|async"
    # Latency-1M: the offered rate is pinned at 1M req/s (see ZRK_FIXED_RATE
    # in tools/zrk.sh) and the measurement is what the server spent to serve
    # it, read exactly out of the container's cgroup rather than sampled.
    #
    # Every other profile here asks how fast a server can go. Real servers
    # spend almost all of their time nowhere near that, so this asks the
    # question from the other end: at a load everybody can carry, who carries
    # it cheaply. 1024 connections because the socket count is part of the
    # workload — 500K req/s needs only ~15 in flight, so the rest of them are
    # there to be polled, which is exactly the cost being compared.
    [latency-1m]="1|0|0-31,64-95|1024|latency-1m"
    # Latency-10K: latency-1m's shape with the offered rate two orders of
    # magnitude lower. Same cpuset, same connection count, same endpoint, same
    # duration -- the rate is the only variable, which is what makes the two
    # numbers comparable.
    #
    # Where latency-1m asks what a server costs at a load only the fastest
    # entries carry, this asks what it costs while nearly idle, which is where
    # most services actually sit. At 10K req/s across 64 threads the work is
    # negligible, so what is left in the CPU figure is the standing cost:
    # poll loops, timers, background GC, wakeups. A busy box amortises those
    # away; this one does not.
    [latency-10k]="1|0|0-31,64-95|1024|latency-10k"
    # Connections-5M: five million keep-alive connections held at once, with
    # the baseline GET paced at 1.25M req/s across them (GCANNON_RATE_CONNECTIONS_5M)
    # - one request per connection every four seconds. At that rate the work
    # per request is a fraction of what a fast server carries on this cpuset,
    # so what separates entries is what holding the rest of the fleet costs:
    # memory per connection, the CPU a request carries while the others wait,
    # and the tail once a heap, a timer wheel or a poll set is that large.
    # Measured on gcannon's window after the whole fleet is connected.
    #
    # One source address can open about 64.5K connections to one destination
    # (the async comment above), so gcannon spreads the fleet over the
    # loopback addresses 127.0.0.1 .. 127.0.0.160 (--addr-span), 31,250 on
    # each - the density the million-connection runs proved. An entry must
    # listen on 0.0.0.0 or [::] to subscribe; validate.sh checks it, and
    # scripts/conn_hold.py probes it before the run. Needs gcannon >= 0.8.2.
    # Opt-in and reference-only while the first field is measured.
    #
    # Not zrk: even 3.0.2 keeps ~41 KiB per connection, ~200 GiB for five
    # million. gcannon holds one in ~3.3 KiB.
    [connections-5m]="1|0|0-31,64-95|5000000|connections-5m"
    # connections-5m over TLS 1.3 on the h1 TLS port (8081), at a million
    # connections and 250K req/s - still one request per connection every four
    # seconds - over 127.0.0.1-.32: every connection handshakes once, then
    # carries its requests encrypted. gcannon hands each session to kernel TLS
    # after the handshake, so its side costs what a plaintext connection does
    # plus the kernel's record state; what the server keeps per TLS session is
    # the point. A million for now: five million over TLS was still connecting
    # 7.7 min into its first run. Needs gcannon >= 0.8.4, which paces the
    # handshakes to the server (MDA2AV/gcannon#33).
    [connections-1m-tls]="1|0|0-31,64-95|1000000|connections-1m-tls"
    # CON-1M: a million connections at 250K req/s with zrk 3.0.2 as the generator
    # (run next to gcannon, it found gcannon 0.8.0's --rate bursts, MDA2AV/gcannon#30).
    # Scored, like CON-1M-TLS (latency_score.HELD); CON-5M is reference-only and
    # runs only for the entries on scripts/connections-5m-allowlist.json.
    # zrk takes one URL, so tools/zrk.sh runs one process per loopback address
    # (scripts/zrk_fanout.py) and merges their histograms. It stays at a
    # million: zrk's ~41 KiB per connection rules out five.
    [connections-1m]="1|0|0-31,64-95|1000000|connections-1m"
    [json-comp]="1|0|0-31,64-95|4096,16384|json-compressed"
    [json-tls]="1|0|0-31,64-95|4096|json-tls"
    # 8Gbit: 100 KB up and the same 100 KB back, over TLS. The only profile
    # that loads both directions at once, which is why it exists - upload
    # measured ingest alone with 8 MB bodies and stopped discriminating (a 7%
    # spread across 99 entries, because it was measuring memcpy).
    #
    # 100 KB rather than more: in+out is 200 KB per request, so the box's
    # bandwidth ceiling still leaves per-request framework overhead visible.
    # It is also ~7 TLS records and more than one socket buffer, so partial
    # reads, multi-record handling and partial writes all get exercised.
    # Paced, not open-loop: zrk holds a fixed offered rate (ZRK_RATE_8GBIT)
    # over 512 held connections, so the question stops being "how fast can this
    # go" and becomes "what did it cost to serve exactly this much". An entry
    # that cannot hold the rate says so in rate_ratio rather than quietly
    # reporting a lower number that reads like a like-for-like result.
    [8gbit]="1|0|0-31,64-95|512|8gbit"
    [static-tls]="1|200|0-31,64-95|1024|static-tls"
    [async-db]="1|0|$DB_SERVER_CPUS|1024|async-db"
    [fortunes]="1|0|$DB_SERVER_CPUS|1024|fortunes"
    [baseline-h2]="1|0|0-31,64-95|256,1024|h2"
    [static-h2]="1|0|0-31,64-95|256,1024|static-h2"
    [baseline-h2c]="1|0|0-31,64-95|256,1024,4096|h2c"
    [json-h2c]="1|0|0-31,64-95|1024,4096|json-h2c"
    [baseline-h3]="1|0|0-31,64-95|64|h3"
    [static-h3]="1|0|0-31,64-95|64|static-h3"
    [unary-grpc]="1|0|0-31,64-95|256,1024|grpc"
    [unary-grpc-tls]="1|0|0-31,64-95|256,1024|grpc-tls"
    [gateway-64]="1|0|0-31,64-95|512,1024|gateway-64"
    [gateway-h3]="1|0|0-31,64-95|64,256|gateway-h3"
    [production-stack]="1|0|0-31,64-95|256,1024|production-stack"
    [echo-ws]="1|0|0-31,64-95|512,4096,16384|ws-echo"
    [echo-ws-pipeline]="16|0|0-31,64-95|512,4096,16384|ws-echo"
    [echo-ws-limited]="1|10|0-31,64-95|512,4096|ws-echo"
)

PROFILE_ORDER=(
    baseline pipelined limited-conn
    json-comp json-tls
    8gbit
    static-tls async-db
    fortunes
    baseline-h2 static-h2
    baseline-h2c json-h2c
    baseline-h3 static-h3
    gateway-64 gateway-h3
    production-stack
    unary-grpc unary-grpc-tls
    echo-ws echo-ws-pipeline echo-ws-limited
    latency-1m latency-10k
    # Last on purpose. It closes ~49K sockets at exit and every one sits in
    # TIME_WAIT for the kernel's fixed ~60s, so anything scheduled after it
    # starts against a nearly full port table.
    async
    # After even that, for the same reason a hundred times over: millions of
    # sockets closing at once, and millions of conntrack entries ageing out.
    connections-5m
    connections-1m-tls
    connections-1m
)

# The held-connection profiles. Everything the harness does around their load
# (host limits, the server's fd and memory caps, the window CPU, the held
# count) is the same for all three; only the generator and the scale differ.
held_conn_profile() {
    case "$1" in
        connections-5m|connections-1m-tls|connections-1m) return 0 ;;
    esac
    return 1
}

# ── Parsing + validation ────────────────────────────────────────────────────

# Parse a profile spec string into global fields. Exits on malformed input.
# Globals set: PROF_PIPELINE, PROF_REQ, PROF_CPU, PROF_CONNS, PROF_ENDPOINT
parse_profile() {
    local spec="$1"
    local n_pipes
    n_pipes=$(echo "$spec" | tr -cd '|' | wc -c)
    if [ "$n_pipes" -ne 4 ]; then
        fail "profile spec '$spec' must have exactly 4 '|' separators, got $n_pipes"
    fi
    IFS='|' read -r PROF_PIPELINE PROF_REQ PROF_CPU PROF_CONNS PROF_ENDPOINT <<< "$spec"
}

# Does every CPU the database split names exist on this box? On one that is too
# small, run_one() leaves the generator and Postgres where they are, the same way
# framework_start() falls back when a profile's cpuset does not fit.
db_split_fits() {
    local highest
    highest=$(grep -oE '[0-9]+' <<< "$DB_SERVER_CPUS,$DB_LOADGEN_CPUS,$DB_POSTGRES_CPUS" | sort -n | tail -1)
    [ "$highest" -lt "$(nproc 2>/dev/null || echo 1)" ]
}

# Map an endpoint to the tool name that handles it.
# Returns one of: gcannon, wrk, zrk, h2load, h2load-h3
endpoint_tool() {
    case "$1" in
        # wrk (lua script rotation)
        static-tls|json-tls)                 echo "wrk" ;;
        # zrk — the only paced generator; holds a fixed offered rate
        latency-1m|latency-10k|8gbit|connections-1m)  echo "zrk" ;;
        # h2load for all HTTP/2 variants (TLS via ALPN + h2c prior-knowledge)
        h2|static-h2|h2c|json-h2c|gateway-64|grpc|grpc-tls|production-stack)  echo "h2load" ;;
        # h2load built with ngtcp2 for HTTP/3
        h3|static-h3|gateway-h3)            echo "h2load-h3" ;;
        # gcannon for everything else (h1, async-db, async, ws, ...)
        *)                                  echo "gcannon" ;;
    esac
}

# Validate at startup that every PROFILE_ORDER entry has a PROFILES definition.
# Call this in benchmark.sh before the main loop.
validate_profiles() {
    local p ok=true
    for p in "${PROFILE_ORDER[@]}"; do
        if [ -z "${PROFILES[$p]+x}" ]; then
            echo "[profiles] MISSING definition: $p" >&2
            ok=false
        fi
    done
    $ok || fail "PROFILE_ORDER references profiles that aren't in PROFILES"
}
