#!/usr/bin/env python3
"""Run gcannon --rate for a held-connection profile; report a fixed-rate summary.

connections-5m holds five million keep-alive connections and paces requests
across them, connections-1m-tls a million over TLS 1.3. connections-ramp-h1
opens two million over two minutes instead, 95% of them idle, and this wrapper
reads from gcannon's interval timeline how many it took to push the active
ones' p99 over the limit (--ramp-p99-us). gcannon does the load
itself (gcannon >= 0.8.2: --rate, --addr-span, --connect-limit, --settle,
--warmup-max) in one process: ~3.3 KiB a connection, against the ~303 KiB that
sank the first million-connection attempt with zrk 2.3.0. (connections-1m
runs a million on zrk 3.0.2, ~41 KiB a connection, through
scripts/zrk_fanout.py.) What this wrapper adds is what gcannon cannot know
about the server or the host:

  - a listener on every address. The fleet is spread over 127.0.0.1-.160
    (.32 for the million over TLS; one source address holds ~64.5K
    connections to one destination), so a
    server bound to 127.0.0.1 or localhost refuses most of it. Probed first,
    and reported as an error rather than millions of connect failures.
  - memory. The run is refused when the client, the kernel's share and what
    the server may still grow into do not fit in MemAvailable: the first
    million-connection run took the bench host down.
  - open files. Five million sockets need RLIMIT_NOFILE above five million,
    usually past the hard limit the runner was started with; it is raised
    with `sudo -n prlimit` when it has to be (fs.nr_open, the ceiling, is
    raised by system_tune_held_connections).
  - the server's CPU over exactly the measured window. gcannon prints
    "gcannon: warmup done" when its window opens and "gcannon: measurement
    done" when it closes, while every connection is still up; the server
    cgroup's usage_usec is read at each, so neither the connects nor the
    million closes afterwards are in the figure.

stdout is one JSON object in the shape scripts/lib/tools/gcannon.sh's
held-connection parser reads (rps, latency, status classes, rate_ratio, the
window CPU, connections still open). Usage:

    conn_hold.py --profile connections-5m --conns N --rate R --port P
                 --probe 127.0.0.2,127.0.0.160 [--span 127.0.0.1-127.0.0.160]
                 [--cpu-stat FILE] [--server-mem 128g] [--kib-per-conn 4]
                 [--kernel-kib-per-conn 8] [--ramp-p99-us 2000]
                 -- <gcannon command prefix...> --args-- <gcannon arguments...>
"""

from __future__ import annotations

import argparse
import json
import os
import resource
import socket
import subprocess
import sys
import threading

# 0.8.0 has --rate, but scheduled each thread's connections inside one 1/T
# slice of the interval, so one thread at a time sent the whole fleet's rate:
# at a million connections every send ran ~150 ms late and that is what the
# latency figures measured (MDA2AV/gcannon#30). 0.8.2 adds --settle, the
# steady-state pause between the connect phase and the window (gcannon#31).
MIN_VERSION = (0, 8, 2)
# Not required, but 0.8.3 closes its own connections before it exits (gcannon#32).
# Earlier ones leave the fleet for the kernel to close, one socket at a time,
# and the harness waits that out between runs (system.sh, held_conn_drain).
CLOSES_ITSELF = (0, 8, 3)
# Over https://, 0.8.4 counts a connection against --connect-limit until its
# handshake is done (gcannon#33). Before, it let the handshakes pile up at the
# server past its handshake timeout, which closed them mid-handshake: a fleet
# that never finished connecting.
MIN_VERSION_TLS = (0, 8, 4)
# connections-ramp-h1 is driven by --ramp-up and --idle, and read off the
# interval lines they print (gcannon#35).
MIN_VERSION_RAMP = (0, 10, 0)
# An interval's rate has to reach this share of what was offered, or the p99
# next to it describes a server that is not keeping up (or one that has
# answered nothing at all, and has no p99).
RAMP_RATE_SHARE = 0.9


