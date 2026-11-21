import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class CompositeStatusTests(unittest.TestCase):
    def test_failed_or_unfinished_variants_cannot_reuse_a_retained_composite(self):
        for status in (None, "running", "1", "0"):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                statuses = root / "statuses"
                statuses.mkdir()
                (statuses / "sample.exit").write_text("0\n")
                if status is not None:
                    (statuses / "sample-grpc.exit").write_text(status + "\n")
                for data in (root / "main", root / "run"):
                    (data / "results").mkdir(parents=True)
                    (data / "frameworks.json").write_text(json.dumps({"sample": {
                        "dir": "sample", "type": "emerging", "language": "Rust",
                        "variants": [{"dir": "sample-grpc"}],
                    }, "rival": {"dir": "rival", "type": "emerging", "language": "Rust"}}))
                    for name in ("sample", "rival"):
                        (data / "results" / f"{name}.json").write_text(json.dumps({
                            "framework": name, "results": {"baseline-4096": {
                                "framework": name, "language": "Rust", "rps": 100,
                                "cpu": "100%", "memory": "10MiB", "connections": 4096,
                            }},
                        }))
                result = subprocess.run([
                    "python3", "-B", str(ROOT / "scripts/composite_delta.py"),
                    str(root / "main"), str(root / "run"), str(root / "out"),
                    "sample", "sample-grpc",
                ], env={**os.environ, "HTTPARENA_RUN_STATUS_DIR": str(statuses)},
                    capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                for name in ("sample", "sample-grpc"):
                    report = (root / "out" / f"{name}.composite.md").read_text()
                    if status == "0":
                        self.assertIn("**Composite score**", report)
                    else:
                        self.assertIn("Composite score unavailable", report)
                        self.assertNotIn("| Family |", report)


if __name__ == "__main__":
    unittest.main()
