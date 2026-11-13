import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
H2 = """finished in 5.00s, 20.00 req/s, 2.00KB/s
requests: 100 total, 110 started, 100 done, 100 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 105 2xx, 0 3xx, 0 4xx, 0 5xx
time for request: 1ms 9ms 3ms 2ms 68.00%
"""
H3 = H2.replace(
    "time for request: 1ms 9ms 3ms 2ms 68.00%",
    "request     : 1ms 9ms 2ms 4ms 7ms 3ms 2ms 68.00%",
)


class H2loadTests(unittest.TestCase):
    def parse(self, output, tool="h2load", endpoint="h2"):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; output=$(cat); "${2}_parse" "$3" "$output"',
             "test", str(ROOT / "scripts/lib/tools" / f"{tool}.sh"),
             tool.replace("-", "_"), endpoint],
            input=output, text=True, capture_output=True, check=False,
        )

    def test_only_completed_successful_responses_count(self):
        for tool, output in [("h2load", H2), ("h2load-h3", H3)]:
            with self.subTest(tool=tool):
                result = self.parse(output, tool)
                self.assertEqual(result.returncode, 0, result.stderr)
                metrics = dict(line.split("=", 1) for line in result.stdout.splitlines())
                self.assertEqual(metrics["rps"], "20")
                self.assertEqual(metrics["duration"], "5.00s")

    def test_failed_streams_with_200_headers_are_rejected(self):
        broken = H3.replace("100 succeeded, 0 failed, 0 errored", "0 succeeded, 100 failed, 100 errored")
        result = self.parse(broken, "h2load-h3")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("rps=", result.stdout)

    def test_missing_or_invalid_summaries_are_rejected(self):
        for output in ["starting benchmark...", H2.split("requests:")[0],
                       H2.replace("5.00s", "0.00s"),
                       H2.replace("0 timeout", "1 timeout"),
                       H2.replace("0 4xx", "1 4xx")]:
            with self.subTest(output=output):
                result = self.parse(output)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("rps=", result.stdout)

    def test_maximum_is_not_published_as_p99(self):
        result = self.parse(H2)
        self.assertEqual(result.returncode, 0, result.stderr)
        metrics = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(metrics["avg_lat"], "3ms")
        self.assertEqual(metrics.get("p99_lat", ""), "")
        self.assertEqual(metrics["max_lat"], "9ms")

    def test_h3_keeps_its_actual_percentile(self):
        result = self.parse(H3, "h2load-h3")
        self.assertEqual(result.returncode, 0, result.stderr)
        metrics = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(metrics["p99_lat"], "7ms")
        self.assertEqual(metrics["avg_lat"], "3ms")

    def test_new_h2load_keeps_its_actual_percentile(self):
        result = self.parse(H3)
        self.assertEqual(result.returncode, 0, result.stderr)
        metrics = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(metrics["p99_lat"], "7ms")
        self.assertEqual(metrics["avg_lat"], "3ms")

    def test_versions_without_duration_shutdown_fix_are_rejected(self):
        for version, expected in [("1.59.0", False), ("1.68.0", False), ("1.69.0", True), ("2.0.0", True)]:
            with self.subTest(version=version):
                result = subprocess.run(
                    ["bash", "-c", 'source "$1"; H2LOAD=fake_h2load; TEST_VERSION="$2"; fake_h2load() { echo "h2load nghttp2/$TEST_VERSION"; }; h2load_check_version',
                     "test", str(ROOT / "scripts/lib/tools/h2load.sh"), version],
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode == 0, expected, result.stderr)

    def test_each_production_invocation_must_complete(self):
        for writes in ["starting benchmark...", H2.replace("0 errored", "1 errored")]:
            result = self.parse(f"=== h2load-reads ===\n{H2}=== h2load-writes ===\n{writes}", endpoint="production-stack")
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("rps=", result.stdout)

    def test_production_rates_use_each_invocations_duration(self):
        writes = H2.replace("5.00s", "10.00s")
        result = self.parse(f"=== h2load-reads ===\n{H2}=== h2load-writes ===\n{writes}", endpoint="production-stack")
        self.assertEqual(result.returncode, 0, result.stderr)
        metrics = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(metrics["rps"], "30")

    def test_timeout_exit_status_is_preserved(self):
        for tool in ["h2load", "h2load-h3"]:
            result = subprocess.run(
                ["bash", "-c", 'source "$1"; GCANNON_CPUS=0; timeout() { echo partial; return 124; }; "${2}_run" ignored',
                 "test", str(ROOT / "scripts/lib/tools" / f"{tool}.sh"), tool.replace("-", "_")],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 124, tool)
            self.assertIn("partial", result.stdout)

    def test_split_invocation_failure_is_preserved(self):
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; GCANNON_CPUS=0; timeout() { echo partial; return 124; }; h2load_run reads --split-- writes',
             "test", str(ROOT / "scripts/lib/tools/h2load.sh")],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 124)
        self.assertIn("=== h2load-reads ===", result.stdout)
        self.assertIn("=== h2load-writes ===", result.stdout)


if __name__ == "__main__":
    unittest.main()
