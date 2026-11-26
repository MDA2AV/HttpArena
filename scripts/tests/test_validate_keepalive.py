"""validate-keepalive.py: what a server has to do to keep idle connections."""

from pathlib import Path
import socket
import subprocess
import sys
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "validate-keepalive.py"


class Server(threading.Thread):
    """One thread per connection, answering GET /baseline11 until the idle timeout."""

    def __init__(self, idle=None, wrong=False, close=False):
        super().__init__(daemon=True)
        self.idle, self.wrong, self.close = idle, wrong, close
        self.sock = socket.create_server(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]

    def run(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def serve(self, conn):
        conn.settimeout(self.idle)
        try:
            while True:
                head = b""
                while b"\r\n\r\n" not in head:
                    chunk = conn.recv(4096)
                    if not chunk:
                        return
                    head += chunk
                query = head.split(b" ")[1].split(b"?", 1)[1].split(b"&")
                a, b = (int(q.split(b"=")[1]) for q in query)
                body = str(1 if self.wrong else a + b).encode()
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                             + (b"Connection: close\r\n" if self.close else b"")
                             + b"Content-Length: %d\r\n\r\n%s" % (len(body), body))
                if self.close:
                    return
        except OSError:
            pass          # the idle timeout, or the client going away
        finally:
            conn.close()


class KeepaliveTests(unittest.TestCase):
    def run_check(self, idle_seconds, **server):
        s = Server(**server)
        s.start()
        try:
            out = subprocess.run(
                [sys.executable, "-B", str(SCRIPT), "127.0.0.1", str(s.port),
                 str(idle_seconds), "6"], capture_output=True, text=True, timeout=30)
        finally:
            s.sock.close()
        return out.returncode, out.stdout + out.stderr

    def test_a_server_that_keeps_the_connection_passes(self):
        code, out = self.run_check(1, idle=None)
        self.assertEqual(code, 0, out)
        self.assertIn("1 passed, 0 failed", out)

    def test_a_server_that_closes_early_fails_and_says_after_how_long(self):
        code, out = self.run_check(1.5, idle=0.5)
        self.assertEqual(code, 1)
        self.assertIn("0 passed, 1 failed", out)
        self.assertIn("6 closed while idle", out)
        self.assertIn("first after 0.5 s", out)

    def test_a_server_that_closes_after_the_wait_passes(self):
        code, out = self.run_check(1, idle=30)
        self.assertEqual(code, 0, out)

    def test_a_wrong_answer_fails(self):
        code, out = self.run_check(1, idle=None, wrong=True)
        self.assertEqual(code, 1)
        self.assertIn("first request", out)

    def test_connection_close_fails(self):
        code, out = self.run_check(1, idle=None, close=True)
        self.assertEqual(code, 1)
        self.assertIn("Connection: close", out)

    def test_nothing_listening_fails(self):
        s = socket.create_server(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        out = subprocess.run([sys.executable, "-B", str(SCRIPT), "127.0.0.1", str(port), "1", "2"],
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 1, out.stdout)
        self.assertIn("0 passed, 1 failed", out.stdout)


if __name__ == "__main__":
    unittest.main()
