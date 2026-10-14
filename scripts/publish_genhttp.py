#!/usr/bin/env python3
"""Publish the site and its results to the genhttp.dev lambda behind http-arena.

.github/workflows/publish-genhttp.yml runs this when someone starts it, after
gen_leaderboard_data.py has generated the site from main. The site and the results are data:
they go through the lambda's api/ingest/, and no version is saved for them. The runs' logs stay
in the repository, where the lambda sends the site's links to them. Three steps, in this order:

  code   site/lambda/, the lambda's code, saved as a new version and put online - only when
         it changed: the newest version says in its specification what it holds.
  site   the tree scripts/assemble_site.sh lays out, to api/ingest/site/: the content the
         lambda does not keep yet, then every path at once, which switches the site over.
  data   site/data/frameworks.json, current.json and results/*.json at this commit,
         as one snapshot to api/ingest/publish.

Environment:
  GENHTTP_EDITOR_KEY   the lambda's editor key (code)
  ARENA_INGEST_KEY     the lambda's secret of that name (site, data)
  ARENA_URL            where the lambda answers, default https://http-arena.com
  GENHTTP_API          the platform's API, default https://genhttp.dev/api/v1

Standard library only, so the workflow installs nothing for it.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import io
import json
import os
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LAMBDA = ROOT / "site" / "lambda"
DATA = ROOT / "site" / "data"

# what the lambda accepts as a path of the site (Names in site/lambda/Store.cs)
SITE_PATH = re.compile(r"^(?:[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}/)*[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$")

# the lambda's own folders that are never part of a version
NOT_CODE = {"bin", "obj", "workspace", "database"}


class Conflict(Exception):
    """A 409 the caller asked to see rather than fail on."""


class NoRedirects(urllib.request.HTTPRedirectHandler):
    """A redirect is an answer, not followed: the keys go only where they were sent."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(NoRedirects)


def request(method: str, url: str, body: bytes | None = None, headers: dict | None = None,
            timeout: int = 120, attempts: int = 4, conflict: bool = False) -> bytes:
    """One HTTP call, retried on connection errors and 5xx; anything else is final."""
    for attempt in range(1, attempts + 1):
        req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
        try:
            with OPENER.open(req, timeout=timeout) as response:
                return response.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:2000]
            if e.code == 409 and conflict:
                raise Conflict(detail)
            if e.code < 500 or attempt == attempts:
                # the lambda moved, as it did to its own domain: ARENA_URL says where it answers
                moved = f" to {redact(e.headers.get('Location') or '?')}" if 300 <= e.code < 400 else ""
                raise SystemExit(f"{method} {redact(url)} -> {e.code}{moved}: {detail}")
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if attempt == attempts:
                raise SystemExit(f"{method} {redact(url)} failed: {e}")
        time.sleep(2 ** attempt)
    raise AssertionError("unreachable")


def redact(url: str) -> str:
    """The editor key is in the platform's URLs; it never goes to a log."""
    key = os.environ.get("GENHTTP_EDITOR_KEY")
    return url.replace(key, "***") if key else url


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"{name} is not set")
    return value


def field(obj: dict, name: str):
    """The platform's JSON may come in either case; read it in both."""
    for key, value in (obj or {}).items():
        if key.lower() == name.lower():
            return value
    return None


# ----------------------------------------------------------------------------- code

def lambda_files() -> list[tuple[str, Path]]:
    """The lambda's code: every file under site/lambda/ but what a build or a run writes."""
    files = []
    for path in sorted(LAMBDA.rglob("*")):
        rel = path.relative_to(LAMBDA)
        if not path.is_file() or rel.parts[0] in NOT_CODE:
            continue
        if path.name == ".gitignore":
            continue  # a zip is read as a commit would be: its .gitignore would apply
        files.append((rel.as_posix(), path))
    return files


def build_zip() -> tuple[bytes, str]:
    """The version, laid out as a clone of the lambda is, and a hash of what it holds."""
    digest = hashlib.sha256()
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name, path in lambda_files():
            content = path.read_bytes()
            digest.update(name.encode() + b"\0" + hashlib.sha256(content).digest())
            # a fixed time, so that the same files make the same zip
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, content)
    return buffer.getvalue(), digest.hexdigest()


def publish_code(api: str, commit: str, title: str, pr: int | None) -> None:
    key = env("GENHTTP_EDITOR_KEY")
    archive, content = build_zip()

    # the newest version says in its specification what it holds; the same again is skipped
    marker = f"content {content}"
    versions = json.loads(request("GET", f"{api}/lambdas/{key}/versions") or b"[]")
    versions = field(versions, "payload") if isinstance(versions, dict) else versions
    newest = max(versions or [], key=lambda v: field(v, "version") or 0, default=None)
    if newest and marker in (field(newest, "specification") or ""):
        deployment = json.loads(request("GET", f"{api}/lambdas/{key}/deployment") or b"{}")
        if field(deployment, "deployed") and field(deployment, "version") == field(newest, "version"):
            print(f"[code] version {field(newest, 'version')} already holds site/lambda/ as it is, and is online")
            return

    change = f"Publishes {commit[:9]}: {title}"[:200]
    specification = (f"The code of the HttpArena site's lambda, site/lambda/ as of "
                     f"https://github.com/MDA2AV/HttpArena/commit/{commit}" + (f" (#{pr})" if pr else "") + f". {marker}")
    query = urllib.parse.urlencode({"deploy": "true", "layout": "project",
                                    "change": change, "specification": specification})

    print(f"[code] site/lambda/ changed: saving a version, {len(archive) / 1e3:.0f} KB zipped")
    answer = json.loads(request("POST", f"{api}/lambdas/{key}/versions/zip?{query}", archive,
                                {"Content-Type": "application/zip"}, timeout=600, attempts=2) or b"{}")
    saved = field(answer, "payload") or answer
    deployment = field(saved, "deployment") or {}
    if not field(deployment, "success"):
        problems = "\n".join(json.dumps(d) for d in (field(deployment, "diagnostics") or []))
        raise SystemExit(f"[code] version {field(saved, 'version')} was saved but not deployed:\n{problems}")
    print(f"[code] version {field(saved, 'version')} is online")


