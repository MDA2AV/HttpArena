# scripts/lib/tools/zrk.sh — zrk (constant-throughput) dispatch + parse.
#
# zrk is the only generator here that paces. gcannon, wrk and h2load all answer
# "how fast can this go"; zrk answers "hold exactly this rate", which is what
# the fixed-rate profiles need — with the rate pinned, the only thing left to
# vary between entries is what it cost them.
#
# It is also the only one that emits a machine-readable summary, so this
# adapter parses `--format json` rather than scraping a report.

: "${ZRK_CMD:=}"

# Resolve how to invoke zrk, and refuse rather than guess.
#
# The other adapters can fall through to a bare binary name because the bench
# host has all of theirs on PATH. zrk's is not installed anywhere, so a silent
# fall-through produces "command not found", an empty summary, and a row of
# zeros that is indistinguishable from a server that served nothing. Failing
# here instead aborts the run with the actual reason -- which is the right
# outcome, because a missing generator fails every entry identically and there
# is nothing to be learned by measuring the other 102 the same way.
_zrk_cmd() {
    if [ -n "$ZRK_CMD" ]; then
        printf '%s\n' $ZRK_CMD
        return 0
    fi
    if command -v "$ZRK" >/dev/null 2>&1; then
        printf '%s\n' "$ZRK"
        return 0
    fi
    if docker image inspect "$ZRK_IMAGE" >/dev/null 2>&1; then
        printf '%s\n' docker run --rm --init --network host \
            --cpuset-cpus="$GCANNON_CPUS" --security-opt seccomp=unconfined \
            --ulimit memlock=-1:-1 --ulimit nofile=1048576:1048576 \
            -v "$REQUESTS_DIR:$REQUESTS_DIR:ro" "$ZRK_IMAGE"
        return 0
    fi
    fail "zrk not found: '$ZRK' is not on PATH and image '$ZRK_IMAGE' does not exist.
      Build it with: docker build -t $ZRK_IMAGE -f docker/zrk.Dockerfile docker/"
}

# The rate each fixed-rate profile holds, in requests/second. They live here
# rather than in the profile spec because the spec's five fields are shaped for
# closed-loop tools and have no slot for an offered rate — and because changing
# it re-baselines every published number on the profile, so it should be a
# visible edit rather than a digit inside a pipe-delimited string.
ZRK_RATE_LATENCY_1M="${ZRK_RATE_LATENCY_1M:-1000000}"
ZRK_RATE_LATENCY_10K="${ZRK_RATE_LATENCY_10K:-10000}"
ZRK_RATE_8GBIT="${ZRK_RATE_8GBIT:-50000}"

# connections-1m: a million held connections at 250K req/s, one request per
# connection every four seconds, with zrk as the load generator. Run next to
# gcannon at the same scale (tools/gcannon.sh), it caught gcannon 0.8.0's
# --rate bursts (MDA2AV/gcannon#30).
#
# Its own zrk, 3.0.2, while the profiles above stay on the pinned 2.3.0 (a bump
# re-baselines them). 2.3.0 kept ~303 KiB per connection and took the bench
# host down at a million; 3.0.2 keeps ~41 KiB (measured at 4K and 16K). The
# image is docker/zrk.Dockerfile built with this version and checksum.
ZRK_RATE_CONNECTIONS_1M="${ZRK_RATE_CONNECTIONS_1M:-250000}"
ZRK_CONN1M_VERSION="${ZRK_CONN1M_VERSION:-3.0.2}"
ZRK_CONN1M_SHA256="${ZRK_CONN1M_SHA256:-339ade3ba435f14ea3c15ab8e97a880d931e14604857cde01aea1797e7430cbf}"
ZRK_CONN1M_IMAGE="${ZRK_CONN1M_IMAGE:-zrk:$ZRK_CONN1M_VERSION}"
: "${ZRK_CONN1M_CMD:=}"

