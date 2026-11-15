#!/usr/bin/env bash
# scripts/resilience.sh — run the resilience attacks against an entry in a
# memory- and CPU-capped container and record whether it survives.
#
#   ./scripts/resilience.sh <framework> [--save] [attack ...]
#
# The entry runs in a fixed box (RES_MEM / RES_CPUSET, default 8g / 2 CPUs) so an
# attack that exhausts memory OOM-kills the container — a signal we can read —
# instead of taking the host down. Each attack gets a FRESH container (a crash in
# one must not cost another its verdict), reusing the normal entry launch path
# (framework_start) with the memory cap turned on.
#
# For each attack we record:
#   verdict        survived | degraded | hung | crashed | oom-killed
#   peak RSS       cgroup high-water during the attack, vs the idle baseline
#   liveness       a plaintext GET every second *during* the attack
#   recovery       seconds until the server serves again *after* the attack stops
# plus what the attack client itself did (scripts/resilience/attack.py).
#
# Scores land in results/resilience/<dir>.json (raw per-attack data next to it in
# results/resilience/<dir>/); --save also writes site/data/resilience/<dir>.json.
# <dir> is the entry directory, not the display name — same rule as spec/tls.
#
# The image is built unless RES_SKIP_BUILD=1 (a caller that just built it).
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/lib" && pwd)"
source "$SOURCE_DIR/common.sh"
source "$SOURCE_DIR/framework.sh"
source "$SOURCE_DIR/profiles.sh"
cd "$ROOT_DIR"

SAVE=false
POSITIONAL=()
ATTACKS_REQUESTED=()
for arg in "$@"; do
    case "$arg" in
        --save) SAVE=true ;;
        slow-body|slow-headers|huge-chunk|continuation-flood) ATTACKS_REQUESTED+=("$arg") ;;
        -*)     fail "unknown flag: $arg" ;;
        *)      POSITIONAL+=("$arg") ;;
    esac
done
[ -n "${POSITIONAL[0]:-}" ] || fail "usage: resilience.sh <framework> [--save] [attack ...]"

# ── Knobs (all env-overridable) ──────────────────────────────────────────────
RES_MEM="${RES_MEM:-8g}"             # the box the entry runs in
RES_CPUSET="${RES_CPUSET:-0-1}"      # 2 CPUs, pinned away from the attack client
RES_DURATION="${RES_DURATION:-60}"   # seconds per attack
RES_CONNS="${RES_CONNS:-4000}"       # connections the slow attacks hold (< the 28k ephemeral-port ceiling)
RES_BODY_SIZE="${RES_BODY_SIZE:-104857600}"  # 100 MiB declared body for slow-body (pre-alloc pressure)
RES_DRIP="${RES_DRIP:-1.0}"          # seconds between drips
RES_DRIP_BYTES="${RES_DRIP_BYTES:-256}"       # bytes per drip for slow-body/huge-chunk: ~256 B/s, slow
                                              # enough to be low-and-slow but above a bytes-at-zero reaper
RES_RECOVERY="${RES_RECOVERY:-15}"   # seconds to wait for the server to serve again
# The attack client runs on the load-generator cores so it never steals CPU from
# the (deliberately CPU-starved) server.
ATTACK_CPUS="${ATTACK_CPUS:-$GCANNON_CPUS}"
ATTACK_PY="$SCRIPT_DIR/resilience/attack.py"

# ── Entry ────────────────────────────────────────────────────────────────────
framework_load_meta "${POSITIONAL[0]}"
CONTAINER_NAME="httparena-resilience-${FRAMEWORK}"
trap 'framework_stop' EXIT

