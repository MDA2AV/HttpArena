#!/usr/bin/env python3
"""Rendezvous validation for HttpArena: GET /rendezvous/{key}?v={value}.

The first request for a key waits, the second completes both, and each is answered
with the other's value. The benchmark's generator reads none of that back, so this is
the whole anti-cheat: a server that answers without waiting, or that pairs requests by
anything but the key, has to fail here.

Zero-dependency HTTP/1.1 client on raw asyncio streams. Keys and values are drawn fresh
on every run, so nothing can be prepared for them.

Usage: python3 validate-rendezvous.py [host] [port]
  Defaults: localhost 8080
  Exit code 0 = all passed, 1 = failures
"""

import asyncio
import random
import secrets
import string
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "localhost"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8080

# A lone request has to still be waiting after this long. The profile's own waits are
# microseconds, so anything answered before this did not wait for its partner.
HOLD_SECONDS = 0.4
# How long a completed pair may take. Generous: this is a correctness check on a
# possibly small hosted runner, not a performance one.
REPLY_TIMEOUT = 15.0
# Enough connections at once that they spread across every worker a server runs, so a
# per-worker map loses most of its pairs rather than passing by luck.
MANY_PAIRS = 256

PASS = 0
FAIL = 0


def result(label, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  PASS [{label}]{' (' + detail + ')' if detail else ''}")
    else:
        FAIL += 1
        print(f"  FAIL [{label}]{': ' + detail if detail else ''}")


def token(n=16):
    return "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(n))


class Conn:
    """One keep-alive connection, so a test can issue several requests on it."""

    async def open(self):
        self.reader, self.writer = await asyncio.open_connection(HOST, PORT)
        return self

    def send(self, key, value):
        self.writer.write(
            f"GET /rendezvous/{key}?v={value} HTTP/1.1\r\n"
            f"Host: {HOST}:{PORT}\r\n\r\n".encode()
        )

    async def recv(self):
        """Read one response. Returns (status, content-type, body)."""
        head = await self.reader.readuntil(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        status = int(lines[0].split(" ")[1])
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                name, val = line.split(":", 1)
                headers[name.strip().lower()] = val.strip()
        if headers.get("transfer-encoding", "").lower() == "chunked":
            body = b""
            while True:
                size = int((await self.reader.readline()).strip().split(b";")[0], 16)
                if size == 0:
                    await self.reader.readline()
                    break
                body += await self.reader.readexactly(size)
                await self.reader.readexactly(2)
        else:
            body = await self.reader.readexactly(int(headers.get("content-length", "0")))
        return status, headers.get("content-type", ""), body.decode("latin-1")

    async def reply(self):
        return await asyncio.wait_for(self.recv(), REPLY_TIMEOUT)

    def close(self):
        self.writer.close()


async def exchange_values():
    """Each side of a pair gets the other's value, verbatim, as text/plain."""
    a, b = await Conn().open(), await Conn().open()
    key = token()
    # Lengths at both ends of what the contract allows, so nothing fixed-size passes.
    va, vb = token(1), token(32)
    a.send(key, va)
    await asyncio.sleep(0.05)
    b.send(key, vb)
    try:
        ra, rb = await asyncio.gather(a.reply(), b.reply())
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError, ValueError) as e:
        result("exchange", False, f"no complete answer: {type(e).__name__}")
        a.close(), b.close()
        return
    result("first request gets the second's value", ra[0] == 200 and ra[2] == vb,
           f"status {ra[0]}, expected {vb!r}, got {ra[2]!r}" if ra[2] != vb or ra[0] != 200 else "")
    result("second request gets the first's value", rb[0] == 200 and rb[2] == va,
           f"status {rb[0]}, expected {va!r}, got {rb[2]!r}" if rb[2] != va or rb[0] != 200 else "")
    result("Content-Type", "text/plain" in ra[1] and "text/plain" in rb[1], f"{ra[1]!r}, {rb[1]!r}")
    a.close(), b.close()


async def first_request_waits():
    """A request with no partner is not answered until one arrives."""
    a, b = await Conn().open(), await Conn().open()
    key, va, vb = token(), token(), token()
    a.send(key, va)
    pending = asyncio.ensure_future(a.recv())
    await asyncio.sleep(HOLD_SECONDS)
    held = not pending.done()
    result("a lone request waits", held,
           "" if held else f"answered within {HOLD_SECONDS}s with no second request")
    if not held:
        pending.cancel()
        a.close(), b.close()
        return
    started = time.monotonic()
    b.send(key, vb)
    try:
        ra, rb = await asyncio.wait_for(asyncio.gather(pending, b.recv()), REPLY_TIMEOUT)
        ok = ra[2] == vb and rb[2] == va
        result("the second request releases it", ok,
               f"{time.monotonic() - started:.3f}s" if ok else f"got {ra[2]!r} and {rb[2]!r}")
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError, ValueError) as e:
        result("the second request releases it", False, f"no answer: {type(e).__name__}")
    a.close(), b.close()