# How the fleet is spread (scripts/zrk_fanout.py has the why). zrk takes one
# URL, so one process per loopback address 127.0.0.1..127.0.0.ZRK_FANOUT_ADDRS,
# 31,250 connections and 2 threads each (64 in all, like gcannon's -t). Each
# opens all of its connections the moment it starts, so processes start
# STAGGER seconds apart, SETTLE seconds after the last start are discarded,
# WINDOW seconds are measured, and TAIL seconds keep the fleet up while the
# open connections are counted (ss walking a million sockets; a count that
# outlasts the tail would see zrk's own closes).
ZRK_FANOUT_ADDRS="${ZRK_FANOUT_ADDRS:-32}"
ZRK_FANOUT_STAGGER="${ZRK_FANOUT_STAGGER:-1}"
ZRK_FANOUT_SETTLE="${ZRK_FANOUT_SETTLE:-10}"
ZRK_FANOUT_WINDOW="${ZRK_FANOUT_WINDOW:-20}"
ZRK_FANOUT_TAIL="${ZRK_FANOUT_TAIL:-20}"
# The fan-out refuses a run the host cannot hold at this much per connection
# and caps each zrk container at half again over it, so an overrun is
# OOM-killed in its own cgroup instead of taking the bench host down.
ZRK_KIB_PER_CONN="${ZRK_KIB_PER_CONN:-48}"

# The zrk connections-1m runs: ZRK_CONN1M_CMD when set (benchmark.sh sets
# it at startup), else a zrk on PATH if it is new enough. Printed one word per
# line; the fan-out asks it for --version and refuses anything older.
_zrk_conn1m_cmd() {
    if [ -n "$ZRK_CONN1M_CMD" ]; then
        printf '%s\n' $ZRK_CONN1M_CMD
    elif _zrk_at_least "$ZRK" "$ZRK_CONN1M_VERSION"; then
        printf '%s\n' "$ZRK"
    else
        printf '%s\n' docker run --rm --network host \
            --cpuset-cpus="$GCANNON_CPUS" --security-opt seccomp=unconfined \
            --ulimit memlock=-1:-1 --ulimit nofile=1048576:1048576 "$ZRK_CONN1M_IMAGE"
    fi
}

# True when binary $1 is on PATH and reports a version >= $2.
_zrk_at_least() {
    command -v "$1" >/dev/null 2>&1 || return 1
    local have
    have=$("$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$have" ] || return 1
    [ "$(printf '%s\n%s\n' "$2" "$have" | sort -V | head -1)" = "$2" ]
}

# The body zrk posts to /echo. zrk takes a single body (-b @FILE), so unlike the
# wrk script this profile used to run there is no eight-way rotation making a
# canned response wrong seven times out of eight. The anti-cheat therefore rests
# entirely on validation, which posts RANDOM bodies and compares byte for byte:
# a server answering from a cache, or sizing a reply from Content-Length without
# reading, fails there. Keep the size in step with benchmark.sh's input_bw.
ZRK_ECHO_BODY_BYTES="${ZRK_ECHO_BODY_BYTES:-10240}"
ZRK_ECHO_BODY_FILE="${ZRK_ECHO_BODY_FILE:-$REQUESTS_DIR/.echo-body.bin}"