# Per-entry opt-in. An entry runs in the benchmark only when it sets
# "resilience": true in meta.json — the attacks are destructive and need the
# whole machine, so this is off by default. An explicit attack list on the CLI
# overrides the gate, for local debugging of an entry that has not opted in yet.
RES_OPT_IN=$(python3 -c "
import json, sys
print('1' if json.load(open(sys.argv[1])).get('resilience') else '0')" \
    "$ROOT_DIR/frameworks/$FRAMEWORK/meta.json" 2>/dev/null || echo 0)
if [ "${#ATTACKS_REQUESTED[@]}" -eq 0 ] && [ "$RES_OPT_IN" != "1" ]; then
    info "$FRAMEWORK has not opted into the resilience suite (set \"resilience\": true in meta.json, or name attacks on the CLI to force a run) — nothing to do"
    # An entry that opted back out takes its saved verdicts with it (mirror spec.sh).
    if $SAVE && [ -f "$ROOT_DIR/site/data/resilience/$FRAMEWORK.json" ]; then
        rm -f "$ROOT_DIR/site/data/resilience/$FRAMEWORK.json"
        info "removed site/data/resilience/$FRAMEWORK.json"
    fi
    exit 0
fi

if [ "${RES_SKIP_BUILD:-0}" = "1" ] && docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    info "RES_SKIP_BUILD=1 — reusing $IMAGE_NAME"
else
    framework_build
fi

WORK="$RESULTS_DIR/resilience/$FRAMEWORK"
rm -rf "$WORK"
mkdir -p "$WORK"

# ── Which attacks apply ──────────────────────────────────────────────────────
# The H1 attacks run against any entry. continuation-flood needs an HTTP/2
# listener, so it runs only when the entry subscribes to an h2/h2c profile.
has_h2() {
    framework_subscribes_to baseline-h2  || framework_subscribes_to static-h2 \
 || framework_subscribes_to baseline-h2c || framework_subscribes_to json-h2c
}
if [ "${#ATTACKS_REQUESTED[@]}" -gt 0 ]; then
    ATTACKS=("${ATTACKS_REQUESTED[@]}")
else
    ATTACKS=(slow-body slow-headers huge-chunk)
    has_h2 && ATTACKS+=(continuation-flood)
fi
info "attacks: ${ATTACKS[*]}"
info "box: mem=$RES_MEM cpuset=$RES_CPUSET  duration=${RES_DURATION}s conns=$RES_CONNS"

# ── Measurement helpers ──────────────────────────────────────────────────────

# Locate one of a container's cgroup files across cgroup drivers/versions.
_cgfile() {
    local id="$1" base="$2" f
    for f in "/sys/fs/cgroup/system.slice/docker-$id.scope/$base" \
             "/sys/fs/cgroup/docker/$id/$base" \
             "/sys/fs/cgroup/memory/docker/$id/$base"; do
        [ -r "$f" ] && { echo "$f"; return 0; }
    done
    f=$(find /sys/fs/cgroup -name "$base" -path "*$id*" 2>/dev/null | head -1)
    [ -n "$f" ] && [ -r "$f" ] && { echo "$f"; return 0; }
    return 1
}

# Current RSS in bytes (cgroup v2 memory.current, v1 memory.usage_in_bytes).
read_mem() {
    local id="$1" f
    f=$(_cgfile "$id" memory.current) || f=$(_cgfile "$id" memory.usage_in_bytes) || { echo 0; return; }
    cat "$f" 2>/dev/null || echo 0
}

# Kernel-maintained high-water RSS in bytes (cgroup v2 memory.peak, v1
# memory.max_usage_in_bytes). Reset per container, and we use a fresh container
# per attack, so this is the peak during this attack.
read_peak() {
    local id="$1" f
    f=$(_cgfile "$id" memory.peak) || f=$(_cgfile "$id" memory.max_usage_in_bytes) || { echo 0; return; }
    cat "$f" 2>/dev/null || echo 0
}

# Fallback sampler: on kernels without memory.peak, poll memory.current and keep
# the max in $1. Runs in the background during the attack.
sample_mem() {
    local id="$1" out="$2" f max=0 v
    f=$(_cgfile "$id" memory.current) || f=$(_cgfile "$id" memory.usage_in_bytes) || { echo 0 > "$out"; return; }
    echo 0 > "$out"
    while :; do
        v=$(cat "$f" 2>/dev/null || echo 0)
        [ "$v" -gt "$max" ] 2>/dev/null && { max=$v; echo "$max" > "$out"; }
        sleep 0.2
    done
}

# Seconds until a plaintext GET succeeds again, or "dead" after the budget.
recovery_probe() {
    local max="$1" start now i
    start=$(date +%s.%N)
    for ((i = 0; i < max * 2; i++)); do
        if curl -sk -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/baseline11?a=1&b=1" 2>/dev/null; then
            now=$(date +%s.%N)
            awk "BEGIN{printf \"%.1f\", $now - $start}"
            return
        fi
        sleep 0.5
    done
    echo dead
}

# ── One attack ───────────────────────────────────────────────────────────────

run_attack() {
    local name="$1" port path extra_tls=""
    case "$name" in
        slow-body)          port=$PORT;     path=/echo ;;
        slow-headers)       port=$PORT;     path=/ ;;
        huge-chunk)         port=$PORT;     path=/echo ;;
        continuation-flood) port=$H2C_PORT; path=/ ;;
        *) warn "unknown attack: $name"; return 0 ;;
    esac
    log "resilience $name: $FRAMEWORK (port $port)"

    FRAMEWORK_MEM_LIMIT="$RES_MEM" framework_start resilience "$RES_CPUSET"
    if ! framework_wait_ready baseline; then
        echo '{"verdict":"error","error":"server did not come up"}' > "$WORK/$name.result.json"
        dump_container_logs "$CONTAINER_NAME" "$FRAMEWORK" 2>/dev/null || true
        framework_stop
        return 0
    fi

    local cid baseline_mem peak_file live_file sampler_pid=""
    cid=$(docker inspect -f '{{.Id}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
    baseline_mem=$(read_mem "$cid")
    peak_file="$WORK/$name.peak"
    live_file="$WORK/$name.liveness"
    : > "$live_file"

    # Liveness: a cheap GET every second during the attack.
    (
        while :; do
            if curl -sk -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/baseline11?a=1&b=1" 2>/dev/null; then
                echo ok; else echo fail; fi
            sleep 1
        done
    ) >> "$live_file" 2>/dev/null &
    local live_pid=$!

    # memory.peak gives the true high-water for free; the sampler is the fallback
    # for kernels that lack it, and we take the max of the two.
    sample_mem "$cid" "$peak_file" &
    sampler_pid=$!

    # The attack itself. --tls only for the TLS-fronted H2 case (not used here).
    local tls_flag=()
    [ -n "$extra_tls" ] && tls_flag=(--tls)
    taskset -c "$ATTACK_CPUS" python3 "$ATTACK_PY" \
        --attack "$name" --host 127.0.0.1 --port "$port" --path "$path" \
        --conns "$RES_CONNS" --duration "$RES_DURATION" \
        --body-size "$RES_BODY_SIZE" --drip-interval "$RES_DRIP" \
        --drip-bytes "$RES_DRIP_BYTES" "${tls_flag[@]}" \
        > "$WORK/$name.client.json" 2> "$WORK/$name.client.log" || \
        warn "attack client exited non-zero (see $name.client.log)"

    kill "$live_pid" 2>/dev/null || true; wait "$live_pid" 2>/dev/null || true
    kill "$sampler_pid" 2>/dev/null || true; wait "$sampler_pid" 2>/dev/null || true

    # Server-side verdict inputs, captured before we tear the container down.
    local oom exitc running peak sampled
    oom=$(docker inspect -f '{{.State.OOMKilled}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)
    exitc=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
    running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false)
    peak=$(read_peak "$cid"); sampled=$(cat "$peak_file" 2>/dev/null || echo 0)
    [ "${sampled:-0}" -gt "${peak:-0}" ] 2>/dev/null && peak=$sampled

    local recovery="dead"
    if [ "$running" = "true" ]; then
        recovery=$(recovery_probe "$RES_RECOVERY")
    fi

    framework_stop

    # Hand the raw signal to the scorer as a JSON line; it classifies the verdict.
    # Note: `grep -c` prints 0 AND exits 1 on no match, so a `|| echo 0` inside
    # the $() would capture "0\n0" and break the int() below — exactly on the
    # all-failed (hung/crashed) case. Keep the fallback outside the substitution.
    local live_ok live_total
    live_ok=$(grep -c '^ok$' "$live_file" 2>/dev/null) || live_ok=0
    live_total=$(grep -c .   "$live_file" 2>/dev/null) || live_total=0
    python3 - "$WORK/$name.result.json" <<PY || warn "could not write the $name result record"
import json, sys
client = {}
try:
    client = json.load(open("$WORK/$name.client.json"))
except Exception:
    pass
json.dump({
    "attack": "$name", "port": $port,
    "oom_killed": "$oom" == "true",
    "exit_code": int("$exitc") if "$exitc".lstrip("-").isdigit() else None,
    "running": "$running" == "true",
    "baseline_mem": int("$baseline_mem" or 0),
    "peak_mem": int("$peak" or 0),
    "mem_limit": "$RES_MEM",
    "cpuset": "$RES_CPUSET",
    "duration_s": $RES_DURATION,
    "recovery": "$recovery",
    "liveness_ok": int("$live_ok" or 0),
    "liveness_total": int("$live_total" or 0),
    "client": client,
}, open(sys.argv[1], "w"))
PY
}

for attack in "${ATTACKS[@]}"; do
    run_attack "$attack"
done

# ── Scores ───────────────────────────────────────────────────────────────────
OUT="$RESULTS_DIR/resilience/$FRAMEWORK.json"
python3 "$SCRIPT_DIR/resilience_results.py" "$WORK" "$DISPLAY_NAME" "$FRAMEWORK" "${ATTACKS[@]}" > "$OUT"
info "wrote results/resilience/$FRAMEWORK.json"
if $SAVE; then
    mkdir -p "$ROOT_DIR/site/data/resilience"
    cp "$OUT" "$ROOT_DIR/site/data/resilience/$FRAMEWORK.json"
    info "saved site/data/resilience/$FRAMEWORK.json"
fi
