#!/usr/bin/env bash
# Local-source build for the orisha entry. validate.sh prefers this script
# over `docker build frameworks/orisha` when it exists. Instead of cloning
# korulang/{koru,koru-libs,orisha}@main it stages the developer's checkouts
# into a scratch context — uncommitted work included — and builds the same
# image name the validator runs. Only the compile-relevant subtrees ship:
# the repos carry gigabytes of tests, benches and cache the image never reads.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PUMP="${PUMP:-linux}"
case "$PUMP" in
    io-uring) IMAGE_NAME="httparena-orisha-uring"; BUILD_FLAG="--build=io-uring" ;;
    race) IMAGE_NAME="httparena-orisha-race"; BUILD_FLAG="--build=race" ;;
    linux|default) IMAGE_NAME="httparena-orisha"; BUILD_FLAG="" ;;
    *) echo "build.sh: unknown PUMP=$PUMP (io-uring|race|linux|default)" >&2; exit 1 ;;
esac
IMAGE_NAME="${IMAGE_NAME_OVERRIDE:-$IMAGE_NAME}"
KORU_SRC="${KORU_SRC:-$HOME/src/koru}"
KORU_LIBS_SRC="${KORU_LIBS_SRC:-$HOME/src/koru-libs}"
ORISHA_SRC="${ORISHA_SRC:-$HOME/src/orisha}"

for d in "$KORU_SRC" "$KORU_LIBS_SRC" "$ORISHA_SRC"; do
    [ -d "$d" ] || { echo "build.sh: missing source tree $d" >&2; exit 1; }
done

CTX="$(mktemp -d /tmp/orisha-build.XXXXXX)"
trap 'rm -rf "$CTX"' EXIT

# koru: the compiler itself — `zig build` needs src/ + the build files;
# koru_std is the std module the entry's koru.json maps `std` to.
mkdir -p "$CTX/koru"
cp "$KORU_SRC/build.zig" "$KORU_SRC/build.zig.zon" "$CTX/koru/"
rsync -a "$KORU_SRC/src/" "$CTX/koru/src/"
rsync -a "$KORU_SRC/koru_std/" "$CTX/koru/koru_std/"

# koru-libs: only koru/openssl is imported (TLS helpers via orisha's pump).
mkdir -p "$CTX/koru-libs/openssl"
rsync -a "$KORU_LIBS_SRC/openssl/" "$CTX/koru-libs/openssl/"

# orisha: the framework lib + the benchmark entry. data/ and certs/ mount
# at container runtime; bench artifacts stay out of the image.
mkdir -p "$CTX/orisha/httparena"
rsync -a "$ORISHA_SRC/lib/" "$CTX/orisha/lib/"
cp "$ORISHA_SRC/httparena/"*.k "$ORISHA_SRC/httparena/koru.json" \
   "$CTX/orisha/httparena/"

# Same recipe as the submission Dockerfile, with the clone step replaced
# by COPY of the staged sources.
python3 - "$HERE/Dockerfile" "$CTX/Dockerfile" "$BUILD_FLAG" <<'EOF'
import sys, re
src = open(sys.argv[1]).read()
new, n = re.subn(
    r'RUN git clone[^\n]*\\\n(?:\s*&&[^\n]*\\\n)*\s*&&[^\n]*\n',
    'COPY koru /src/koru\nCOPY koru-libs /src/koru-libs\nCOPY orisha /src/orisha\n',
    src, count=1)
if n == 0:
    sys.exit("build.sh: could not locate the git-clone RUN block in Dockerfile")
flag = sys.argv[3]
if flag:
    new, m = re.subn(r'koruc main\.k --release=fast', f'koruc main.k --release=fast {flag}', new, count=1)
    if m == 0:
        sys.exit("build.sh: could not locate the koruc invocation in Dockerfile")
open(sys.argv[2], 'w').write(new)
EOF
grep -q "COPY koru /src/koru" "$CTX/Dockerfile" \
    || { echo "build.sh: failed to patch Dockerfile" >&2; exit 1; }

docker build -t "$IMAGE_NAME" "$CTX"
echo "built $IMAGE_NAME (pump=$PUMP) from local sources:"
echo "  koru      = $KORU_SRC"
echo "  koru-libs = $KORU_LIBS_SRC"
echo "  orisha    = $ORISHA_SRC"
