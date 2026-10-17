#!/usr/bin/env bash
# run_host_round.sh — benchmark every enabled framework under a host profile,
# one after another, resumable.
#
#   HOST_PROFILE=rpi scripts/run_host_round.sh [framework ...]
#
# Each framework is built first under BUILD_TIMEOUT (a Rust or Java build on a
# small arm64 board can take very long, and one that does not finish is skipped
# rather than holding the round up), then benchmarked with benchmark.sh --save.
# The outcome goes to results-hosts/<host>/_status.tsv; a framework listed there
# is not run again, so the script can be stopped and restarted at any time.
# Delete its line to retry one.
#
# Images are removed after each framework so the disk does not fill up.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

HOST_PROFILE="${HOST_PROFILE:?set HOST_PROFILE, e.g. HOST_PROFILE=rpi}"
export HOST_PROFILE
BUILD_TIMEOUT="${BUILD_TIMEOUT:-45m}"
RUN_TIMEOUT="${RUN_TIMEOUT:-90m}"
# Before each benchmark, wait for the board to cool below COOL_BELOW_C (at most
# COOL_MAX_S seconds), so every framework starts from the same temperature
# rather than from whatever the previous one left behind. Needs vcgencmd.
COOL_BELOW_C="${COOL_BELOW_C:-60}"
COOL_MAX_S="${COOL_MAX_S:-600}"

cool_down() {
    command -v vcgencmd >/dev/null 2>&1 || return 0
    local waited=0 t
    while :; do
        t=$(vcgencmd measure_temp | tr -dc '0-9.')
        [ "${t%.*}" -lt "$COOL_BELOW_C" ] && break
        [ "$waited" -ge "$COOL_MAX_S" ] && { echo "[warn] still ${t}C after ${COOL_MAX_S}s"; break; }
        sleep 10; waited=$((waited + 10))
    done
    [ "$waited" -gt 0 ] && echo "[$(date +%H:%M:%S)] cooled to ${t}C in ${waited}s"
    return 0
}

OUT="$ROOT_DIR/results-hosts/$HOST_PROFILE"
STATUS="$OUT/_status.tsv"
LOGS="$OUT/_runs"
mkdir -p "$LOGS"
touch "$STATUS"

# Profiles the host runs, read from its profile file.
mapfile -t HOST_PROFILES < <(bash -c '
    declare -A PROFILES; ROOT_DIR='"$ROOT_DIR"'
    source scripts/lib/hosts/'"$HOST_PROFILE"'.sh >/dev/null 2>&1
    printf "%s\n" "${PROFILE_ORDER[@]}"')

# Enabled frameworks that subscribe to at least one of them.
candidates() {
    python3 - "${HOST_PROFILES[@]}" <<'EOF'
import glob, json, sys
host = set(sys.argv[1:])
for m in sorted(glob.glob("frameworks/*/meta.json")):
    d = json.load(open(m))
    if d.get("enabled", True) is False:
        continue
    if set(d.get("tests", [])) & host:
        print(m.split("/")[1])
EOF
}

if [ $# -gt 0 ]; then FWS=("$@"); else mapfile -t FWS < <(candidates); fi

build() {
    local fw="$1"
    if [ -x "frameworks/$fw/build.sh" ]; then
        timeout "$BUILD_TIMEOUT" "frameworks/$fw/build.sh"
    else
        timeout "$BUILD_TIMEOUT" docker build -t "httparena-$fw" "frameworks/$fw"
    fi
}

for fw in "${FWS[@]}"; do
    if cut -f1 "$STATUS" | grep -qxF "$fw"; then continue; fi
    log="$LOGS/$fw.log"
    start=$(date +%s)
    echo "[$(date +%H:%M:%S)] $fw: building"
    build "$fw" >"$log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        reason="build failed"; [ "$rc" -eq 124 ] && reason="build timeout ($BUILD_TIMEOUT)"
        printf '%s\t%s\t%s\t%s\n' "$fw" "skip" "$reason" "$(( $(date +%s) - start ))s" >>"$STATUS"
        echo "[$(date +%H:%M:%S)] $fw: $reason"
    else
        cool_down
        echo "[$(date +%H:%M:%S)] $fw: benchmarking"
        # Sample the board's live throttle bits and temperature for the whole
        # run (the "has occurred" bits are sticky until reboot, so one reading
        # at the end says nothing about this framework).
        thermal="$LOGS/$fw.thermal"
        : >"$thermal"
        if command -v vcgencmd >/dev/null 2>&1; then
            ( while sleep 2; do
                  printf '%s %s\n' "$(vcgencmd get_throttled | cut -d= -f2)" \
                      "$(vcgencmd measure_temp | tr -dc '0-9.')"
              done ) >>"$thermal" &
            sampler=$!
        fi
        timeout "$RUN_TIMEOUT" scripts/benchmark.sh "$fw" --save >>"$log" 2>&1
        rc=$?
        [ -n "${sampler:-}" ] && kill "$sampler" 2>/dev/null; sampler=""
        saved=$(grep -c "^\[info\] saved results/" "$log")
        failed=$(grep -c "did not come up" "$log")
        # Live bits 0x2 (capped), 0x4 (throttled), 0x8 (soft temp limit).
        throttled=$(python3 -c '
import sys
t, m = False, 0.0
for line in open(sys.argv[1]):
    p = line.split()
    if len(p) == 2:
        t |= bool(int(p[0], 16) & 0xe)
        m = max(m, float(p[1] or 0))
print(("YES" if t else "no") + "/max%.0fC" % m)' "$thermal" 2>/dev/null)
        state="ok"; [ "$saved" -eq 0 ] && state="skip"
        printf '%s\t%s\t%s\t%s\n' "$fw" "$state" \
            "rc=$rc saved=$saved not_ready=$failed throttled=${throttled:-n/a}" \
            "$(( $(date +%s) - start ))s" >>"$STATUS"
        echo "[$(date +%H:%M:%S)] $fw: $state (saved $saved, not ready $failed)"
    fi
    docker rm -f "httparena-bench-$fw" >/dev/null 2>&1
    docker rmi -f "httparena-$fw" >/dev/null 2>&1
    # Keep the build cache unless the disk runs low; base images are shared.
    if [ "$(df --output=avail -BG / | tail -1 | tr -dc 0-9)" -lt 30 ]; then
        docker builder prune -af >/dev/null 2>&1
        docker image prune -f >/dev/null 2>&1
    fi
done