# Written on the host before the container starts (REQUESTS_DIR is mounted into
# it read-only). Deterministic, so a run is reproducible and no two entries are
# ever measured against different bytes.
_zrk_echo_body() {
    local have=0
    [ -s "$ZRK_ECHO_BODY_FILE" ] && have=$(stat -c%s "$ZRK_ECHO_BODY_FILE" 2>/dev/null || echo 0)
    if [ "$have" != "$ZRK_ECHO_BODY_BYTES" ]; then
        python3 -c "
import sys
n = $ZRK_ECHO_BODY_BYTES
unit = b'echo-body:'
sys.stdout.buffer.write((unit * (n // len(unit) + 1))[:n])
" > "$ZRK_ECHO_BODY_FILE" || fail "could not write the zrk echo body fixture"
    fi
}

# ── Build arguments ─────────────────────────────────────────────────────────

zrk_build_args() {
    local endpoint="$1" conns="$2" pipeline="$3" duration="$4"
    local -a cmd

    # The baseline GET over plaintext, as on connections-5m. One zrk cannot
    # hold a million connections to one address, so zrk_run fans this out;
    # the sentinel carries what it needs ahead of the zrk command itself.
    # Handled before _zrk_cmd: this profile runs 3.0.2, not the pinned zrk.
    if [ "$endpoint" = "connections-1m" ]; then
        mapfile -t cmd < <(_zrk_conn1m_cmd)
        printf '%s\n' --fanout-- "$conns" "$ZRK_RATE_CONNECTIONS_1M" "/baseline11?a=1&b=2" \
            -- "${cmd[@]}"
        return 0
    fi

    mapfile -t cmd < <(_zrk_cmd)

    case "$endpoint" in
        latency-1m|latency-10k)
            # Same GET the baseline profile is validated on, so nothing new has
            # to be implemented to subscribe and the handler is as thin as the
            # framework allows -- what is left in the CPU number is the
            # framework's own overhead rather than the workload's.
            #
            # Every thread the box will give it, like every other adapter.
            # Generator threads cannot contaminate the measurement: they run on
            # GCANNON_CPUS, a cpuset disjoint from the server's, and the metric
            # is read out of the server container's own cgroup -- so a spinning
            # generator shows up in nobody's number. What thread count does buy
            # is schedule fidelity: at 1M req/s, -t 16 held rate_ratio 0.9934
            # with 93ms of peak schedule lag against -t 24's 0.9955 and 46ms.
            local _rate="$ZRK_RATE_LATENCY_1M"
            [ "$endpoint" = "latency-10k" ] && _rate="$ZRK_RATE_LATENCY_10K"
            cmd+=(-t "$THREADS" -c "$conns" -d 20s -R "$_rate"
                  --format json --plain
                  "http://localhost:$PORT/baseline11?a=1&b=2")
            ;;
        8gbit)
            # POST the body over TLS and take the same bytes back, so one
            # request loads both directions. -k because the bench certs are
            # self-signed. Paced rather than open-loop: what varies between
            # entries is the cost of serving the rate, not the rate itself.
            _zrk_echo_body
            cmd+=(-t "$THREADS" -c "$conns" -d "$duration" -R "$ZRK_RATE_8GBIT"
                  -m POST -b "@$ZRK_ECHO_BODY_FILE"
                  -H "Content-Type: application/octet-stream"
                  -k --format json --plain
                  "https://localhost:$H1TLS_PORT/echo")
            ;;
        *)
            fail "zrk_build_args: unknown endpoint '$endpoint'"
            ;;
    esac

    printf '%s\n' "${cmd[@]}"
}

# stdout is the JSON summary and is captured by the caller; stderr is left
# attached to the console on purpose. It used to go to /dev/null to keep the
# dashboard out of the log -- but --format json already suppresses the
# dashboard, so all that redirect ever hid was the reason a run failed.
zrk_run() {
    if [ "${1:-}" = "--fanout--" ]; then
        _zrk_fanout_run "${@:2}"
        return 0
    fi
    if [ -n "$ZRK_CMD" ]; then
        timeout 60 "$@" || true
    else
        timeout 60 taskset -c "$GCANNON_CPUS" "$@" || true
    fi
}

# connections-1m: one zrk per loopback address, merged into one summary
# shaped like zrk's own (scripts/zrk_fanout.py). Its stdout is that summary, so
# the caller captures and parses it exactly as it would a single zrk's.
#
# The server cgroup's CPU is read by the fan-out at the edges of the measured
# window and reported as server_cpu_usec; benchmark.sh's own reading spans the
# whole run, a million connects included, so the window figure replaces it.
_zrk_fanout_run() {
    local conns="$1" rate="$2" path="$3"
    shift 3
    [ "${1:-}" = "--" ] && shift
    local -a prefix=("$@")
    # docker pins through --cpuset-cpus; a native zrk needs taskset.
    [ "$(basename "${prefix[0]}")" = "docker" ] || prefix=(taskset -c "$GCANNON_CPUS" "${prefix[@]}")
    local cpu_stat=""
    if [ -n "${CONTAINER_NAME:-}" ]; then
        cpu_stat=$(_cgroup_cpu_path "$CONTAINER_NAME" 2>/dev/null) || cpu_stat=""
    fi
    local addrs="$ZRK_FANOUT_ADDRS" nofile mem
    read -r nofile mem <<< "$(held_conn_limits connections-1m)"
    local total=$(( (addrs - 1) * ZRK_FANOUT_STAGGER + ZRK_FANOUT_SETTLE \
                    + ZRK_FANOUT_WINDOW + ZRK_FANOUT_TAIL ))
    timeout $(( total + 300 )) python3 "$SCRIPT_DIR/zrk_fanout.py" \
        --conns "$conns" --rate "$rate" --addrs "$addrs" \
        --port "$PORT" --path "$path" --threads "$THREADS" \
        --stagger "$ZRK_FANOUT_STAGGER" --settle "$ZRK_FANOUT_SETTLE" \
        --window "$ZRK_FANOUT_WINDOW" --tail "$ZRK_FANOUT_TAIL" \
        ${cpu_stat:+--cpu-stat "$cpu_stat"} --ss-cpus "$GCANNON_CPUS" \
        --kib-per-conn "$ZRK_KIB_PER_CONN" --server-mem "${FRAMEWORK_MEM_LIMIT:-$mem}" \
        --min-version "$ZRK_CONN1M_VERSION" \
        -- "${prefix[@]}" || true
}

