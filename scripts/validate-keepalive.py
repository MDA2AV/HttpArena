#!/usr/bin/env python3
"""Idle keep-alive validation for HttpArena's connections-ramp-h1 (CON-RAMP).

CON-RAMP opens two million connections, 95% of which send one request and are
then left idle. A server may close an idle connection, but has to keep it for at
least 30 seconds first: without a floor, a server with a five second timeout
holds a few percent of the fleet and the profile measures how fast it can churn
connections, not how many it can carry.

This opens a handful of connections, sends one request on each, leaves them
alone for just under that long and sends a second one on the same connection.
Both requests have to be answered correctly. A connection the server closed in
the meantime fails, and the output says how long it lasted.

The wait is one second under the 30: a server's timer may be coarse (actix's
clock ticks every 500 ms, so a 30 s timeout closes at 29.5 to 30), and the point
is the order of magnitude, not the last second of a timer.

Usage: python3 validate-keepalive.py [host] [port] [idle_seconds] [connections]
  Defaults: localhost 8080 29 32
  Exit code 0 = all passed, 1 = failures
"""

import random
import selectors
import socket
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "localhost"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
IDLE = float(sys.argv[3]) if len(sys.argv) > 3 else 29.0
CONNS = int(sys.argv[4]) if len(sys.argv) > 4 else 32

CONNECT_TIMEOUT = 10
RESPONSE_TIMEOUT = 10

# More than this many connections failing the same way says it once each.
MAX_SHOWN = 5


class Conn:
    def __init__(self, n):
        self.n = n
        self.sock = None
        self.answered_at = 0.0   # when the response to the first request was in
        self.lived = None        # seconds it lasted idle, if the server closed it
        self.error = ""          # what went wrong, if anything

    def ok(self):
        return not self.error and self.lived is None


def request(a, b):
    return (f"GET /baseline11?a={a}&b={b} HTTP/1.1\r\n"
            f"Host: {HOST}\r\n\r\n").encode("latin-1")


def read_response(sock, timeout):
    """(status, body, why) - one response off the wire, reading no further than
    its end. status is None if there was no complete response."""
    sock.settimeout(timeout)
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            return None, "", "closed before answering" if buf == b"" else "closed mid-response"
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    try:
        status = int(lines[0].split(b" ")[1])
    except (IndexError, ValueError):
        return None, "", "not a status line: %r" % lines[0][:60]
    hdrs = {}
    for line in lines[1:]:
        k, _, v = line.partition(b":")
        hdrs[k.strip().lower()] = v.strip()
    if hdrs.get(b"connection", b"").lower() == b"close":
        return status, "", "the server sent Connection: close"
    if b"transfer-encoding" in hdrs:
        body, rest = b"", rest
        while True:
            while b"\r\n" not in rest:
                chunk = sock.recv(4096)
                if not chunk:
                    return None, "", "closed mid-response"
                rest += chunk
            size, _, rest = rest.partition(b"\r\n")
            n = int(size.split(b";")[0] or b"0", 16)
            while len(rest) < n + 2:
                chunk = sock.recv(4096)
                if not chunk:
                    return None, "", "closed mid-response"
                rest += chunk
            body, rest = body + rest[:n], rest[n + 2:]
            if n == 0:
                break
    elif b"content-length" in hdrs:
        n = int(hdrs[b"content-length"])
        while len(rest) < n:
            chunk = sock.recv(4096)
            if not chunk:
                return None, "", "closed mid-response"
            rest += chunk
        body, rest = rest[:n], rest[n:]
    else:
        return None, "", "no Content-Length and not chunked, so the end of the response cannot be told"
    return status, body.decode("utf-8", "replace").strip(), ""


def ask(conn, a, b, what):
    """Send one request, check the answer. Sets conn.error on a wrong one."""
    try:
        conn.sock.sendall(request(a, b))
        status, body, why = read_response(conn.sock, RESPONSE_TIMEOUT)
    except socket.timeout:
        conn.error = "%s: no answer within %d s" % (what, RESPONSE_TIMEOUT)
        return
    except OSError as e:
        conn.error = "%s: %s" % (what, e)
        return
    if why:
        conn.error = "%s: %s" % (what, why)
    elif status != 200 or body != str(a + b):
        conn.error = "%s: expected 200 %d, got %s %r" % (what, a + b, status, body[:40])


def open_all():
    conns = [Conn(i) for i in range(CONNS)]
    for c in conns:
        try:
            c.sock = socket.create_connection((HOST, PORT), timeout=CONNECT_TIMEOUT)
            c.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError as e:
            c.error = "connect: %s" % e
    return conns


def wait_idle(conns):
    """Watch the answered connections until every one has been idle for IDLE
    seconds, and record the ones the server closes before that."""
    live = [c for c in conns if c.ok()]
    end = max(c.answered_at for c in live) + IDLE
    sel = selectors.DefaultSelector()
    for c in live:
        c.sock.setblocking(False)
        sel.register(c.sock, selectors.EVENT_READ, c)
    while True:
        left = end - time.monotonic()
        if left <= 0 or not sel.get_map():
            break
        for key, _ in sel.select(timeout=left):
            c = key.data
            now = time.monotonic()
            try:
                data = c.sock.recv(4096)
            except OSError as e:
                data, c.error = b"", str(e)
            # a FIN or a reset is the server closing it; anything else arrived
            # unasked (some servers say 408 before they do)
            c.lived = now - c.answered_at
            if data:
                c.error = "sent %d bytes nobody asked for: %r" % (len(data), data[:60])
            sel.unregister(c.sock)
    sel.close()


def main():
    conns = open_all()
    for c in conns:
        if c.error:
            continue
        a, b = random.randint(100, 999), random.randint(100, 999)
        ask(c, a, b, "first request")
        c.answered_at = time.monotonic()
    ready = [c for c in conns if c.ok()]
    if ready:
        wait_idle(conns)
    for c in ready:
        if not c.ok():
            continue
        c.sock.setblocking(True)
        a, b = random.randint(100, 999), random.randint(100, 999)
        ask(c, a, b, "second request, after %.0f s idle" % IDLE)

    bad = [c for c in conns if not c.ok()]
    good = len(conns) - len(bad)
    print("  %s [keep-alive: idle for %.0f s, then used again] %d of %d connections"
          % ("PASS" if not bad else "FAIL", IDLE, good, len(conns)))
    early = [c for c in bad if c.lived is not None]
    if early:
        print("        %d closed while idle: first after %.1f s, last after %.1f s. "
              "Keep an idle connection open for at least 30 seconds"
              % (len(early), min(c.lived for c in early), max(c.lived for c in early)))
    shown = {}
    for c in bad:
        if c.lived is not None and not c.error:
            continue
        shown[c.error] = shown.get(c.error, 0) + 1
    for text, n in list(shown.items())[:MAX_SHOWN]:
        print("        %d: %s" % (n, text))
    for c in conns:
        if c.sock is not None:
            c.sock.close()
    print("=== %d passed, %d failed ===" % (1 if not bad else 0, 1 if bad else 0))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
