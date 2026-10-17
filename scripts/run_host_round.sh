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
        echo "[$(date +%H:%M:%S)] $fw: benchmarking"
        timeout "$RUN_TIMEOUT" scripts/benchmark.sh "$fw" --save >>"$log" 2>&1
        rc=$?
        saved=$(grep -c "^\[info\] saved results/" "$log")
        failed=$(grep -c "did not come up" "$log")
        throttled=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
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