# ── Parse output ────────────────────────────────────────────────────────────

# zrk writes the JSON summary to stdout under --format json. stderr carries the
# dashboard/progress, which zrk_run drops -- so `output` is the object alone.
zrk_parse() {
    local output="$2"

    python3 - "$output" <<'PY'
import json, sys

raw = sys.argv[1]
# Be tolerant of anything zrk may print around the object: take the outermost
# {...} rather than assuming the whole stream is the summary.
start, end = raw.find("{"), raw.rfind("}")
if start < 0 or end <= start:
    # No summary at all. Say so on stderr rather than only emitting zeros,
    # which downstream cannot tell apart from a server that served nothing.
    sys.stderr.write("[zrk] no JSON summary in output — the generator did not "
                     "run, or died before reporting. Raw output was:\n%s\n"
                     % (raw[:2000] or "<empty>"))
    for k in ("rps=0", "avg_lat=", "p99_lat=", "reconnects=0", "bandwidth=0",
              "status_2xx=0", "status_3xx=0", "status_4xx=0", "status_5xx=0",
              "rate_ratio=0"):
        print(k)
    sys.exit(0)

d = json.loads(raw[start:end + 1])
lat = d.get("latency_us") or {}
codes = d.get("status_codes") or {}

print("rps=%d" % round(d.get("achieved_rate") or 0))
# lat() on the board reads us/ms/s, so hand it microseconds unconverted.
print("avg_lat=%.1fus" % (lat.get("mean") or 0))
# The median, which the held-connection profiles score (latency_score.HELD).
print("p50_lat=%.1fus" % (lat.get("p50") or 0))
print("p99_lat=%.1fus" % (lat.get("p99") or 0))
# p99.9 is not a field any other adapter produces, and the fixed-rate
# score weights it, so it has to survive into the result row rather than
# only existing in this summary.
print("p999_lat=%.1fus" % (lat.get("p99_9") or 0))
# Nothing reconnects on a paced run over held connections; report the real
# connect failures instead of a zero that hides them.
print("reconnects=%d" % ((d.get("errors") or {}).get("connect") or 0))
print("bandwidth=%.2fMB/s" % ((d.get("bytes_per_sec") or 0) / 1e6))
for k in ("1xx", "2xx", "3xx", "4xx", "5xx"):
    if k != "1xx":
        print("status_%s=%d" % (k, codes.get(k) or 0))

# The validity gate for a fixed-rate run. If the client could not hold the
# schedule the offered load was not what the profile says it was, and the CPU
# number is not comparable with anyone else's. Carried through to the result
# row so the reason is visible rather than inferred from a low rps.
print("rate_ratio=%.4f" % (d.get("rate_ratio") or 0))
# The adapters that hardcode their own -d have always let the result row
# inherit the global DURATION, which is wrong for all of them. It matters
# here because cpu_usec is only readable against the window it was taken
# over, so this one reports the duration it actually ran.
print("duration=%.0fs" % (d.get("duration_s") or 0))
print("target_rate=%d" % (d.get("target_rate") or 0))
print("max_schedule_lag_us=%d" % (d.get("max_schedule_lag_us") or 0))

# connections-1m's fan-out adds these (scripts/zrk_fanout.py), under the
# keys gcannon's held-connection parser emits, so benchmark.sh reads both the
# same way. A single zrk summary has none of them.
if "fanout" in d or d.get("hold_error"):
    for k in ("launched", "connections_open", "ramp_connect_errors"):
        if d.get(k) is not None:
            print("%s=%d" % (k, d[k]))
    print("connect_errors=%d" % ((d.get("errors") or {}).get("connect") or 0))
if d.get("server_cpu_usec") is not None:
    print("cpu_usec_window=%d" % d["server_cpu_usec"])
if d.get("hold_error"):
    print("hold_error=%s" % " ".join(str(d["hold_error"]).split()))
PY
}