# ----------------------------------------------------------------------------- site

def publish_site(url: str, commit: str, workers: int) -> None:
    headers = {"X-Api-Key": env("ARENA_INGEST_KEY")}

    with tempfile.TemporaryDirectory() as tmp:
        site_dir = Path(tmp) / "site"
        subprocess.check_call([str(ROOT / "scripts" / "assemble_site.sh"), "--no-logs", str(site_dir)])

        files: dict[str, str] = {}
        content: dict[str, Path] = {}
        for path in sorted(site_dir.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(site_dir).as_posix()
            if len(rel) > 300 or not SITE_PATH.match(rel):
                raise SystemExit(f"[site] {rel} is not a path the lambda serves: folders and a name of "
                                 "[A-Za-z0-9._-], none starting with a dot")
            sha256 = hashlib.sha256(path.read_bytes()).hexdigest()
            files[rel] = sha256
            content.setdefault(sha256, path)

        def send() -> int:
            """Sends the content the lambda does not keep, and says how many."""
            kept = set(field(json.loads(request("GET", f"{url}/api/ingest/site", headers=headers)), "kept") or [])
            missing = [sha256 for sha256 in content if sha256 not in kept]

            def put(sha256: str) -> None:
                request("PUT", f"{url}/api/ingest/site/{sha256}", content[sha256].read_bytes(),
                        {**headers, "Content-Type": "application/octet-stream"}, timeout=300)

            with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
                list(pool.map(put, missing))
            return len(missing)

        def post(conflict: bool) -> dict:
            """Puts every path online at once - refused while content is missing."""
            body = json.dumps({"commit": commit, "files": files}, separators=(",", ":")).encode()
            return json.loads(request("POST", f"{url}/api/ingest/site", body,
                                      {**headers, "Content-Type": "application/json"}, timeout=300, conflict=conflict))

        sent = send()
        try:
            summary = post(conflict=True)
        except Conflict:
            # content went away between the two calls: send what is missing now, once
            sent += send()
            summary = post(conflict=False)

    print(f"[site] {len(files)} files, {len(content)} distinct, {sent} sent: publish {field(summary, 'id')}, "
          + ("unchanged, already online" if field(summary, "unchanged") else
             f"{field(summary, 'changed')} changed, {field(summary, 'removed')} removed, "
             f"{field(summary, 'deleted')} no longer kept"))


# ----------------------------------------------------------------------------- data

def publish_data(url: str, commit: str, title: str, pr: int | None) -> None:
    snapshot = {
        "commit": commit,
        "pr": pr,
        "title": title,
        "host": json.loads((DATA / "current.json").read_text()),
        "frameworks": json.loads((DATA / "frameworks.json").read_text()),
        "results": {p.stem: json.loads(p.read_text()) for p in sorted((DATA / "results").glob("*.json"))},
    }
    body = json.dumps(snapshot, separators=(",", ":")).encode()
    headers = {"X-Api-Key": env("ARENA_INGEST_KEY"), "Content-Type": "application/json"}
    summary = json.loads(request("POST", f"{url}/api/ingest/publish", body, headers, timeout=300))
    print(f"[data] publish {field(summary, 'id')}: {field(summary, 'frameworks')} entries, {field(summary, 'rows')} rows, "
          f"{field(summary, 'changed')} changed, {field(summary, 'removed')} removed"
          + (" - unchanged, already published" if field(summary, "unchanged") else ""))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--pr", type=int, help="the pull request whose merge this is")
    parser.add_argument("--skip", action="append", default=[], choices=["code", "site", "data"],
                        help="leave a step out (repeatable)")
    parser.add_argument("--workers", type=int, default=8, help="files sent at once")
    args = parser.parse_args()

    url = os.environ.get("ARENA_URL", "https://http-arena.com").rstrip("/")
    api = os.environ.get("GENHTTP_API", "https://genhttp.dev/api/v1").rstrip("/")
    commit = git("rev-parse", "HEAD")
    title = git("log", "-1", "--format=%s")

    # a squash merge names its pull request at the end of the title: "... (#1556)"
    if args.pr is None and (merged := re.search(r"\(#(\d+)\)$", title)):
        args.pr = int(merged.group(1))

    if "code" not in args.skip:
        publish_code(api, commit, title, args.pr)
    if "site" not in args.skip:
        publish_site(url, commit, args.workers)
    if "data" not in args.skip:
        publish_data(url, commit, title, args.pr)


if __name__ == "__main__":
    main()
