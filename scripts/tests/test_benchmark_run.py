import os
import pathlib
import re
import subprocess
import unittest

from test_h2load import H2


ROOT = pathlib.Path(__file__).resolve().parents[2]
BENCHMARK = ROOT / "scripts/benchmark.sh"


class BenchmarkRunTests(unittest.TestCase):
    driver = BENCHMARK

    def run_measurement(self, output, exit_code=0, version_supported=True):
        function = re.search(r"^run_one\(\) \{\n.*?^\}", self.driver.read_text(), re.MULTILINE | re.DOTALL)[0]
        harness = '''
set -euo pipefail
source "$1"
parse_profile() { PROF_ENDPOINT=h2; PROF_PIPELINE=1; PROF_CPU=1; PROF_REQ=1; }
endpoint_tool() { echo h2load; }
banner() { :; }
info() { echo "$*"; }
warn() { echo "$*" >&2; }
framework_start() { echo STARTED; }
framework_wait_ready() { return 0; }
framework_stop() { echo STOPPED; }
stats_start() { :; }
stats_stop() { :; }
cpu_acct_start() { :; }
cpu_acct_stop() { :; }
sleep() { :; }
h2load_build_args() { echo ignored; }
h2load_check_version() { test "$VERSION_SUPPORTED" = true; }
h2load_run() { printf '%s\\n' "$LOAD_OUTPUT"; return "$LOAD_EXIT"; }
save_result() { echo SAVED; }
FRAMEWORK=sample
CONTAINER_NAME=sample
RUNS=1
DURATION=5s
SAVE_RESULTS=true
STATS_AVG_CPU=1%
STATS_PEAK_MEM=1MiB
STATS_BREAKDOWN=""
declare -A PROFILES=([baseline-h2]=ignored)
declare -A BEST_M
'''
        return subprocess.run(
            ["bash", "-c", harness + function + "\nrun_one baseline-h2 256 && exit 0 || exit $?\n", "test",
             str(ROOT / "scripts/lib/tools/h2load.sh")],
            env={**os.environ, "LOAD_OUTPUT": output, "LOAD_EXIT": str(exit_code),
                 "VERSION_SUPPORTED": str(version_supported).lower()},
            capture_output=True, text=True, check=False,
        )

    def test_incomplete_run_is_not_saved_as_zero_rps(self):
        result = self.run_measurement("starting benchmark...")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("SAVED", result.stdout)
        self.assertIn("STOPPED", result.stdout)

    def test_timeout_cannot_publish_a_partial_summary(self):
        result = self.run_measurement(H2, exit_code=124)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("SAVED", result.stdout)
        self.assertIn("STOPPED", result.stdout)

    def test_valid_result_is_saved_and_server_is_stopped(self):
        result = self.run_measurement(H2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("=== Best: 20 req/s", result.stdout)
        self.assertIn("SAVED", result.stdout)
        self.assertIn("STOPPED", result.stdout)

    def test_unsupported_load_generator_is_rejected_before_server_start(self):
        result = self.run_measurement(H2, version_supported=False)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("STARTED", result.stdout)
        self.assertNotIn("SAVED", result.stdout)


class LiteBenchmarkRunTests(BenchmarkRunTests):
    driver = ROOT / "scripts/benchmark-lite.sh"


if __name__ == "__main__":
    unittest.main()
