import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class H2loadSetupTests(unittest.TestCase):
    def prepare(self, **overrides):
        harness = r'''
set -euo pipefail
source "$1/scripts/lib/common.sh"
source "$1/scripts/lib/tools/h2load.sh"
ROOT_DIR="$1"
REQUESTS_DIR=/requests
GCANNON_CPUS=2-3
H2C_PORT=8082
H2THREADS=2
H2LOAD_IMAGE=h2load:test
H2LOAD_H3=h2load-h3
native() {
    if [ "$2" = --version ]; then
        [ "$1" != missing ] || return 127
        echo "h2load nghttp2/$1"
    else
        echo "MEASURED $1 $*"
    fi
}
h2load() { native "$NATIVE_VERSION" "$@"; }
h2load-h3() { native "$H3_VERSION" "$@"; }
custom() { native 1.59.0 "$@"; }
docker() {
    printf '%s\n' "$*" >> "$DOCKER_LOG"
    case "$1" in
        image) return 1 ;;
        build) return "$BUILD_EXIT" ;;
        run)
            if [ "${!#}" = --version ]; then
                echo "h2load nghttp2/$IMAGE_VERSION"
            else
                echo "MEASURED docker $*"
            fi
            ;;
        *) return 99 ;;
    esac
}
h2load_prepare
mapfile -t command < <(h2load_build_args h2c 4 1 1s)
"${command[@]}"
'''
        with tempfile.TemporaryDirectory() as tmp:
            log = pathlib.Path(tmp) / "docker.log"
            env = {key: value for key, value in os.environ.items() if key != "H2LOAD"}
            result = subprocess.run(
                ["bash", "-c", harness, "test", str(ROOT)],
                env={**env, "H2LOAD_CMD": "",
                     "H2LOAD_VERSION_CHECKED": "false", "NATIVE_VERSION": "1.59.0",
                     "H3_VERSION": "missing", "IMAGE_VERSION": "1.69.0",
                     "BUILD_EXIT": "0", "DOCKER_LOG": str(log), **overrides},
                capture_output=True, text=True, check=False,
            )
            calls = log.read_text() if log.exists() else ""
        return result, calls

    def test_supported_native_client_runs_http2_without_docker(self):
        for native, h3, selected in [
            ("1.70.0", "1.69.0", "1.70.0"),
            ("1.59.0", "1.69.0", "1.69.0"),
            ("missing", "1.69.0", "1.69.0"),
        ]:
            with self.subTest(native=native, h3=h3):
                result, calls = self.prepare(NATIVE_VERSION=native, H3_VERSION=h3)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"MEASURED {selected}", result.stdout)
                self.assertIn("http://localhost:8082/baseline2?a=1&b=1 -p h2c", result.stdout)
                self.assertNotIn("--alpn-list=h3", result.stdout)
                self.assertEqual(calls, "")

    def test_missing_or_old_native_clients_use_pinned_http2_image(self):
        for native, h3 in [("1.59.0", "1.68.0"), ("missing", "missing")]:
            with self.subTest(native=native, h3=h3):
                result, calls = self.prepare(NATIVE_VERSION=native, H3_VERSION=h3)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("MEASURED docker", result.stdout)
                self.assertIn("build -t h2load:test", calls)
                self.assertIn("docker/h2load.Dockerfile", calls)
                self.assertIn("--network host --cpuset-cpus=2-3", calls)
                self.assertIn("-v /requests:/requests:ro", calls)
                self.assertLess(calls.index("build "), calls.index("--version"))
                self.assertNotIn("--alpn-list=h3", result.stdout)

    def test_explicit_commands_are_not_silently_replaced(self):
        for override in [{"H2LOAD": "h2load"}, {"H2LOAD": "custom"}, {"H2LOAD_CMD": "custom"}]:
            with self.subTest(override=override):
                result, calls = self.prepare(H3_VERSION="1.69.0", **override)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("MEASURED", result.stdout)
                self.assertEqual(calls, "")

    def test_unusable_fallback_stops_before_measurement(self):
        for override in [{"BUILD_EXIT": "42"}, {"IMAGE_VERSION": "1.59.0"}]:
            with self.subTest(override=override):
                result, _ = self.prepare(**override)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("MEASURED", result.stdout)


if __name__ == "__main__":
    unittest.main()
