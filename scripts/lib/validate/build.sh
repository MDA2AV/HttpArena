# scripts/lib/validate/build.sh — build the framework Docker image (unless gateway-only)
# Part of the validate.sh suite — sourced by scripts/validate.sh, not run directly.

# Build — skip standalone build if framework only subscribes to compose profiles
# (gateway-64, gateway-h3, production-stack) and has no isolated tests.
GATEWAY_ONLY=true
for t in $TESTS; do
    case "$t" in
        gateway-64|gateway-h3|production-stack) ;;
        *) GATEWAY_ONLY=false ;;
    esac
done

if [ "$GATEWAY_ONLY" = "false" ]; then
    echo "[build] Building Docker image..."
    if [ -x "frameworks/$FRAMEWORK/build.sh" ]; then
        "frameworks/$FRAMEWORK/build.sh" || { echo "FAIL: Docker build failed"; exit 1; }
    else
        docker build --no-cache -t "$IMAGE_NAME" "frameworks/$FRAMEWORK" || { echo "FAIL: Docker build failed"; exit 1; }
    fi
fi

# keep `source` exit status 0 so the orchestrator continues (set -e stays active inside)
true
