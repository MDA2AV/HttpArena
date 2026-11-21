#!/usr/bin/env python3
"""Fan one zrk run out over many loopback addresses and merge the results.

connections-1m is connections-1m (a million keep-alive connections, 250K
req/s paced across them) with zrk as the load generator instead of gcannon,
so the two generators can be compared on the same load. It needs zrk >= 3.0.2:
2.3.0 kept a 272 KiB latency histogram per connection, ~303 KiB resident in
all, and the first million-connection run with it took the bench host down.
3.0.2 shares one histogram per thread; measured at 4K and 16K connections it
keeps ~41 KiB a connection (buffers and coroutine stacks), ~40 GiB for the
million.

The kernel tells TCP connections apart by source address and port plus
destination address and port, so one source address can hold at most one
connection per local port to a given destination: about 64K on the bench host
(ip_local_port_range 1024-65535, less the reserved ports). That is the ceiling
the async profile's comment in scripts/lib/profiles.sh runs into.

Every 127.x.y.z address is local on Linux, so the fleet is spread over
127.0.0.1 .. 127.0.0.K instead: one zrk process per address, each holding
conns/K connections at rate/K, and each destination address brings its own
64K ports. The server has to accept on all of them, which a listener on
0.0.0.0 or [::] does. One bound to 127.0.0.1 alone refuses the rest, and the
probe below says so before anything is launched.

Measuring the steady state only. zrk opens all of its connections the moment
it starts, so the processes are launched `stagger` seconds apart, and the
`settle` seconds after the last launch are discarded too. What is reported is
the `window` that follows, with the whole fleet connected. Each process streams
one NDJSON row per second (--timeseries) carrying that second's full latency
histogram (--timeseries-histogram). The rows inside the window are merged
exactly, bucket by bucket, and the percentiles are read off the merged
histogram: averaging per-process percentiles would not be a percentile of
anything.

Output: one JSON object on stdout with the keys of zrk's own --format json
summary that zrk_parse reads (achieved_rate, latency_us, status_codes, errors,
rate_ratio, duration_s, target_rate, max_schedule_lag_us, bytes_per_sec), and:

    connections          offered connection count
    launched             connections the zrk processes report launching
    connections_open     server-side ESTABLISHED sockets on the port, counted
                         with ss(8) right after the window
    server_cpu_usec      the server cgroup's CPU over the window, or null
    ramp_connect_errors  connect failures outside the window (the ramp)
    fanout               how the run was split and timed, per process
    hold_error           set, with every count zero, when the run could not
                         start (the key scripts/conn_hold.py uses too)

status_codes 2xx counts the window, like every other figure here. 4xx and 5xx
count the whole run, ramp included: a non-2xx anywhere is worth seeing.

Usage (scripts/lib/tools/zrk.sh calls it):

    zrk_fanout.py --conns N --rate R --addrs K --port P --path /x --threads T
                  [--stagger S] [--settle Z] [--window W] [--tail E]
                  [--cpu-stat FILE] [--ss-cpus LIST] [--min-version 3.0.2]
                  -- <zrk command...>
"""

from __future__ import annotations

import argparse
import base64
import json
import math
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib

# ── HdrHistogram V2, as zrk writes it (src/hdr.zig) ─────────────────────────
#
# zrk records microseconds at 3 significant figures between 1us and 60s. The
# functions below mirror its index arithmetic and its reporting conventions
# exactly -- a percentile is the median-equivalent value of the bucket holding
# the rank round(p/100 * total), the mean weights each bucket's median-
# equivalent value, max is the highest-equivalent value of the top bucket -- so
# the merged figures are the ones zrk would print had one process seen
# everything. tests: decoding a summary's own latency_histogram reproduces the
# latency_us block printed next to it.

_COMPRESSED_BASE = 0x1C849304
_ENCODING_BASE = 0x1C849303
_COOKIE_MASK = 0xFFFFFF0F  # zrk masks the word-size nibble: ~0xf0 as a u32


