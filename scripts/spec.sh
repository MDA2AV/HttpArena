#!/usr/bin/env bash
# scripts/spec.sh — run the protocol-compliance suites an entry lists in
# "spec" (meta.json) and write their scores.
#
#   ./scripts/spec.sh <framework> [--save]
#
#   h1  Http11Probe against /spec on :8080 (built by docker/h1spec.Dockerfile)
#   h2  h2spec against /spec on :8443 (TLS) and/or :8082 (h2c)
#   h3  h3spec against the QUIC listener on :8443
#   ws  Autobahn's fuzzing client against /ws on :8080
#
# Each suite gets a fresh container, so a crash in one cannot cost another its
# score. The scores always land in results/spec/<dir>.json, next to the raw
# output in results/spec/<dir>/; --save also writes site/data/spec/<dir>.json,
# the file /benchmark --save and /spec --save commit.
#
# <dir> is the entry's directory, not its display name: several entries share
# one display name (actix, actix-h2c and actix-websocket are all "actix" on the
# board), and each has to own its file, the way site/data/tls/<dir>.json does.
#
# The image is built unless SPEC_SKIP_BUILD=1, which a caller that has just
# built it (a /benchmark run) sets. Contract, suites and file format:
# site/content/docs/test-profiles/compliance/.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/lib" && pwd)"
source "$SOURCE_DIR/common.sh"
source "$SOURCE_DIR/framework.sh"
source "$SOURCE_DIR/profiles.sh"
source "$SOURCE_DIR/spec.sh"
cd "$ROOT_DIR"

SAVE=false
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --save) SAVE=true ;;
        *)      POSITIONAL+=("$arg") ;;
    esac
done
[ -n "${POSITIONAL[0]:-}" ] || fail "usage: spec.sh <framework> [--save]"

# ── Tool pins ───────────────────────────────────────────────────────────────
# A changed pin rebuilds or re-pulls that tool: the local image tags hash their
# inputs, and the upstream images are referenced by digest. Every pin is also
# written into the scores, so a result always says what produced it.
H1SPEC_COMMIT="d50d818a0e008e9feb3bb9860ad5d9cc40342bc3"   # MDA2AV/Http11Probe
H2SPEC_VERSION="2.6.0"
H2SPEC_IMAGE="summerwind/h2spec:2.6.0@sha256:5f4a65c30cae8569558ced048b4bfe0dcf01a221e36767ae504ccd8348a7aeb0"
H3SPEC_VERSION="v0.1.15"
H3SPEC_SHA256="c3c5f497153f4ba81f82023791ba7f9a4bc46d4141211e614196f141c5996830"
AUTOBAHN_VERSION="25.10.1"
AUTOBAHN_IMAGE="crossbario/autobahn-testsuite:25.10.1@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074"
# Case 9 is throughput (messages up to 16 MB) and 12-13 are permessage-deflate,
# which no profile asks for. What is left is the protocol: framing, pings,
# fragmentation, UTF-8, reserved bits and opcodes, the close handshake.
AUTOBAHN_EXCLUDE='["9.*", "12.*", "13.*"]'
# h2spec's per-test wait. Its default of 2 s turns a slow answer into a failure.
H2SPEC_TIMEOUT=3

# The entry gets the benchmark's own cpuset and the tools the load generators',
# so a suite never competes with the server it is testing.
parse_profile "${PROFILES[baseline]}"
SPEC_ENTRY_CPUS="$PROF_CPU"
SPEC_TOOL_CPUS="${SPEC_TOOL_CPUS:-$GCANNON_CPUS}"
# Tool containers run as the caller, so what they write into results/ can be
# removed again by the runner that wrote it.
SPEC_USER="$(id -u):$(id -g)"

# ── Entry ───────────────────────────────────────────────────────────────────

framework_load_meta "${POSITIONAL[0]}"
CONTAINER_NAME="httparena-spec-${FRAMEWORK}"
trap 'framework_stop' EXIT

spec_load "$ROOT_DIR/frameworks/$FRAMEWORK/meta.json" \
    || fail "meta.json \"spec\" must be a list of compliance suites (known: $SPEC_KNOWN)"
if [ -z "$SPEC_SUITES" ]; then
    info "$FRAMEWORK lists no compliance suites in meta.json \"spec\" - nothing to run"
    # An entry that stopped listing suites takes its saved scores with it.
    if $SAVE && [ -f "$ROOT_DIR/site/data/spec/$FRAMEWORK.json" ]; then
        rm -f "$ROOT_DIR/site/data/spec/$FRAMEWORK.json"
        info "removed site/data/spec/$FRAMEWORK.json"
    fi
    exit 0
fi
if ! problems=$(spec_check "$FRAMEWORK_TESTS"); then
    fail "meta.json \"spec\" lists suite(s) that cannot run: $problems"
fi
info "compliance suites: $SPEC_SUITES"

if [ "${SPEC_SKIP_BUILD:-0}" = "1" ] && docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    info "SPEC_SKIP_BUILD=1 - reusing $IMAGE_NAME"
else
    framework_build
fi

WORK="$RESULTS_DIR/spec/$FRAMEWORK"
rm -rf "$WORK"
mkdir -p "$WORK"

# ── Helpers ─────────────────────────────────────────────────────────────────

