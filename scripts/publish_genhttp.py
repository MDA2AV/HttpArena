#!/usr/bin/env python3
"""Publish the site, its results and its logs to the genhttp.dev lambda behind http-arena.

.github/workflows/publish-genhttp.yml runs this when a pull request merges, after
gen_leaderboard_data.py has generated the site. Three steps, in this order:

  site   site/lambda/ (the lambda's code) and the site scripts/assemble_site.sh lays out,
         at the root of its resources/, saved as a new version of the lambda and put online.
         Skipped when the newest version already holds exactly this.
  logs   site/static/logs/**/*.log, gzipped, to api/ingest/logs/. Only what differs from
         what the lambda keeps is sent, and what the repository no longer has is deleted.
  data   site/data/frameworks.json, current.json and results/*.json at this commit,
         as one snapshot to api/ingest/publish.

Environment:
  GENHTTP_EDITOR_KEY   the lambda's editor key (site)
  ARENA_INGEST_KEY     the lambda's secret of that name (logs, data)
  ARENA_URL            where the lambda answers, default https://http-arena.genhttp.run
  GENHTTP_API          the platform's API, default https://genhttp.dev/api/v1

Standard library only, so the workflow installs nothing for it.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import gzip
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LAMBDA = ROOT / "site" / "lambda"
LOGS = ROOT / "site" / "static" / "logs"
DATA = ROOT / "site" / "data"

# what the lambda accepts as {profile}/{conns}/{name}.log (Names in site/lambda/Store.cs)
LOG_PATH = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}/[0-9]{1,7}/[A-Za-z0-9][A-Za-z0-9._-]{0,123}\.log$")

# the lambda's own folders that are never part of a version
NOT_CODE = {"bin", "obj", "workspace", "database"}

# what the platform takes as a name below resources/: these characters, no part starting with a
# dot, an extension to serve it by, at most six parts and 120 characters
RESOURCE_NAME = re.compile(r"^(?!.*(?:^|/)\.)(?:[A-Za-z0-9_.-]+/){0,5}[A-Za-z0-9_-][A-Za-z0-9_.-]*\.[A-Za-z0-9]+$")


def request(method: str, url: str, body: bytes | None = None, headers: dict | None = None,
            timeout: int = 120, attempts: int = 4) -> bytes:
    """One HTTP call, retried on connection errors and 5xx; anything else is final."""
    for attempt in range(1, attempts + 1):
        req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                return response.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:2000]
            if e.code < 500 or attempt == attempts:
                raise SystemExit(f"{method} {redact(url)} -> {e.code}: {detail}")
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


# ----------------------------------------------------------------------------- site

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


def build_zip(site_dir: Path) -> tuple[bytes, str]:
    """The version, laid out as a clone of the lambda is, and a hash of what it holds."""
    entries = lambda_files()
    site = [(f"resources/{p.relative_to(site_dir).as_posix()}", p) for p in sorted(site_dir.rglob("*")) if p.is_file()]

    taken = {name for name, _ in entries}
    if clash := [name for name, _ in site if name in taken]:
        raise SystemExit(f"[site] the site has files the lambda already ships: {', '.join(clash)}")
    if refused := [name for name, _ in site if len(name) > 120 or not RESOURCE_NAME.match(name[len("resources/"):])]:
        raise SystemExit("[site] the platform takes resource names of [A-Za-z0-9_.-], at most six parts deep and "
                         "120 characters, with an extension; these are not:\n  " + "\n  ".join(refused))
    entries += site

    digest = hashlib.sha256()
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name, path in entries:
            content = path.read_bytes()
            digest.update(name.encode() + b"\0" + hashlib.sha256(content).digest())
            # a fixed time, so that the same files make the same zip
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, content)
    return buffer.getvalue(), digest.hexdigest()


def publish_site(api: str, commit: str, title: str, pr: int | None) -> None:
    key = env("GENHTTP_EDITOR_KEY")

    with tempfile.TemporaryDirectory() as tmp:
        site_dir = Path(tmp) / "site"
        subprocess.check_call([str(ROOT / "scripts" / "assemble_site.sh"), "--no-logs", str(site_dir)])
        archive, content = build_zip(site_dir)

    # the newest version says in its specification what it holds; the same again is skipped
    marker = f"content {content}"
    versions = json.loads(request("GET", f"{api}/lambdas/{key}/versions") or b"[]")
    versions = field(versions, "payload") if isinstance(versions, dict) else versions
    newest = max(versions or [], key=lambda v: field(v, "version") or 0, default=None)
    if newest and marker in (field(newest, "specification") or ""):
        deployment = json.loads(request("GET", f"{api}/lambdas/{key}/deployment") or b"{}")
        if field(deployment, "deployed") and field(deployment, "version") == field(newest, "version"):
            print(f"[site] version {field(newest, 'version')} already holds this and is online")
            return

    change = f"Publishes {commit[:9]}: {title}"[:200]
    specification = (f"The HttpArena site as of https://github.com/MDA2AV/HttpArena/commit/{commit}"
                     + (f" (#{pr})" if pr else "") + f". {marker}")
    query = urllib.parse.urlencode({"deploy": "true", "layout": "project",
                                    "change": change, "specification": specification})

    print(f"[site] saving a version: {len(archive) / 1e6:.1f} MB zipped")
    answer = json.loads(request("POST", f"{api}/lambdas/{key}/versions/zip?{query}", archive,
                                {"Content-Type": "application/zip"}, timeout=600, attempts=2) or b"{}")
    saved = field(answer, "payload") or answer
    deployment = field(saved, "deployment") or {}
    if not field(deployment, "success"):
        problems = "\n".join(json.dumps(d) for d in (field(deployment, "diagnostics") or []))
        raise SystemExit(f"[site] version {field(saved, 'version')} was saved but not deployed:\n{problems}")
    print(f"[site] version {field(saved, 'version')} is online")


# ----------------------------------------------------------------------------- logs

def publish_logs(url: str, workers: int) -> None:
    headers = {"X-Api-Key": env("ARENA_INGEST_KEY")}
    kept = field(json.loads(request("GET", f"{url}/api/ingest/logs", headers=headers)), "logs") or {}

    local: dict[str, Path] = {}
    for path in sorted(LOGS.rglob("*.log")):
        rel = path.relative_to(LOGS).as_posix()
        if LOG_PATH.match(rel):
            local[rel] = path
        else:
            print(f"[logs] skipping {rel}: not a {{profile}}/{{conns}}/{{name}}.log the lambda takes", file=sys.stderr)

    def put(rel: str) -> int:
        content = local[rel].read_bytes()
        if kept.get(rel) == hashlib.sha256(content).hexdigest():
            return 0
        body = gzip.compress(content, compresslevel=9, mtime=0)
        request("PUT", f"{url}/api/ingest/logs/{rel}", body,
                {**headers, "Content-Type": "application/gzip"}, timeout=300)
        return 1

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        sent = sum(pool.map(put, local))

    gone = sorted(set(kept) - set(local))
    for rel in gone:
        request("DELETE", f"{url}/api/ingest/logs/{rel}", headers=headers)

    print(f"[logs] {len(local)} in the repository: {sent} sent, {len(local) - sent} already kept, {len(gone)} deleted")


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
    parser.add_argument("--skip", action="append", default=[], choices=["site", "logs", "data"],
                        help="leave a step out (repeatable)")
    parser.add_argument("--workers", type=int, default=8, help="logs sent at once")
    args = parser.parse_args()

    url = os.environ.get("ARENA_URL", "https://http-arena.genhttp.run").rstrip("/")
    api = os.environ.get("GENHTTP_API", "https://genhttp.dev/api/v1").rstrip("/")
    commit = git("rev-parse", "HEAD")
    title = git("log", "-1", "--format=%s")

    # a squash merge names its pull request at the end of the title: "... (#1556)"
    if args.pr is None and (merged := re.search(r"\(#(\d+)\)$", title)):
        args.pr = int(merged.group(1))

    if "site" not in args.skip:
        publish_site(api, commit, title, args.pr)
    if "logs" not in args.skip:
        publish_logs(url, args.workers)
    if "data" not in args.skip:
        publish_data(url, commit, title, args.pr)


if __name__ == "__main__":
    main()
