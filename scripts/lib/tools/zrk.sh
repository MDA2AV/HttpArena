# scripts/lib/tools/zrk.sh — zrk (constant-throughput) dispatch + parse.
#
# zrk is the only generator here that paces. gcannon, wrk and h2load all answer
# "how fast can this go"; zrk answers "hold exactly this rate", which is what
# the millionaire profile needs — with the rate pinned, the only thing left to
# vary between entries is what it cost them.
#
# It is also the only one that emits a machine-readable summary, so this
# adapter parses `--format json` rather than scraping a report.

: "${ZRK_CMD:=}"

_zrk_cmd() {
    if [ -n "$ZRK_CMD" ]; then
        printf '%s\n' $ZRK_CMD
    else
        printf '%s\n' "$ZRK"
    fi
}

# The rate the millionaire profile holds, in requests/second. It lives here
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
        millionaire)
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

zrk_run() {
    if [ -n "$ZRK_CMD" ]; then
        timeout 60 "$@" 2>/dev/null || true
    else
        timeout 60 taskset -c "$GCANNON_CPUS" "$@" 2>/dev/null || true
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
