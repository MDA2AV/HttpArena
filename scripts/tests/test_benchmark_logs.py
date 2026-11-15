import os
import pathlib
import re
import subprocess
import tempfile
import unittest

from test_h2load import H2


ROOT = pathlib.Path(__file__).resolve().parents[2]


class BenchmarkLogTests(unittest.TestCase):
    def measure(self, valid, gateway=True, save=True, lite=False, noisy=False):
        driver = (ROOT / "scripts" / ("benchmark-lite.sh" if lite else "benchmark.sh")).read_text()
        functions = "\n".join(
            re.search(rf"^{name}\(\) \{{\n.*?^\}}(?=\n\n)", driver, re.MULTILINE | re.DOTALL)[0]
            for name in ("run_one", "save_result")
        )
        harness = r'''
set -euo pipefail
source "$1/scripts/lib/common.sh"
source "$1/scripts/lib/tools/h2load.sh"
ROOT_DIR="$2"
RESULTS_DIR="$2/results"
parse_profile() { PROF_ENDPOINT="$ENDPOINT"; PROF_PIPELINE=1; PROF_CPU=1; PROF_REQ=1; }
endpoint_tool() { echo h2load; }
framework_start() { :; }
framework_wait_ready() { return 0; }
framework_stop() { touch "$ROOT_DIR/stopped"; }
gateway_up() { GATEWAY_PROJECT=httparena-sample-production-stack; }
gateway_down() { touch "$ROOT_DIR/stopped"; GATEWAY_PROJECT=""; }
stats_start() { :; }
stats_stop() { :; }
cpu_acct_start() { :; }
cpu_acct_stop() { :; }
sleep() { :; }
h2load_build_args() { echo ignored; }
h2load_check_version() { return 0; }
h2load_run() { printf '%s\n' "$LOAD_OUTPUT"; }
h2load_diagnose() { echo 'DIAGNOSTIC REPLAY'; }
docker() {
    [ ! -f "$ROOT_DIR/stopped" ] || { echo 'logs requested after teardown'; return 1; }
    case "$1" in
        ps)
            printf 'edge-id\nserver-id\n'
            [ "$2" != -aq ] || echo auth-id ;;
        inspect)
            if [[ "$*" == *'{{.Name}}'* ]]; then echo "/${!#}";
            else echo 'status=exited exit=1 oom=false error='; fi ;;
        logs)
            case "${!#}" in
                edge-id) echo 'GET /api/me: 401' ;;
                auth-id) echo 'auth diagnostic' ;;
                server-id|single)
                    if [ "$NOISY" = true ]; then
                        python3 -c 'print("x" * 12000)'
                    fi
                    echo 'database unavailable' ;;
                *) echo "No such container: ${!#}"; return 1 ;;
            esac ;;
        *) echo "unexpected docker call: $*"; return 1 ;;
    esac
}
FRAMEWORK=sample
CONTAINER_NAME=single
[ "$ENDPOINT" != production-stack ] || CONTAINER_NAME=nonexistent-compose-container
GATEWAY_CONTAINERS='edge-id server-id'
DISPLAY_NAME=sample
LANGUAGE=Rust
RUNS=1
DURATION=5s
STATS_AVG_CPU=1%
STATS_PEAK_MEM=1MiB
STATS_BREAKDOWN=""
declare -A PROFILES=([production-stack]=ignored)
declare -A BEST_M
'''
        output = H2 if valid else H2.replace("100 succeeded, 0 failed", "99 succeeded, 1 failed")
        if gateway:
            output = f"=== h2load-reads ===\n{output}\n=== h2load-writes ===\n{H2}"
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(
                ["bash", "-c", harness + functions + "\nrun_one production-stack 256 && exit 0 || exit $?\n",
                 "test", str(ROOT), tmp],
                env={**os.environ, "LOAD_OUTPUT": output, "ENDPOINT": "production-stack" if gateway else "h2",
                     "SAVE_RESULTS": str(save).lower(), "NOISY": str(noisy).lower(),
                     "HTTPARENA_MAX_LOG_BYTES": "128" if noisy else "8000000"},
                capture_output=True, text=True, check=False,
            )
            log_path = pathlib.Path(tmp) / "site/static/logs/production-stack/256/sample.log"
            log = log_path.read_text() if log_path.exists() else ""
            saved = (pathlib.Path(tmp) / "results/production-stack/256/sample.json").exists()
            stopped = (pathlib.Path(tmp) / "stopped").exists()
        return result, log, saved, stopped

    def test_compose_logs_survive_success_and_failed_measurements(self):
        for valid in (False, True):
            with self.subTest(valid=valid):
                result, log, saved, stopped = self.measure(valid)
                self.assertEqual(result.returncode, 0 if valid else 1, result.stderr)
                self.assertEqual(saved, valid)
                self.assertTrue(stopped)
                for diagnostic in ("GET /api/me: 401", "auth diagnostic", "database unavailable"):
                    self.assertIn(diagnostic, log)
                    if not valid:
                        self.assertIn(diagnostic, result.stdout)
                self.assertNotIn("No such container", log)
                self.assertNotIn("after teardown", log)
                self.assertEqual("DIAGNOSTIC REPLAY" in result.stdout, not valid)

    def test_failed_single_container_logs_respect_save_flag(self):
        for lite in (False, True):
            for save in (False, True):
                with self.subTest(lite=lite, save=save):
                    result, log, saved, stopped = self.measure(False, gateway=False, save=save, lite=lite)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertFalse(saved)
                    self.assertTrue(stopped)
                    self.assertIn("database unavailable", result.stdout)
                    self.assertEqual("database unavailable" in log, save)
                    self.assertNotIn("DIAGNOSTIC REPLAY", result.stdout)

    def test_noisy_service_log_is_capped_and_keeps_the_last_error(self):
        for gateway in (False, True):
            with self.subTest(gateway=gateway):
                result, log, saved, _ = self.measure(True, gateway=gateway, noisy=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(saved)
                self.assertLess(len(log.encode()), 256)
                self.assertIn("keeping the last 128", log)
                self.assertIn("database unavailable", log)


if __name__ == "__main__":
    unittest.main()
