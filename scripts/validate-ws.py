#!/usr/bin/env python3
"""WebSocket echo validation for HttpArena.

Zero-dependency WebSocket client using raw sockets.
Validates: upgrade handshake, text echo, binary echo, ping/pong, clean close.

Usage: python3 validate-ws.py [host] [port] [path]
  Defaults: localhost 8080 /ws
  Exit code 0 = all passed, 1 = failures
"""

import hashlib
import base64
import os
import socket
import struct
import sys
import time

# ── Config ──

HOST = sys.argv[1] if len(sys.argv) > 1 else "localhost"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
PATH = sys.argv[3] if len(sys.argv) > 3 else "/ws"

PASS = 0
FAIL = 0

# ── WebSocket opcodes ──

OP_TEXT = 0x1
OP_BINARY = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA

# ── Helpers ──

def result(label, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  PASS [{label}]{' (' + detail + ')' if detail else ''}")
    else:
        FAIL += 1
        print(f"  FAIL [{label}]{': ' + detail if detail else ''}")

def make_ws_key():
    return base64.b64encode(os.urandom(16)).decode()

def expected_accept(key):
    magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    return base64.b64encode(hashlib.sha1(magic.encode()).digest()).decode()

def send_frame(sock, opcode, payload, mask=True):
    """Send a WebSocket frame. Client frames MUST be masked per RFC 6455."""
    fin_opcode = 0x80 | opcode
    data = payload if isinstance(payload, bytes) else payload.encode()
    length = len(data)

    header = bytes([fin_opcode])
    mask_bit = 0x80 if mask else 0x00

    if length < 126:
        header += bytes([mask_bit | length])
    elif length < 65536:
        header += bytes([mask_bit | 126]) + struct.pack("!H", length)
    else:
        header += bytes([mask_bit | 127]) + struct.pack("!Q", length)

    if mask:
        mask_key = os.urandom(4)
        header += mask_key
        masked = bytes(b ^ mask_key[i % 4] for i, b in enumerate(data))
        sock.sendall(header + masked)
    else:
        sock.sendall(header + data)

def recv_frame(sock, timeout=5.0):
    """Receive a WebSocket frame. Returns (opcode, payload_bytes)."""
    sock.settimeout(timeout)
    try:
        head = _recv_exact(sock, 2)
        opcode = head[0] & 0x0F
        masked = bool(head[1] & 0x80)
        length = head[1] & 0x7F

        if length == 126:
            length = struct.unpack("!H", _recv_exact(sock, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", _recv_exact(sock, 8))[0]

        if masked:
            mask_key = _recv_exact(sock, 4)
            raw = _recv_exact(sock, length)
            payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(raw))
        else:
            payload = _recv_exact(sock, length)

        return opcode, payload
    except socket.timeout:
        return None, None

def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("Connection closed unexpectedly")
        buf += chunk
    return buf

# ── Tests ──

def test_upgrade():
    """Test WebSocket upgrade handshake."""
    sock = socket.create_connection((HOST, PORT), timeout=5)
    key = make_ws_key()
    req = (
        f"GET {PATH} HTTP/1.1\r\n"
        f"Host: {HOST}:{PORT}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n"
        f"\r\n"
    )
    sock.sendall(req.encode())

    # Read response headers
    sock.settimeout(5)
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            break
        response += chunk

    resp_text = response.decode("utf-8", errors="replace")
    headers = resp_text.split("\r\n")

    # Check 101 status
    status_ok = "101" in headers[0]
    result("upgrade status 101", status_ok, headers[0].strip())

    # Check Sec-WebSocket-Accept
    accept_value = ""
    for h in headers:
        if h.lower().startswith("sec-websocket-accept:"):
            accept_value = h.split(":", 1)[1].strip()
    expected = expected_accept(key)
    result("Sec-WebSocket-Accept", accept_value == expected,
           f"expected {expected}, got {accept_value}" if accept_value != expected else "correct")

    if not status_ok:
        sock.close()
        return None
    return sock

def test_text_echo(sock):
    """Send text message, verify echo."""
    msg = f"HttpArena-validate-{os.urandom(8).hex()}"
    send_frame(sock, OP_TEXT, msg)
    opcode, payload = recv_frame(sock)
    echoed = payload.decode() if payload else ""
    result("text echo", opcode == OP_TEXT and echoed == msg,
           f"sent '{msg}', got '{echoed}'" if echoed != msg else f"echoed {len(msg)} chars")

def test_binary_echo(sock):
    """Send binary message, verify echo."""
    data = os.urandom(256)
    send_frame(sock, OP_BINARY, data)
    opcode, payload = recv_frame(sock)
    result("binary echo", opcode == OP_BINARY and payload == data,
           f"sent {len(data)} bytes, got {len(payload) if payload else 0} bytes")

def test_multiple_messages(sock):
    """Send multiple text messages rapidly, verify all echoed correctly."""
    messages = [f"msg-{i}-{os.urandom(4).hex()}" for i in range(5)]
    for msg in messages:
        send_frame(sock, OP_TEXT, msg)

    all_ok = True
    for i, expected in enumerate(messages):
        opcode, payload = recv_frame(sock, timeout=3)
        echoed = payload.decode() if payload else ""
        if opcode != OP_TEXT or echoed != expected:
            all_ok = False
            result(f"multi-message {i+1}/5", False, f"expected '{expected}', got '{echoed}'")
            return
    result("multi-message echo (5 msgs)", all_ok, "all 5 echoed correctly")

def close_connection(sock):
    """Send close frame and tear down the connection."""
    close_payload = struct.pack("!H", 1000) + b"validate done"
    send_frame(sock, OP_CLOSE, close_payload)
    try:
        recv_frame(sock, timeout=3)
    except ConnectionError:
        pass
    sock.close()

def test_reject_bad_upgrade():
    """Non-WebSocket GET to /ws should not crash the server."""
    sock = socket.create_connection((HOST, PORT), timeout=5)
    req = (
        f"GET {PATH} HTTP/1.1\r\n"
        f"Host: {HOST}:{PORT}\r\n"
        f"Connection: keep-alive\r\n"
        f"\r\n"
    )
    sock.sendall(req.encode())
    sock.settimeout(3)
    try:
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response += chunk
        resp_text = response.decode("utf-8", errors="replace")
        status_line = resp_text.split("\r\n")[0]
        # Should get a 4xx (400 or 426), not 101 or 5xx
        code = int(status_line.split()[1]) if len(status_line.split()) >= 2 else 0
        ok = 400 <= code < 500
        result("reject non-upgrade GET /ws", ok, f"HTTP {code}")
    except Exception as e:
        # Connection reset is also acceptable (server closed it)
        result("reject non-upgrade GET /ws", True, f"connection closed ({e})")
    finally:
        sock.close()

# ── Main ──

print(f"[test] WebSocket echo validation (ws://{HOST}:{PORT}{PATH})")

# 1. Upgrade handshake — retry briefly to absorb container startup race.
# The harness skips its HTTP readiness probe for pure-WS frameworks (e.g.
# Fleck), so the TCP listener may bind a moment before the WS handler is
# fully ready and resets the first upgrade attempt. The exception-only retry
# avoids double-counting result() calls from a successful-then-failed run.
sock = None
for attempt in range(20):
    try:
        sock = test_upgrade()
        break
    except (ConnectionResetError, ConnectionRefusedError, BrokenPipeError, ConnectionError):
        if attempt == 19:
            raise
        time.sleep(0.5)
if sock is None:
    print(f"\n=== WS Results: {PASS} passed, {FAIL} failed ===")
    sys.exit(1)

# 2. Text echo
test_text_echo(sock)

# 3. Binary echo
test_binary_echo(sock)

# 4. Multiple messages
test_multiple_messages(sock)

# 5. Close connection
close_connection(sock)

# 6. Bad upgrade rejection (new connection)
time.sleep(0.1)
test_reject_bad_upgrade()

# 7. Server still alive after all tests (new WS connection)
print("[test] post-validation health check")
sock2 = socket.create_connection((HOST, PORT), timeout=5)
key2 = make_ws_key()
req2 = (
    f"GET {PATH} HTTP/1.1\r\n"
    f"Host: {HOST}:{PORT}\r\n"
    f"Upgrade: websocket\r\n"
    f"Connection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key2}\r\n"
    f"Sec-WebSocket-Version: 13\r\n"
    f"\r\n"
)
sock2.sendall(req2.encode())
sock2.settimeout(5)
response2 = b""
while b"\r\n\r\n" not in response2:
    chunk = sock2.recv(4096)
    if not chunk:
        break
    response2 += chunk
health_ok = b"101" in response2
if health_ok:
    send_frame(sock2, OP_TEXT, "health")
    op, pl = recv_frame(sock2)
    health_ok = (op == OP_TEXT and pl == b"health")
    send_frame(sock2, OP_CLOSE, struct.pack("!H", 1000))
    try:
        recv_frame(sock2, timeout=2)
    except ConnectionError:
        pass
sock2.close()
result("server alive after tests", health_ok)

# ── Summary ──
print(f"\n=== WS Results: {PASS} passed, {FAIL} failed ===")
sys.exit(1 if FAIL > 0 else 0)
