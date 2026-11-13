import os
import subprocess
import unittest


@unittest.skipUnless(os.environ.get("HTTPARENA_TEST_AUTHSVC_IMAGE"), "set HTTPARENA_TEST_AUTHSVC_IMAGE to test a built image")
class AuthImageTests(unittest.TestCase):
    def test_image_runs_the_real_health_endpoint(self):
        result = subprocess.run(
            ["docker", "run", "--rm", "--entrypoint", "sh", os.environ["HTTPARENA_TEST_AUTHSVC_IMAGE"], "-c", """
set -eu
/usr/local/bin/authsvc &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" || true' EXIT
for attempt in 1 2 3 4 5; do
    if wget -q -O /dev/null http://127.0.0.1:9090/_health; then exit 0; fi
    kill -0 "$pid" 2>/dev/null || exit 1
    sleep 1
done
exit 1
"""], capture_output=True, text=True, timeout=20, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