# Build a tool image from docker/<file> unless one for exactly these inputs is
# already there. The tag hashes the Dockerfile and its build args.
spec_tool_image() {
    local name="$1" file="$2" tag a
    shift 2
    tag="httparena-spec-$name:$( { cat "$ROOT_DIR/docker/$file"; printf '%s\n' "$@"; } | sha256sum | cut -c1-12)"
    if ! docker image inspect "$tag" >/dev/null 2>&1; then
        info "building $tag from docker/$file" >&2
        local args=()
        for a in "$@"; do args+=(--build-arg "$a"); done
        docker build -q "${args[@]}" -t "$tag" -f "$ROOT_DIR/docker/$file" "$ROOT_DIR/docker" >&2 \
            || fail "$tag build failed"
    fi
    echo "$tag"
}

spec_tool() {
    docker run --rm --network host --cpuset-cpus="$SPEC_TOOL_CPUS" --user "$SPEC_USER" "$@"
}

# Start a fresh container and wait for the listener a suite needs. $1 is the
# suite, $2 the readiness probe's endpoint (framework_wait_ready's names).
spec_start() {
    framework_start spec "$SPEC_ENTRY_CPUS"
    if framework_wait_ready "$2"; then
        return 0
    fi
    echo "error: the server did not come up for the $1 suite" > "$WORK/$1.status"
    dump_container_logs "$CONTAINER_NAME" 2>/dev/null || true
    framework_stop
    return 1
}

# A suite that left the server dead is recorded as a crash: the tests it could
# no longer answer count as failed, and the score says why.
spec_finish() {
    if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]; then
        echo ok > "$WORK/$1.status"
    else
        echo crashed > "$WORK/$1.status"
        warn "$FRAMEWORK stopped running during the $1 suite"
        FAIL_LOG_TAIL=40 dump_container_logs "$CONTAINER_NAME" "$FRAMEWORK"
    fi
    framework_stop
}

# ── Suites ──────────────────────────────────────────────────────────────────

spec_run_h1() {
    local img
    img=$(spec_tool_image h1 h1spec.Dockerfile "PROBE_COMMIT=$H1SPEC_COMMIT")
    spec_start h1 baseline || return 0
    spec_tool -v "$WORK:/out" "$img" --host 127.0.0.1 --port "$PORT" --output /out/h1.json \
        > "$WORK/h1.log" 2>&1 || true
    spec_finish h1
}

spec_run_h2() {
    local first=true
    if framework_subscribes_to baseline-h2 || framework_subscribes_to static-h2; then
        spec_start h2 h2 || return 0
        first=false
        spec_tool -v "$WORK:/out" "$H2SPEC_IMAGE" -h 127.0.0.1 -p "$H2PORT" -t -k \
            -P /spec -o "$H2SPEC_TIMEOUT" -j /out/h2-tls.xml > "$WORK/h2-tls.log" 2>&1 || true
    fi
    if framework_subscribes_to baseline-h2c || framework_subscribes_to json-h2c; then
        if $first; then
            spec_start h2 h2c || return 0
        fi
        spec_tool -v "$WORK:/out" "$H2SPEC_IMAGE" -h 127.0.0.1 -p "$H2C_PORT" \
            -P /spec -o "$H2SPEC_TIMEOUT" -j /out/h2-h2c.xml > "$WORK/h2-h2c.log" 2>&1 || true
    fi
    spec_finish h2
}

spec_run_h3() {
    local img
    img=$(spec_tool_image h3 h3spec.Dockerfile "H3SPEC_VERSION=$H3SPEC_VERSION" "H3SPEC_SHA256=$H3SPEC_SHA256")
    # curl here cannot speak QUIC, so readiness is the TCP listener on the same
    # port, which is what the benchmark waits on for the h3 profiles as well.
    spec_start h3 h3 || return 0
    sleep 1
    spec_tool "$img" 127.0.0.1 "$H2PORT" -n > "$WORK/h3.txt" 2>&1 || true
    spec_finish h3
}

spec_run_ws() {
    mkdir -p "$WORK/ws/config" "$WORK/ws/reports"
    cat > "$WORK/ws/config/fuzzingclient.json" <<EOF
{"outdir": "/reports", "servers": [{"agent": "entry", "url": "ws://127.0.0.1:$PORT/ws"}],
 "cases": ["*"], "exclude-cases": $AUTOBAHN_EXCLUDE, "exclude-agent-cases": {}}
EOF
    spec_start ws ws-echo || return 0
    spec_tool -v "$WORK/ws/config:/config:ro" -v "$WORK/ws/reports:/reports" "$AUTOBAHN_IMAGE" \
        wstest -m fuzzingclient -s /config/fuzzingclient.json > "$WORK/ws.log" 2>&1 || true
    spec_finish ws
}

for suite in $SPEC_SUITES; do
    log "spec $suite: $FRAMEWORK"
    "spec_run_$suite"
done

# ── Scores ──────────────────────────────────────────────────────────────────

OUT="$RESULTS_DIR/spec/$FRAMEWORK.json"
SPEC_VERSION_H1="${H1SPEC_COMMIT:0:7}" SPEC_VERSION_H2="$H2SPEC_VERSION" \
SPEC_VERSION_H3="$H3SPEC_VERSION" SPEC_VERSION_WS="$AUTOBAHN_VERSION" \
    python3 "$SCRIPT_DIR/spec_results.py" "$WORK" "$DISPLAY_NAME" "$FRAMEWORK" $SPEC_SUITES > "$OUT"
info "wrote results/spec/$FRAMEWORK.json"
if $SAVE; then
    mkdir -p "$ROOT_DIR/site/data/spec"
    cp "$OUT" "$ROOT_DIR/site/data/spec/$FRAMEWORK.json"
    info "saved site/data/spec/$FRAMEWORK.json"
fi
