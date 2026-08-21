#!/usr/bin/env python3
"""Exhaustive TCP-fragmentation validation for HttpArena.

Where validate.sh's check_fragmented picks a handful of split points by hand,
this splits every request shape at EVERY byte offset. Hand-picked splits only
cover the boundaries someone thought of; the parser bugs that survive are the
ones nobody picks - between the CR and the LF, mid Content-Length digits, mid
chunk-size hex, one byte into the terminating 0\\r\\n\\r\\n.

For each offset: open a connection, write the first part, pause, write the
rest, and require 200 with the exact expected body. The pause is what makes it
a real test - it guarantees the server's read loop returns with a partial
buffer and has to carry parser state across recv() calls, instead of the kernel
coalescing both writes into one.

Every shape carries the `?a=…&b=…` query string, so query parsing is on the
split path too, not just the request line and headers.

Approach borrowed from uWebSockets/tests/fragment_test.ts, which does the same
byte-by-byte sweep. Two differences: the body is asserted, not just the status
(a server can answer 200 with the wrong sum), and connections are opened in
batches so one pause covers a whole batch rather than one offset.

Usage: python3 validate-frag.py [host] [port] [delay_ms]
  Defaults: localhost 8080 200
  Exit code 0 = all passed, 1 = failures
"""

import random
import socket
import sys
import time
from concurrent.futures import ThreadPoolExecutor

HOST = sys.argv[1] if len(sys.argv) > 1 else "localhost"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
DELAY = (int(sys.argv[3]) if len(sys.argv) > 3 else 200) / 1000.0

# Sockets held open at once. Each batch pays the pause once, so the whole run
# costs ceil(offsets / BATCH) * DELAY rather than offsets * DELAY. Kept well
# under the default 1024 fd limit.
BATCH = 384

CONNECT_TIMEOUT = 10

PASS = 0
FAIL = 0

# ── Request shapes ────────────────────────────────────────────────────────
# The three the baseline profile defines (GET, POST + Content-Length, POST +
# chunked), each in more than one spelling. Randomized operands appear in two
# of them so a hardcoded response fails here as well as in the main checks.

RA, RB = random.randint(100, 999), random.randint(100, 999)
RBODY = random.randint(10, 99)


def shapes():
    return [
        ("GET, minimal",
         f"GET /baseline11?a=13&b=42 HTTP/1.1\r\n"
         f"Host: {HOST}\r\nConnection: close\r\n\r\n", "55"),

        ("GET, several headers",
         f"GET /baseline11?a=13&b=42 HTTP/1.1\r\n"
         f"Host: {HOST}\r\nUser-Agent: arena-frag/1.0\r\n"
         f"Accept: text/plain\r\nAccept-Encoding: identity\r\n"
         f"Connection: close\r\n\r\n", "55"),

        ("GET, lower-cased field names",
         f"GET /baseline11?a=13&b=42 HTTP/1.1\r\n"
         f"host: {HOST}\r\nuser-agent: arena-frag/1.0\r\nconnection: close\r\n\r\n", "55"),

        ("GET, randomized query",
         f"GET /baseline11?a={RA}&b={RB} HTTP/1.1\r\n"
         f"Host: {HOST}\r\nConnection: close\r\n\r\n", str(RA + RB)),

        ("POST, Content-Length",
         f"POST /baseline11?a=13&b=42 HTTP/1.1\r\n"
         f"Host: {HOST}\r\nContent-Type: text/plain\r\n"
         f"Content-Length: 2\r\nConnection: close\r\n\r\n20", "75"),

        ("POST, lower-cased content-length",
         f"POST /baseline11?a=13&b=42 HTTP/1.1\r\n"
         f"host: {HOST}\r\ncontent-type: text/plain\r\n"
         f"content-length: 2\r\nconnection: close\r\n\r\n20", "75"),

        ("POST, randomized body",
         f"POST /baseline11?a={RA}&b={RB} HTTP/1.1\r\n"
         f"Host: {HOST}\r\nContent-Type: text/plain\r\n"
         f"Content-Length: {len(str(RBODY))}\r\nConnection: close\r\n\r\n{RBODY}",
         str(RA + RB + RBODY)),

        ("POST, chunked",
         f"POST /baseline11?a=13&b=42 HTTP/1.1\r\n"
         f"Host: {HOST}\r\nContent-Type: text/plain\r\n"
         f"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
         f"2\r\n20\r\n0\r\n\r\n", "75"),

        ("POST, chunked in two chunks",
         f"POST /baseline11?a=13&b=42 HTTP/1.1\r\n"
         f"Host: {HOST}\r\nContent-Type: text/plain\r\n"
         f"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
         f"1\r\n2\r\n1\r\n0\r\n0\r\n\r\n", "75"),
    ]


