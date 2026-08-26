# scripts/lib/tools/zrk.sh — zrk (constant-throughput) dispatch + parse.
#
# zrk is the only generator here that paces. gcannon, wrk and h2load all answer
# "how fast can this go"; zrk answers "hold exactly this rate", which is what
# the latency-1m profile needs — with the rate pinned, the only thing left to
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
        printf '%s\n' docker run --rm --network host \
            --cpuset-cpus="$GCANNON_CPUS" --security-opt seccomp=unconfined \
            --ulimit memlock=-1:-1 --ulimit nofile=1048576:1048576 "$ZRK_IMAGE"
        return 0
    fi
    fail "zrk not found: '$ZRK' is not on PATH and image '$ZRK_IMAGE' does not exist.
      Build it with: docker build -t $ZRK_IMAGE -f docker/zrk.Dockerfile docker/"
}

# The rate the latency-1m profile holds, in requests/second. It lives here
# rather than in the profile spec because the spec's five fields are shaped for
# closed-loop tools and have no slot for an offered rate — and because changing
# it re-baselines every published number on the profile, so it should be a
# visible edit rather than a digit inside a pipe-delimited string.
ZRK_FIXED_RATE="${ZRK_FIXED_RATE:-1000000}"

# ── Build arguments ─────────────────────────────────────────────────────────

zrk_build_args() {
    local endpoint="$1" conns="$2" pipeline="$3" duration="$4"
    local -a cmd
    mapfile -t cmd < <(_zrk_cmd)

    case "$endpoint" in
        latency-1m)
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
            cmd+=(-t "$THREADS" -c "$conns" -d 20s -R "$ZRK_FIXED_RATE"
                  --format json --plain
                  "http://localhost:$PORT/baseline11?a=1&b=2")
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
    if [ -n "$ZRK_CMD" ]; then
        timeout 60 "$@" || true
    else
        timeout 60 taskset -c "$GCANNON_CPUS" "$@" || true
    fi
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
print("p99_lat=%.1fus" % (lat.get("p99") or 0))
# p99.9 is not a field any other adapter produces, and the latency-1m
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
PY
}
