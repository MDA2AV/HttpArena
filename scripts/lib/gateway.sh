# scripts/lib/gateway.sh — multi-container compose stack lifecycle.
#
# Profiles that use a compose-orchestrated stack (instead of the single
# framework container used by isolated profiles) route through this module:
#
#   gateway-64       — h2/TLS at the edge. 2 containers: proxy + server.
#                      Compose file: compose.gateway.yml (legacy name).
#   gateway-h3       — h3/QUIC at the edge. 2 containers: proxy + server.
#                      Compose file: compose.gateway-h3.yml
#   production-stack — h2/TLS at the edge + auth sidecar + cache. 4
#                      containers: edge + authsvc + cache + server.
#                      Compose file: compose.production-stack.yml
#
# All gateway_* functions take the profile name as their second argument
# so we resolve the right compose file + expected container count per
# profile. The module name is "gateway" for historical reasons — it now
# covers all multi-container stacks.

GATEWAY_PROJECT=""
GATEWAY_ACTIVE_PROFILE=""
GATEWAY_ACTIVE_FRAMEWORK=""
GATEWAY_CONTAINERS=""
GATEWAY_CONTAINER_COUNT=0

_gateway_env() {
    # All compose invocations need the same env vars for interpolation.
    CERTS_DIR="$CERTS_DIR" \
    DATA_DIR="$DATA_DIR" \
    DATABASE_URL="$DATABASE_URL" \
    "$@"
}

# Resolve <framework>/<profile> → absolute compose file path. gateway-64
# keeps its legacy `compose.gateway.yml` name; everything else uses
# `compose.<profile>.yml`.
_gateway_compose_file() {
    local framework="$1"
    local profile="$2"
    case "$profile" in
        gateway-64) echo "$ROOT_DIR/frameworks/$framework/compose.gateway.yml" ;;
        *)          echo "$ROOT_DIR/frameworks/$framework/compose.$profile.yml" ;;
    esac
}

# Expected container count per profile. The gateway-* profiles are fixed
# at exactly 2 (proxy + server). production-stack is fixed at 4 (edge +
# authsvc + cache + server). Any other count triggers a non-fatal warning
# at startup because stats aggregation assumes the whole stack is under
# our control — leftover sidecars would skew the numbers.
_gateway_expected_containers() {
    case "$1" in
        production-stack) echo 4 ;;
        *)                echo 2 ;;
    esac
}

gateway_up() {
    local framework="$1"
    local profile="${2:-gateway-64}"
    local compose_file
    compose_file=$(_gateway_compose_file "$framework" "$profile")
    GATEWAY_PROJECT="httparena-$framework-$profile"
    GATEWAY_ACTIVE_PROFILE="$profile"
    GATEWAY_ACTIVE_FRAMEWORK="$framework"

    [ -f "$compose_file" ] || fail "$profile: compose file not found at $compose_file"

    _gateway_env docker compose -f "$compose_file" -p "$GATEWAY_PROJECT" \
        down --remove-orphans 2>/dev/null || true

    info "starting gateway compose stack: $framework ($profile)"
    # --build forces compose to rebuild from source if any file in the
    # build context changed. Without this, an edit to a service Dockerfile
    # or Program.cs silently falls back to a stale image from the last run.
    _gateway_env docker compose -f "$compose_file" -p "$GATEWAY_PROJECT" up --build -d \
        || fail "gateway compose up failed"

    # Discover running container IDs for stats collection.
    sleep 2
    GATEWAY_CONTAINERS=$(docker ps -q --filter "label=com.docker.compose.project=$GATEWAY_PROJECT" 2>/dev/null | tr '\n' ' ')
    GATEWAY_CONTAINER_COUNT=$(echo "$GATEWAY_CONTAINERS" | wc -w)
    info "gateway containers: $GATEWAY_CONTAINER_COUNT ($GATEWAY_CONTAINERS)"

    local expected
    expected=$(_gateway_expected_containers "$profile")
    if [ "$GATEWAY_CONTAINER_COUNT" -ne "$expected" ]; then
        warn "$profile expects exactly $expected containers, found $GATEWAY_CONTAINER_COUNT — stats may not sum correctly"
    fi
}

gateway_down() {
    # Tear down whatever gateway stack is currently active. Callers can
    # pass (framework, profile) explicitly, but the normal cleanup path
    # (EXIT trap, post-run teardown) relies on the state gateway_up stored.
    local framework="${1:-$GATEWAY_ACTIVE_FRAMEWORK}"
    local profile="${2:-$GATEWAY_ACTIVE_PROFILE}"
    [ -n "$framework" ] || return 0
    [ -n "$profile" ]   || return 0
    local compose_file
    compose_file=$(_gateway_compose_file "$framework" "$profile")
    [ -f "$compose_file" ] || return 0
    _gateway_env docker compose -f "$compose_file" -p "httparena-$framework-$profile" \
        down --remove-orphans 2>/dev/null || true
    GATEWAY_PROJECT=""
    GATEWAY_ACTIVE_PROFILE=""
    GATEWAY_ACTIVE_FRAMEWORK=""
    GATEWAY_CONTAINERS=""
    GATEWAY_CONTAINER_COUNT=0
}

gateway_service_names() {
    local framework="$1"
    local profile="${2:-gateway-64}"
    local compose_file
    compose_file=$(_gateway_compose_file "$framework" "$profile")
    _gateway_env docker compose -f "$compose_file" -p "httparena-$framework-$profile" \
        ps --services 2>/dev/null
}
