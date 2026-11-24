import os
import pathlib
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOWS = ("benchmark-pr.yml", "pr-commands.yml")


class WorkflowMergeTests(unittest.TestCase):
    def merge_after_fetch(self, command, conflicting):
        env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
               "GIT_AUTHOR_NAME": "Test", "GIT_COMMITTER_NAME": "Test",
               "GIT_AUTHOR_EMAIL": "test@example.com", "GIT_COMMITTER_EMAIL": "test@example.com"}

        def git(repo, *args, check=True):
            return subprocess.run(["git", "-C", str(repo), *args], env=env,
                                  capture_output=True, text=True, check=check)

        with tempfile.TemporaryDirectory() as tmp:
            origin = pathlib.Path(tmp) / "origin"
            origin.mkdir()
            git(origin, "init", "-b", "main")
            (origin / "shared").write_text("base\n")
            git(origin, "add", ".")
            git(origin, "commit", "-m", "test: base")
            git(origin, "checkout", "-b", "feature")
            (origin / ("shared" if conflicting else "feature")).write_text("feature\n")
            git(origin, "add", ".")
            git(origin, "commit", "-m", "test: feature")
            git(origin, "checkout", "main")
            (origin / ("shared" if conflicting else "upstream")).write_text("upstream\n")
            git(origin, "add", ".")
            git(origin, "commit", "-m", "test: upstream")

            checkout = pathlib.Path(tmp) / "checkout"
            git(origin, "clone", "--no-local", str(origin), str(checkout))
            git(checkout, "checkout", "feature")
            git(checkout, *shlex.split(command)[1:])
            result = git(checkout, "merge", "--no-commit", "--no-ff", "origin/main", check=False)
            files = {p.name: p.read_text() for p in checkout.iterdir() if p.is_file()}
        return result, files

    def fetch_commands(self):
        for name in WORKFLOWS:
            text = (ROOT / ".github/workflows" / name).read_text()
            commands = re.findall(r"^\s*(git fetch origin main[^\n]*)$", text, re.MULTILINE)
            self.assertTrue(commands, f"no main-fetch commands found in {name}")
            for line in commands:
                yield name, line.strip()

    def test_diverged_branches_with_compatible_changes_can_merge(self):
        for workflow, command in self.fetch_commands():
            with self.subTest(workflow=workflow, command=command):
                result, files = self.merge_after_fetch(command, conflicting=False)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(files["feature"], "feature\n")
                self.assertEqual(files["upstream"], "upstream\n")

    def test_real_content_conflicts_are_still_rejected(self):
        for workflow, command in self.fetch_commands():
            with self.subTest(workflow=workflow, command=command):
                result, _ = self.merge_after_fetch(command, conflicting=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("CONFLICT", result.stdout)
                self.assertNotIn("unrelated histories", result.stderr)


if __name__ == "__main__":
    unittest.main()