class Layout:
    def __init__(self, lowest: int, highest: int, sig_figs: int):
        self.key = (lowest, highest, sig_figs)
        largest_single_unit = 2 * 10 ** sig_figs
        sub_bucket_count_magnitude = (largest_single_unit - 1).bit_length()  # ceil(log2)
        self.half_mag = max(sub_bucket_count_magnitude - 1, 0)
        self.unit_mag = lowest.bit_length() - 1  # floor(log2)
        sub_bucket_count = 1 << (self.half_mag + 1)
        self.half_count = sub_bucket_count // 2
        self.mask = (sub_bucket_count - 1) << self.unit_mag

    def value_from_index(self, i: int) -> int:
        bucket = (i >> self.half_mag) - 1
        sub = (i & (self.half_count - 1)) + self.half_count
        if bucket < 0:
            sub -= self.half_count
            bucket = 0
        return sub << (bucket + self.unit_mag)

    def _bucket(self, v: int) -> int:
        return (v | self.mask).bit_length() - self.unit_mag - (self.half_mag + 1)

    def _lowest_equiv(self, v: int) -> int:
        b = self._bucket(v)
        return (v >> (b + self.unit_mag)) << (b + self.unit_mag)

    def _size(self, v: int) -> int:
        return 1 << (self._bucket(v) + self.unit_mag)

    def median_equiv(self, v: int) -> int:
        return self._lowest_equiv(v) + (self._size(v) >> 1)

    def highest_equiv(self, v: int) -> int:
        return self._lowest_equiv(v) + self._size(v) - 1


def _read_zigzag(buf: bytes, pos: int) -> tuple[int, int]:
    value = shift = 0
    for i in range(9):
        b = buf[pos]
        pos += 1
        if i == 8:  # the 9th byte carries the top 8 bits whole
            value |= b << 56
            break
        value |= (b & 0x7F) << shift
        if not b & 0x80:
            break
        shift += 7
    return (value >> 1) ^ -(value & 1), pos


def decode_histogram(b64: str) -> tuple[Layout, list[int]]:
    raw = base64.b64decode(b64)
    cookie, zlen = struct.unpack(">II", raw[:8])
    if cookie & _COOKIE_MASK != _COMPRESSED_BASE:
        raise ValueError("not an HdrHistogram V2 compressed histogram")
    enc = zlib.decompress(raw[8:8 + zlen])
    cookie, plen, _offset, sig, lowest, highest, _ratio = struct.unpack(">IIIIQQd", enc[:40])
    if cookie & _COOKIE_MASK != _ENCODING_BASE:
        raise ValueError("bad HdrHistogram V2 encoding cookie")
    payload = enc[40:40 + plen]
    counts: list[int] = []
    pos = 0
    while pos < len(payload):
        v, pos = _read_zigzag(payload, pos)
        if v < 0:
            counts.extend([0] * -v)  # a run of zeros
        else:
            counts.append(v)
    return Layout(lowest, highest, sig), counts


class Merged:
    """Counts summed bucket by bucket across any number of decoded histograms."""

    def __init__(self):
        self.layout: Layout | None = None
        self.counts: list[int] = []

    def add(self, b64: str | None) -> None:
        if not b64:
            return
        layout, counts = decode_histogram(b64)
        if self.layout is None:
            self.layout = layout
        elif layout.key != self.layout.key:
            raise ValueError(f"histogram layouts differ: {layout.key} vs {self.layout.key}")
        if len(counts) > len(self.counts):
            self.counts.extend([0] * (len(counts) - len(self.counts)))
        for i, c in enumerate(counts):
            if c:
                self.counts[i] += c

    @property
    def total(self) -> int:
        return sum(self.counts)

    def percentile(self, p: float) -> int:
        total = self.total
        if not total or self.layout is None:
            return 0
        wanted = int(math.floor((p / 100.0) * total + 0.5))  # Zig @round: half away from zero
        wanted = max(wanted, 1)
        running = 0
        for i, c in enumerate(self.counts):
            running += c
            if running >= wanted:
                return self.layout.median_equiv(self.layout.value_from_index(i))
        return self.max()

    def mean(self) -> float:
        total = self.total
        if not total or self.layout is None:
            return 0.0
        acc = 0.0
        for i, c in enumerate(self.counts):
            if c:
                acc += float(self.layout.median_equiv(self.layout.value_from_index(i))) * c
        return acc / total

    def max(self) -> int:
        if self.layout is None:
            return 0
        for i in range(len(self.counts) - 1, -1, -1):
            if self.counts[i]:
                return self.layout.highest_equiv(self.layout.value_from_index(i))
        return 0

    def min(self) -> int:
        if self.layout is None:
            return 0
        for i, c in enumerate(self.counts):
            if c:
                return self.layout.value_from_index(i)
        return 0

    def latency_block(self) -> dict:
        return {
            "min": self.min(), "mean": round(self.mean(), 1), "max": self.max(),
            "p50": self.percentile(50), "p75": self.percentile(75),
            "p90": self.percentile(90), "p99": self.percentile(99),
            "p99_9": self.percentile(99.9), "p99_99": self.percentile(99.99),
        }


