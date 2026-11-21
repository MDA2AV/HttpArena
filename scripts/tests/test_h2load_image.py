import os
import socket
import subprocess
import threading
import unittest
import uuid


@unittest.skipUnless(os.environ.get("HTTPARENA_TEST_H2LOAD_IMAGE"), "set HTTPARENA_TEST_H2LOAD_IMAGE to test a built image")
class H2loadImageTests(unittest.TestCase):
    def test_duration_ends_while_tls_handshake_is_pending(self):
        listener = socket.socket()
        listener.bind(("0.0.0.0", 0))
        listener.listen(1)
        listener.settimeout(6)
        stop = threading.Event()
        accepted = threading.Event()

        def hold_handshake():
            try:
                conn, _ = listener.accept()
                with conn:
                    accepted.set()
                    stop.wait(6)
            except OSError:
                pass

        thread = threading.Thread(target=hold_handshake)
        thread.start()
        name = "httparena-h2load-test-" + uuid.uuid4().hex
        host = os.environ.get("HTTPARENA_TEST_H2LOAD_HOST", "127.0.0.1")
        network = ["--network", "host"] if host == "127.0.0.1" else []
        try:
            result = subprocess.run(
                ["docker", "run", "--rm", "--init", "--name", name, *network,
                 "--entrypoint", "timeout", os.environ["HTTPARENA_TEST_H2LOAD_IMAGE"],
                 "-k", "1", "4", "h2load", "-c1", "-t1", "-D1",
                 f"https://{host}:{listener.getsockname()[1]}/"],
                capture_output=True, text=True, timeout=8, check=False,
            )
            self.assertTrue(accepted.is_set(), result.stdout + result.stderr)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("finished in", result.stdout)
        finally:
            stop.set()
            listener.close()
            thread.join(timeout=7)
            subprocess.run(["docker", "rm", "-f", name], capture_output=True, check=False)


if __name__ == "__main__":
    unittest.main()
