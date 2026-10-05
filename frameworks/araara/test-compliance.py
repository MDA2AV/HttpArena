#!/usr/bin/env python3
"""Check HttpArena responses and live static files over HTTP/2.

Run against an isolated benchmark container. --static-dir must be the writable
host directory mounted at /data/static in that container. Existing test files
are restored even on failure. Requires Python 3 and curl with HTTP/2 support.
"""

import argparse
import gzip
import json
import os
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import quote


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", nargs="?", default="https://localhost:8443")
    parser.add_argument("--static-dir", type=Path, required=True)
    parser.add_argument("--dataset", type=Path, required=True)
    args = parser.parse_args()
    passed = 0

    def check(condition, label):
        nonlocal passed
        if not condition:
            raise AssertionError(label)
        passed += 1
        print(f"PASS {label}", flush=True)

    with tempfile.TemporaryDirectory(prefix="arena-responses-") as tmp:
        headers_file = Path(tmp) / "headers"
        body_file = Path(tmp) / "body"

        def request(path, encoding="identity", method="GET"):
            result = subprocess.run([
                "curl", "--silent", "--show-error", "--insecure", "--http2",
                "--path-as-is", "--max-time", "15", "--request", method,
                "--header", f"Accept-Encoding: {encoding}",
                "--dump-header", str(headers_file), "--output", str(body_file),
                "--write-out", "%{http_version} %{http_code}",
                args.url.rstrip("/") + path,
            ], check=True, capture_output=True, text=True)
            version, status = result.stdout.split()
            if version != "2":
                raise AssertionError(f"HTTP/2 required, got {version}")
            headers = {}
            for line in headers_file.read_text().splitlines():
                if ":" in line:
                    key, value = line.split(":", 1)
                    headers.setdefault(key.lower(), []).append(value.strip())
            body = body_file.read_bytes()
            lengths = headers.get("content-length", [])
            if lengths != [str(len(body))]:
                raise AssertionError(f"{path}: incorrect/duplicate Content-Length {lengths}")
            if headers.get("content-encoding") == ["gzip"]:
                body = gzip.decompress(body)
            elif "content-encoding" in headers:
                raise AssertionError(f"unexpected encoding: {headers['content-encoding']}")
            return int(status), headers, body

        # Verify real mounted bytes, including fonts/images and compressed text.
        files = sorted(p for p in args.static_dir.iterdir()
                       if p.is_file() and p.suffix not in (".gz", ".br"))
        if not files:
            raise AssertionError("empty static fixture directory")
        for path in files:
            expected = path.read_bytes()
            for encoding in ("identity", "gzip"):
                status, headers, body = request("/static/" + quote(path.name), encoding)
                check(status == 200 and body == expected,
                      f"static {path.name}, {encoding}, exact mounted bytes")

        # Replace an existing file atomically with the SAME size and mtime.
        # This catches startup caches, stale mmap/inodes, and size-only checks.
        target = args.static_dir / "reset.css"
        original = target.read_bytes()
        original_stat = target.stat()
        seed = b"/* live replacement */\n"
        replacement = (seed * (len(original) // len(seed) + 1))[:len(original)]
        assert replacement != original and len(replacement) == len(original)

        def replace_target(content):
            fd, name = tempfile.mkstemp(prefix="arena-replace-", dir=target.parent)
            try:
                with os.fdopen(fd, "wb") as stream:
                    stream.write(content)
                os.chmod(name, original_stat.st_mode & 0o777)
                os.utime(name, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
                os.replace(name, target)
            finally:
                if os.path.exists(name):
                    os.unlink(name)

        try:
            replace_target(replacement)
            for encoding in ("identity", "gzip"):
                status, headers, body = request("/static/reset.css", encoding)
                check(status == 200 and body == replacement,
                      f"static replacement visible immediately, {encoding}")
                if encoding == "gzip":
                    check(headers.get("content-encoding") == ["gzip"],
                          "static compression uses current file contents")
        finally:
            replace_target(original)
        for encoding in ("identity", "gzip"):
            status, _, body = request("/static/reset.css", encoding)
            check(status == 200 and body == original, f"restored file visible, {encoding}")

        # A file created after startup must appear, then disappear on deletion.
        fd, name = tempfile.mkstemp(prefix="arena-live-", suffix=".txt", dir=args.static_dir)
        live = Path(name)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(b"created after server startup\n")
            os.chmod(live, 0o644)
            status, _, body = request("/static/" + live.name)
            check(status == 200 and body == live.read_bytes(), "new static file visible")
        finally:
            live.unlink()
        status, _, _ = request("/static/" + live.name)
        check(status == 404, "deleted static file returns 404")
        status, _, _ = request("/static/../dataset.json")
        check(status in (403, 404), "static handler rejects parent traversal")

        dataset = json.loads(args.dataset.read_text())
        # Change params between requests; exercise URI decoding and JSON escaping.
        for count, multiplier in ((1, 2), (25, 4), (50, 6), (3, 11)):
            expected = {"items": [dict(item, total=item["price"] * item["quantity"] * multiplier)
                                  for item in dataset[:count]], "count": count}
            for encoding in ("identity", "gzip"):
                encoded_multiplier = "".join(f"%{ord(c):02X}" for c in str(multiplier))
                status, headers, body = request(
                    f"/json/{count}?m={encoded_multiplier}", encoding)
                check(status == 200 and json.loads(body) == expected,
                      f"JSON count={count} m={multiplier}, {encoding}, complete schema")
                check(headers.get("content-type", [""])[0].split(";")[0] == "application/json",
                      "JSON content type")
                check(headers.get("content-encoding") == (["gzip"] if encoding == "gzip" else None),
                      f"JSON compression negotiation, {encoding}")
        status, _, body = request("/baseline2?%61=19&b=%32%33")
        check(status == 200 and body == b"42", "framework decodes query names and values")
        status, _, _ = request("/json/1", method="POST")
        check(status == 404, "router rejects unsupported JSON method")

    print(f"{passed} passed")


if __name__ == "__main__":
    main()