# ── Helpers ─────────────────────────────────────────────────────────────────

def _summary(text: str) -> dict | None:
    """zrk's final report, from a stream that may carry other output around it."""
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        return json.loads(text[start:end + 1])
    except json.JSONDecodeError:
        return None


def _rows(path: str) -> list[dict]:
    out = []
    try:
        with open(path, errors="replace") as f:
            for line in f:
                line = line.strip()
                if line.startswith("{"):
                    try:
                        out.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
    except OSError:
        pass
    return out


def _cgroup_mem_kib(cpu_stat: str | None) -> int:
    """The server cgroup's memory now, in KiB: memory.current, which sits next
    to the cpu.stat the caller passes. 0 when it cannot be read."""
    if not cpu_stat:
        return 0
    try:
        with open(os.path.join(os.path.dirname(cpu_stat), "memory.current")) as f:
            return int(f.read().strip()) // 1024
    except (OSError, ValueError):
        return 0


def _cpu_usec(path: str | None) -> int | None:
    if not path:
        return None
    try:
        with open(path) as f:
            for line in f:
                if line.startswith("usage_usec"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return None


def _count_established(port: int, cpus: str | None) -> int | None:
    """Server-side ESTABLISHED sockets on `port`, counted without buffering 1M lines."""
    if not shutil.which("ss"):
        return None
    cmd = ["ss", "-H", "-t", "-n", "state", "established", f"( sport = :{port} )"]
    if cpus and shutil.which("taskset"):
        cmd = ["taskset", "-c", cpus] + cmd
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return None
    n = 0
    deadline = time.monotonic() + 30
    assert p.stdout is not None
    while True:
        chunk = p.stdout.read(1 << 20)
        if not chunk:
            break
        n += chunk.count(b"\n")
        if time.monotonic() > deadline:
            p.kill()
            return None
    p.wait()
    return n if p.returncode == 0 else None


def _probe(addr: str, port: int) -> str | None:
    try:
        with socket.create_connection((addr, port), timeout=3):
            return None
    except OSError as e:
        return f"{type(e).__name__}: {e}"


def _split(total: int, parts: int) -> list[int]:
    base, extra = divmod(total, parts)
    return [base + (1 if i < extra else 0) for i in range(parts)]


def _name_containers(prefix: list[str], k: int, mem_mib: int = 0) -> list[str]:
    """Name each zrk container so the harness's cleanup sweeps it (httparena-*),
    and cap its memory so a client that outgrows its estimate is OOM-killed in
    its own cgroup instead of taking the host down with it."""
    for i in range(len(prefix) - 1):
        if os.path.basename(prefix[i]) == "docker" and prefix[i + 1] == "run":
            extra = ["--name", f"httparena-zrk-{k}"]
            if mem_mib > 0:
                extra += [f"--memory={mem_mib}m", f"--memory-swap={mem_mib}m"]
            return prefix[:i + 2] + extra + prefix[i + 2:]
    return prefix


def _version(prefix: list[str]) -> tuple[int, ...] | None:
    """What `zrk --version` says ("zrk 3.0.2"), through the same prefix the run
    uses, so a docker image is asked rather than whatever is on PATH."""
    try:
        out = subprocess.run(prefix + ["--version"], capture_output=True, text=True,
                             timeout=120).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    for tok in out.split():
        parts = tok.lstrip("v").split(".")
        if len(parts) == 3 and all(p.isdigit() for p in parts):
            return tuple(int(p) for p in parts)
    return None


def _empty(args, error: str) -> dict:
    return {
        "hold_error": error, "connections": args.conns, "launched": 0,
        "connections_open": None, "requests": 0, "achieved_rate": 0,
        "target_rate": args.rate, "rate_ratio": 0, "duration_s": 0,
        "bytes_per_sec": 0, "max_schedule_lag_us": 0, "server_cpu_usec": None,
        "latency_us": {}, "status_codes": {"1xx": 0, "2xx": 0, "3xx": 0, "4xx": 0, "5xx": 0},
        "errors": {"connect": 0}, "ramp_connect_errors": 0,
    }


def _mem_available_kib() -> int | None:
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return None


def _size_kib(s: str | None) -> int:
    """'96g' / '512m' / '1048576k' / bytes -> KiB; 0 when unset or unparseable."""
    if not s:
        return 0
    s = s.strip().lower()
    mult = {"k": 1, "m": 1024, "g": 1024 ** 2, "t": 1024 ** 3}
    try:
        if s[-1] in mult:
            return int(float(s[:-1]) * mult[s[-1]])
        return int(s) // 1024
    except ValueError:
        return 0


# Kernel memory per connection, both ends of it: two sockets with their file,
# dentry and epoll entries (~3.5 KiB each), plus a conntrack entry.
_KERNEL_KIB_PER_CONN = 8


def _sleep_until(t: float) -> None:
    d = t - time.monotonic()
    if d > 0:
        time.sleep(d)


def log(msg: str) -> None:
    print(f"[zrk-fanout] {msg}", file=sys.stderr, flush=True)


# ── The run ─────────────────────────────────────────────────────────────────

def run(args, prefix: list[str]) -> dict:
    K = args.addrs
    if not 1 <= K <= 254:
        return _empty(args, f"--addrs must be 1..254, got {K}")
    addrs = [f"127.0.0.{k + 1}" for k in range(K)]

    # 2.3.0, the version the other zrk profiles pin, would need ~290 GiB here.
    want = tuple(int(p) for p in args.min_version.split("."))
    ver = _version(prefix)
    if ver is None or ver < want:
        msg = ("connections-1m needs zrk >= %s (per-thread latency histograms); "
               "%s %s" % (args.min_version, prefix[-1],
                          "is " + ".".join(map(str, ver)) if ver else
                          "did not answer --version (not installed, or an image that did not build)"))
        log(msg)
        return _empty(args, msg)

    # A listener bound to 127.0.0.1 or "localhost" passes everything else in the
    # harness and refuses every address here but the first. Say that, rather
    # than launching a million connect errors that read like a broken server.
    for probe_addr in (addrs[1], addrs[-1]) if K > 1 else (addrs[0],):
        err = _probe(probe_addr, args.port)
        if err:
            msg = (f"no listener reachable on {probe_addr}:{args.port} ({err}). "
                   "connections-1m spreads its connections over 127.0.0.1-"
                   f"{addrs[-1]}, so the server must listen on 0.0.0.0 or [::], "
                   "not on 127.0.0.1 or localhost alone")
            log(msg)
            return _empty(args, msg)

    # Refuse what the host cannot hold. The first million-connection run on the
    # bench host took it down: zrk 2.3.0 keeps ~303 KiB resident per connection
    # (measured flat from 1K to 8K connections), so a million needed ~290 GiB
    # of a 251 GiB machine, with nothing capping it. 3.0.2 keeps ~41 KiB.
    # Count the client, the kernel's share and everything the server is still
    # allowed to grow into.
    avail = _mem_available_kib()
    server_kib = _size_kib(args.server_mem)
    # What the server already holds is out of MemAvailable and inside its cap
    # both: count only what it may still grow by.
    server_now = _cgroup_mem_kib(args.cpu_stat)
    need = (args.conns * (args.kib_per_conn + _KERNEL_KIB_PER_CONN)
            + max(server_kib - server_now, 0))
    if avail is not None and need > avail * 0.9:
        gib = 1024 ** 2
        msg = (f"not enough memory to hold {args.conns} connections: the load generator "
               f"needs ~{args.conns * args.kib_per_conn / gib:.0f} GiB at {args.kib_per_conn} KiB "
               f"per connection, the kernel ~{args.conns * _KERNEL_KIB_PER_CONN / gib:.0f} GiB, "
               f"and the server, at {server_now / gib:.1f} GiB now, may grow to "
               f"{server_kib / gib:.0f} GiB, against {avail / gib:.0f} GiB available. "
               "Refusing rather than running the host out of memory")
        log(msg)
        return _empty(args, msg)

    conns = _split(args.conns, K)
    rates = _split(args.rate, K)
    threads = max(1, args.threads // K)
    # Per-process cap: half again over the estimate, plus a fixed allowance.
    mem_cap_mib = int(conns[0] * args.kib_per_conn * 1.5 / 1024) + 512 if args.kib_per_conn else 0
    stagger, settle, window, tail = args.stagger, args.settle, args.window, args.tail
    w0 = (K - 1) * stagger + settle  # window start, seconds after the first launch
    total = w0 + window + tail
    log(f"{args.conns} connections at {args.rate} req/s over {K} addresses "
        f"({addrs[0]}-{addrs[-1]}): {conns[0]} conns, {rates[0]} req/s, {threads} threads each; "
        f"launches {stagger}s apart, window {w0}-{w0 + window}s, run {total}s")

    work = tempfile.mkdtemp(prefix="zrk-fanout-")
    procs: list[subprocess.Popen | None] = [None] * K
    launch = [0.0] * K
    ended = [None] * K
    files = []
    if any(os.path.basename(x) == "docker" for x in prefix):
        for k in range(K):  # a name left over from a crashed run would refuse the start
            subprocess.run(["docker", "rm", "-f", f"httparena-zrk-{k}"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t0 = time.monotonic()
    try:
        for k in range(K):
            _sleep_until(t0 + k * stagger)
            cmd = _name_containers(prefix, k, mem_cap_mib) + [
                "-t", str(threads), "-c", str(conns[k]), "-d", f"{total - k * stagger}s",
                "-R", str(rates[k]), "--interval", "1s",
                "--timeseries", "-", "--timeseries-histogram", "--format", "json",
                f"http://{addrs[k]}:{args.port}{args.path}",
            ]
            ts = open(os.path.join(work, f"ts{k}.ndjson"), "wb")
            rep = open(os.path.join(work, f"rep{k}.txt"), "wb")
            files += [ts, rep]
            launch[k] = time.monotonic() - t0
            try:
                procs[k] = subprocess.Popen(cmd, stdout=ts, stderr=rep, stdin=subprocess.DEVNULL)
            except OSError as e:
                log(f"process {k} ({addrs[k]}) did not start: {e}")

        _sleep_until(t0 + w0)
        cpu_a = _cpu_usec(args.cpu_stat)
        _sleep_until(t0 + w0 + window)
        cpu_b = _cpu_usec(args.cpu_stat)
        # Counted after the window rather than inside it: walking a million
        # sockets is kernel work the measurement should not carry.
        conns_open = _count_established(args.port, args.ss_cpus)

        deadline = t0 + total + 90
        while any(p is not None and ended[k] is None for k, p in enumerate(procs)):
            for k, p in enumerate(procs):
                if p is not None and ended[k] is None and p.poll() is not None:
                    ended[k] = time.monotonic() - t0
            if time.monotonic() > deadline:
                for k, p in enumerate(procs):
                    if p is not None and ended[k] is None:
                        log(f"process {k} ({addrs[k]}) overran; terminating")
                        p.terminate()
                        try:
                            p.wait(10)
                        except subprocess.TimeoutExpired:
                            p.kill()
                        ended[k] = time.monotonic() - t0
                break
            time.sleep(0.05)
    finally:
        for f in files:
            f.close()

    # ── Merge ───────────────────────────────────────────────────────────────
    hist = Merged()
    window_reqs = window_bytes = 0
    rate_sum = bps_sum = 0.0
    covered = []
    errs = {"connect": 0, "read": 0, "write": 0, "timeout": 0, "deadline": 0, "non_2xx_3xx": 0}
    run_connect = run_4xx = run_5xx = launched = 0
    lag = 0
    per = []
    for k in range(K):
        rep_text = open(os.path.join(work, f"rep{k}.txt"), errors="replace").read()
        summ = _summary(rep_text)
        rows = _rows(os.path.join(work, f"ts{k}.ndjson"))
        info = {"addr": addrs[k], "connections": conns[k], "rate": rates[k],
                "launched": None, "window_requests": 0, "window_s": 0.0}
        if summ is None:
            log(f"process {k} ({addrs[k]}) left no summary: {rep_text.strip()[:300] or '<empty>'}")
        else:
            info["launched"] = (summ.get("config") or {}).get("launched")
            launched += info["launched"] or 0
            run_connect += (summ.get("errors") or {}).get("connect") or 0
            codes = summ.get("status_codes") or {}
            run_4xx += codes.get("4xx") or 0
            run_5xx += codes.get("5xx") or 0
        # This process's clock started when zrk did, which is its launch plus
        # however long `docker run` took to get there. Its own elapsed time,
        # taken back from when it ended, places that start better than the
        # launch time alone; the slack either way is well inside settle/tail.
        start = launch[k]
        if summ and summ.get("duration_s") and ended[k] is not None:
            start = max(launch[k], ended[k] - float(summ["duration_s"]))
        lo, hi = w0 - start, w0 + window - start
        prev = 0.0
        cov = 0.0
        reqs = byts = 0
        for r in rows:
            t = float(r.get("t") or 0)
            interval = t - prev
            prev = t
            if t - interval < lo - 0.5 or t > hi + 0.5:
                continue
            cov += interval
            reqs += r.get("requests") or 0
            byts += r.get("bytes") or 0
            for kind, n in (r.get("errors_by_kind") or {}).items():
                if kind in errs:
                    errs[kind] += n or 0
            lag = max(lag, r.get("max_schedule_lag_us") or 0)
            hist.add(r.get("latency_histogram"))
        info["window_requests"], info["window_s"] = reqs, round(cov, 3)
        window_reqs += reqs
        window_bytes += byts
        if cov > 0:
            rate_sum += reqs / cov
            bps_sum += byts / cov
            covered.append(cov)
        per.append(info)

    shutil.rmtree(work, ignore_errors=True)

    if launched and launched < args.conns:
        log(f"only {launched} of {args.conns} connections were launched - "
            "zrk could not spawn the rest (vm.max_map_count, memory, or fds)")
    if conns_open is not None:
        log(f"{conns_open} established on :{args.port} after the window "
            f"({100.0 * conns_open / args.conns:.1f}% of {args.conns})")

    return {
        "fanout": {"processes": K, "addresses": f"{addrs[0]}-{addrs[-1]}",
                   "stagger_s": stagger, "settle_s": settle, "window_s": window,
                   "tail_s": tail, "threads_per_process": threads, "per_process": per},
        "connections": args.conns,
        "launched": launched,
        "connections_open": conns_open,
        "duration_s": round(sum(covered) / len(covered), 3) if covered else 0,
        "requests": window_reqs,
        "bytes": window_bytes,
        "achieved_rate": round(rate_sum, 2),
        "target_rate": args.rate,
        "rate_ratio": round(rate_sum / args.rate, 4) if args.rate else 0,
        "bytes_per_sec": round(bps_sum, 2),
        "max_schedule_lag_us": lag,
        "server_cpu_usec": (cpu_b - cpu_a) if cpu_a is not None and cpu_b is not None and cpu_b >= cpu_a else None,
        "latency_us": hist.latency_block(),
        "status_codes": {"1xx": 0, "2xx": max(window_reqs - errs["non_2xx_3xx"], 0), "3xx": 0,
                         "4xx": run_4xx, "5xx": run_5xx},
        "errors": errs,
        "ramp_connect_errors": max(run_connect - errs["connect"], 0),
    }


def main(argv: list[str]) -> int:
    if "--" not in argv:
        print("usage: zrk_fanout.py [options] -- <zrk command...>", file=sys.stderr)
        return 2
    i = argv.index("--")
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--conns", type=int, required=True)
    ap.add_argument("--rate", type=int, required=True)
    ap.add_argument("--addrs", type=int, required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--path", required=True)
    ap.add_argument("--threads", type=int, default=64)
    ap.add_argument("--stagger", type=int, default=1)
    ap.add_argument("--settle", type=int, default=10)
    ap.add_argument("--window", type=int, default=20)
    ap.add_argument("--tail", type=int, default=20)
    ap.add_argument("--cpu-stat", dest="cpu_stat")
    ap.add_argument("--ss-cpus", dest="ss_cpus")
    ap.add_argument("--kib-per-conn", dest="kib_per_conn", type=int, default=48,
                    help="client memory per connection in KiB (zrk 3.0.2: ~41 measured, "
                         "2.3.0: ~303)")
    ap.add_argument("--min-version", dest="min_version", default="3.0.2",
                    help="the oldest zrk the run accepts")
    ap.add_argument("--server-mem", dest="server_mem",
                    help="the server container's memory cap (e.g. 96g), counted as headroom")
    args = ap.parse_args(argv[:i])
    prefix = argv[i + 1:]
    if not prefix:
        print("zrk_fanout.py: no zrk command after --", file=sys.stderr)
        return 2
    print(json.dumps(run(args, prefix), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