async def many_pairs_at_once():
    """Hundreds of keys in flight together: every side gets its own partner's value."""
    conns = await asyncio.gather(*(Conn().open() for _ in range(MANY_PAIRS * 2)))
    sends = []
    for i in range(MANY_PAIRS):
        key = token()
        sends.append((conns[2 * i], key, token(), conns[2 * i + 1]))
    # One side of every pair first, in random order, then all the others, so every pair
    # is split in time as well as across connections.
    random.shuffle(sends)
    expected = {}
    for first, key, value, partner in sends:
        first.send(key, value)
        expected[first] = (key, value, partner)
    await asyncio.sleep(0.1)
    values = {}
    random.shuffle(sends)
    for first, key, value, partner in sends:
        pv = token()
        values[partner] = pv
        partner.send(key, pv)

    want = {}
    for first, (key, value, partner) in expected.items():
        want[first] = values[partner]
        want[partner] = value

    async def one(conn):
        try:
            return (await conn.reply())[2] == want[conn]
        except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError, ValueError):
            return None

    outcomes = await asyncio.gather(*(one(c) for c in conns))
    wrong = sum(1 for o in outcomes if o is False)
    missing = sum(1 for o in outcomes if o is None)
    result(f"{MANY_PAIRS} pairs at once", wrong == 0 and missing == 0,
           f"{wrong} got someone else's value, {missing} never answered"
           if wrong or missing else "every side got its partner's value")
    for c in conns:
        c.close()


async def keep_alive_and_key_reuse():
    """Connections stay usable, and a key is free again once its pair has completed."""
    a, b = await Conn().open(), await Conn().open()
    key = token()
    ok = True
    detail = ""
    for round_no in range(20):
        va, vb = token(), token()
        a.send(key, va)
        await asyncio.sleep(0)
        b.send(key, vb)
        try:
            ra, rb = await asyncio.gather(a.reply(), b.reply())
        except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError, ValueError) as e:
            ok, detail = False, f"round {round_no}: no answer: {type(e).__name__}"
            break
        if ra[2] != vb or rb[2] != va:
            ok, detail = False, f"round {round_no}: stale values {ra[2]!r}, {rb[2]!r}"
            break
    result("same key, same connections, 20 rounds", ok, detail)
    a.close(), b.close()


async def disconnected_waiter():
    """A client that leaves while it waits must not take the server down with it."""
    gone = await Conn().open()
    gone.send(token(), token())
    await asyncio.sleep(0.05)
    gone.close()
    await asyncio.sleep(0.1)

    a, b = await Conn().open(), await Conn().open()
    key, va, vb = token(), token(), token()
    a.send(key, va)
    b.send(key, vb)
    try:
        ra, rb = await asyncio.gather(a.reply(), b.reply())
        ok = ra[2] == vb and rb[2] == va
        result("still serving after a waiter disconnects", ok, "" if ok else f"got {ra[2]!r}, {rb[2]!r}")
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError, ValueError) as e:
        result("still serving after a waiter disconnects", False, type(e).__name__)
    a.close(), b.close()


async def main():
    for test in (exchange_values, first_request_waits, many_pairs_at_once,
                 keep_alive_and_key_reuse, disconnected_waiter):
        try:
            await test()
        except OSError as e:
            result(test.__name__, False, f"could not connect: {e}")


if __name__ == "__main__":
    asyncio.run(main())
    print(f"  {PASS} passed, {FAIL} failed")
    sys.exit(1 if FAIL else 0)