def log(msg: str) -> None:
    print(f"[conn-hold] {msg}", file=sys.stderr, flush=True)


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
    if not s:
        return 0
    s = s.strip().lower()
    mult = {"k": 1, "m": 1024, "g": 1024 ** 2, "t": 1024 ** 3}
    try:
        return int(float(s[:-1]) * mult[s[-1]]) if s[-1] in mult else int(s) // 1024
    except ValueError:
        return 0


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


def _probe(addr: str, port: int) -> str | None:
    try:
        with socket.create_connection((addr, port), timeout=3):
            return None
    except OSError as e:
        return f"{type(e).__name__}: {e}"


def _version(prefix: list[str]) -> tuple[int, ...] | None:
    try:
        out = subprocess.run(prefix + ["--version"], capture_output=True, text=True,
                             timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    for tok in out.split():
        parts = tok.lstrip("v").split(".")
        if len(parts) == 3 and all(p.isdigit() for p in parts):
            return tuple(int(p) for p in parts)
    return None   # an old gcannon has no --version and prints usage instead


def _raise_nofile(want: int) -> str | None:
    """Give this process (and so gcannon, which inherits it) `want` open files.

    Raising the soft limit up to the hard one needs no privilege. Past the
    hard limit - five million sockets are usually past whatever the runner was
    started with - only root can raise it, and setrlimit has no sudo, so
    prlimit(1) raises it for this pid from outside. fs.nr_open caps both.
    Returns why it could not, or None."""
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    if soft >= want:
        return None
    if hard < want:
        try:
            subprocess.run(["sudo", "-n", "prlimit", "--pid", str(os.getpid()),
                            f"--nofile={want}:{want}"], capture_output=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            pass
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, (min(want, hard), hard))
    except (ValueError, OSError):
        pass
    soft = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
    if soft >= want:
        return None
    try:
        nr_open = int(open("/proc/sys/fs/nr_open").read())
    except (OSError, ValueError):
        nr_open = 0
    return (f"the open-file limit is {soft} (hard {hard}, fs.nr_open {nr_open}), below the "
            f"{want} these connections need; `sudo -n prlimit` could not raise it. Raise the "
            "runner's hard limit (LimitNOFILE= in its systemd unit, or limits.conf) and "
            "fs.nr_open")


def ramp_summary(args, g: dict) -> tuple[dict | None, str | None]:
    """How far the ramp got before the active connections' p99 went over the
    limit, from gcannon's timeline (one row per interval). Returns (summary,
    None) or (None, why not).

    The row that counts is the last one before the limit is crossed. A crossing
    is an interval over the limit - its p99, or its rate short of what was
    offered, which is also how a server that stopped answering reads - with the
    one after it over too, or with nothing after it: one noisy interval on its
    own is not the end of a ramp. `reached` is every connection opened by then,
    idle ones included, whether or not the server has closed some since;
    `connections_open` is how many of them were open at that moment."""
    rows = g.get("timeline") or []
    if not rows:
        return None, "no interval timeline in gcannon's summary"

    def over(r: dict) -> str:
        if (r.get("rps") or 0) < RAMP_RATE_SHARE * args.rate:
            return "rate"
        if (r.get("p99_us") or 0) > args.ramp_p99_us:
            return "p99"
        return ""

    reached = open_now = idle_closed = 0
    stop, crossed = "ceiling", None
    for i, r in enumerate(rows):
        why = over(r)
        if why and (i + 1 == len(rows) or over(rows[i + 1])):
            stop, crossed = why, r
            break
        if why:
            continue   # one interval on its own
        # opened so far: the active connections open now, and every idle one
        # ever opened (the timeline has no idle_* keys without --idle)
        reached = (r.get("active") or 0) + (r.get("idle_opened") or 0)
        open_now = (r.get("active") or 0) + (r.get("idle_open") or 0)
        idle_closed = r.get("idle_closed") or 0
    out = {"reached": reached, "connections_open": open_now, "stop": stop,
           "idle_closed": idle_closed, "p99_limit_us": args.ramp_p99_us,
           "intervals": len(rows)}
    if crossed is not None:
        out["stop_t"] = crossed.get("t")
        out["stop_p99_us"] = crossed.get("p99_us")
        out["stop_rps"] = crossed.get("rps")
    return out, None


def _error(args, msg: str) -> dict:
    log(msg)
    return {"hold_error": msg, "connections": args.conns, "target_rate": args.rate,
            "rps": 0, "rate_ratio": 0, "duration_s": 0, "latency_us": {},
            "status_codes": {}, "errors": {}, "connections_open": None,
            "server_cpu_usec": None}


def run(args, prefix: list[str], gargs: list[str]) -> dict:
    ver = _version(prefix)
    tls = bool(gargs) and gargs[0].startswith("https://")
    ramp = args.ramp_p99_us > 0
    need = MIN_VERSION_RAMP if ramp else MIN_VERSION_TLS if tls else MIN_VERSION
    if ver is None or ver < need:
        # prefix[-1] is the image or the binary: which gcannon was asked
        why = ("--ramp-up, --idle and the interval lines" if ramp else
               "--connect-limit held through the TLS handshake" if tls else
               "--settle, and --rate with every thread spread over the whole interval")
        return _error(args, "%s needs gcannon >= %s (%s); %s %s"
                      % (args.profile, ".".join(map(str, need)), why, prefix[-1],
                         "is " + ".".join(map(str, ver)) if ver else
                         "did not answer --version (an older gcannon, or an image that did not build)"))

    if ver < CLOSES_ITSELF:
        log(f"gcannon {'.'.join(map(str, ver))} leaves its {args.conns} connections for the "
            "kernel to close after it exits, one at a time; the next run waits for that. "
            f"{'.'.join(map(str, CLOSES_ITSELF))} closes them itself")

    for addr in [a for a in args.probe.split(",") if a]:
        err = _probe(addr, args.port)
        if err:
            return _error(args, f"no listener reachable on {addr}:{args.port} ({err}): "
                          f"{args.profile} spreads its connections over {args.span}, "
                          "so the server must listen on 0.0.0.0 or [::], not 127.0.0.1 or "
                          "localhost alone")

    avail = _mem_available_kib()
    server_kib = _size_kib(args.server_mem)
    # What the server already holds is missing from MemAvailable and inside its
    # cap both, so only what it may still grow by is counted; otherwise a
    # server still warm from an earlier run is counted twice.
    server_now = _cgroup_mem_kib(args.cpu_stat)
    need = (args.conns * (args.kib_per_conn + args.kernel_kib_per_conn)
            + max(server_kib - server_now, 0))
    gib = 1024 ** 2
    budget = (f"the client ~{args.conns * args.kib_per_conn / gib:.1f} GiB, the kernel "
              f"~{args.conns * args.kernel_kib_per_conn / gib:.1f} GiB, and the server, at "
              f"{server_now / gib:.1f} GiB now, may grow to {server_kib / gib:.0f} GiB")
    if avail is not None and need > avail * 0.9:
        return _error(args, f"not enough memory to hold {args.conns} connections: {budget}, "
                      f"against {avail / gib:.0f} GiB available")
    if avail is not None:
        log(f"memory: {budget}; {avail / gib:.0f} GiB available")

    native = not any(os.path.basename(p) == "docker" for p in prefix)
    if native:
        want = args.conns + 4096
        err = _raise_nofile(want)
        if err:
            return _error(args, err)

    cpu = {}
    proc = subprocess.Popen(prefix + gargs, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            stdin=subprocess.DEVNULL, text=True)

    def watch_stderr():
        assert proc.stderr is not None
        for line in proc.stderr:
            sys.stderr.write(line)
            if line.startswith("gcannon: warmup done"):
                cpu["start"] = _cpu_usec(args.cpu_stat)
            elif line.startswith("gcannon: measurement done"):
                cpu["end"] = _cpu_usec(args.cpu_stat)
        sys.stderr.flush()

    t = threading.Thread(target=watch_stderr, daemon=True)
    t.start()
    # Not communicate(): it reads stderr too, and would race the thread for
    # the markers (the "measurement done" line went missing that way).
    assert proc.stdout is not None
    out = proc.stdout.read()
    proc.wait()
    t.join(timeout=10)

    start, end = out.find("{"), out.rfind("}")
    try:
        g = json.loads(out[start:end + 1])
    except ValueError:
        return _error(args, f"gcannon exited {proc.returncode} without a JSON summary: "
                      f"{out.strip()[:300] or '<no output>'}")

    el = g.get("elapsed_sec") or 0
    st = g.get("status") or {}
    ok = st.get("2xx") or 0
    rps = ok / el if el else 0
    lat = g.get("latency_us") or {}
    rate = g.get("rate") or {}
    cpu_win = (cpu["end"] - cpu["start"]) if cpu.get("start") is not None \
        and cpu.get("end") is not None and cpu["end"] >= cpu["start"] else None
    if g.get("connections_active") is not None:
        log(f"{g['connections_active']} of {args.conns} connections open at the end of the window")
    summary = {
        "connections": args.conns,
        "connections_open": g.get("connections_active"),
        "target_rate": args.rate,
        "rps": round(rps, 2),
        "rate_ratio": round(rps / args.rate, 4) if args.rate else 0,
        "duration_s": el,
        "bytes_per_sec": g.get("bandwidth_bps") or 0,
        "max_schedule_lag_us": rate.get("max_lag_us") or 0,
        "latency_us": {"mean": lat.get("avg"), "p50": lat.get("p50"), "p90": lat.get("p90"),
                       "p99": lat.get("p99"), "p99_9": lat.get("p999")},
        "status_codes": {k: st.get(k) or 0 for k in ("2xx", "3xx", "4xx", "5xx")},
        "errors": g.get("errors") or {},
        "reconnects": g.get("reconnects") or 0,
        "server_cpu_usec": cpu_win,
        "gcannon": g,
    }
    if ramp:
        found, why = ramp_summary(args, g)
        if found is None:
            return _error(args, why or "no ramp in gcannon's summary")
        log("reached %d connections (%d open) within %.1f ms p99; stopped by %s%s"
            % (found["reached"], found["connections_open"], args.ramp_p99_us / 1000,
               found["stop"], "" if found["stop"] == "ceiling"
               else " at %.0f s (p99 %.2f ms, %.0f req/s)"
               % (found.get("stop_t") or 0, (found.get("stop_p99_us") or 0) / 1000,
                  found.get("stop_rps") or 0)))
        summary["ramp"] = found
        summary["connections_open"] = found["connections_open"]
    return summary


def main(argv: list[str]) -> int:
    if "--" not in argv or "--args--" not in argv:
        print(__doc__, file=sys.stderr)
        return 2
    i, j = argv.index("--"), argv.index("--args--")
    ap = argparse.ArgumentParser()
    ap.add_argument("--conns", type=int, required=True)
    ap.add_argument("--rate", type=int, required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--probe", default="")
    ap.add_argument("--cpu-stat", dest="cpu_stat")
    ap.add_argument("--server-mem", dest="server_mem")
    ap.add_argument("--kib-per-conn", dest="kib_per_conn", type=int, default=4,
                    help="gcannon's memory per connection in KiB (~3.3 measured)")
    ap.add_argument("--kernel-kib-per-conn", dest="kernel_kib_per_conn", type=int, default=8,
                    help="kernel memory per connection: both sockets and a conntrack "
                         "entry, plus kernel TLS state over TLS")
    ap.add_argument("--profile", default="connections-5m", help="for messages")
    ap.add_argument("--span", default="127.0.0.1-127.0.0.160",
                    help="the addresses the fleet is spread over, for messages")
    ap.add_argument("--ramp-p99-us", dest="ramp_p99_us", type=int, default=0,
                    help="connections-ramp-h1: the p99 limit (microseconds) the ramp is "
                         "read against; 0 = not a ramp")
    args = ap.parse_args(argv[:i])
    print(json.dumps(run(args, argv[i + 1:j], argv[j + 1:]), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