# ── Response parsing ──────────────────────────────────────────────────────

def parse(raw):
    """(status, body) from a raw HTTP/1.1 response. Decodes a chunked body."""
    try:
        head, sep, rest = raw.partition(b"\r\n\r\n")
        if not sep:
            return -1, ""
        lines = head.split(b"\r\n")
        status = int(lines[0].split(b" ")[1])
        hdrs = {}
        for line in lines[1:]:
            k, _, v = line.partition(b":")
            hdrs[k.strip().lower()] = v.strip()
        if hdrs.get(b"transfer-encoding", b"").lower() == b"chunked":
            out = b""
            while True:
                size_line, _, rest = rest.partition(b"\r\n")
                n = int(size_line.split(b";")[0] or b"0", 16)
                if n == 0:
                    break
                out, rest = out + rest[:n], rest[n + 2:]
            body = out
        elif b"content-length" in hdrs:
            body = rest[:int(hdrs[b"content-length"])]
        else:
            body = rest
        return status, body.decode("utf-8", "replace").strip()
    except Exception:
        return -1, ""


# ── One batch: open, write first half, pause once, finish ─────────────────

def run_batch(batch):
    handles = []
    for offset, first, second in batch:
        try:
            s = socket.create_connection((HOST, PORT), timeout=CONNECT_TIMEOUT)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)  # no Nagle coalescing
            s.sendall(first)
            handles.append((s, offset, second, None))
        except Exception as e:
            handles.append((None, offset, second, f"{type(e).__name__}: {e}"))

    # The whole point: the server is now sitting on a partial request.
    time.sleep(DELAY)

    def finish(h):
        s, offset, second, err = h
        if err:
            return offset, -1, "", err
        try:
            s.sendall(second)
            buf = b""
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                buf += chunk
            status, body = parse(buf)
            return offset, status, body, None
        except socket.timeout:
            return offset, -1, "", "timeout (server never answered or never closed)"
        except Exception as e:
            return offset, -1, "", f"{type(e).__name__}: {e}"
        finally:
            try:
                s.close()
            except Exception:
                pass

    with ThreadPoolExecutor(max_workers=64) as ex:
        return list(ex.map(finish, handles))


def esc(s):
    return s.replace("\r", "\\r").replace("\n", "\\n")


def check_shape(name, request, expected):
    global PASS, FAIL
    raw = request.encode("latin-1")
    splits = [(i, raw[:i], raw[i:]) for i in range(1, len(raw))]

    results = []
    for i in range(0, len(splits), BATCH):
        results.extend(run_batch(splits[i:i + BATCH]))

    bad = [r for r in results if r[1] != 200 or r[2] != expected]
    if not bad:
        PASS += 1
        print(f"  PASS [frag: {name}] all {len(results)} offsets -> 200 {expected!r}")
        return

    FAIL += 1
    print(f"  FAIL [frag: {name}] {len(bad)}/{len(results)} offsets wrong "
          f"(expected 200 {expected!r})")
    for offset, status, body, err in bad[:5]:
        detail = err if err else f"status={status} body={body!r}"
        print(f"    offset {offset:>3}: {detail}")
        pre, post = raw[:offset].decode("latin-1"), raw[offset:].decode("latin-1")
        print(f"      ...{esc(pre[-40:])} >>>SPLIT<<< {esc(post[:40])}...")
    if len(bad) > 5:
        print(f"    ... and {len(bad) - 5} more offsets")


# ── Run ───────────────────────────────────────────────────────────────────

all_shapes = shapes()
total = sum(len(s[1].encode("latin-1")) - 1 for s in all_shapes)
print(f"[frag] {len(all_shapes)} request shapes, {total} split offsets, "
      f"{int(DELAY * 1000)}ms pause per batch of {BATCH}")

for name, request, expected in all_shapes:
    check_shape(name, request, expected)

print(f"\n=== Frag Results: {PASS} passed, {FAIL} failed ===")
sys.exit(1 if FAIL > 0 else 0)
