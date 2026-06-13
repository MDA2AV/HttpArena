#!/usr/bin/env python3
"""Generate site/static/new-leaderboard/data.js from site/data/*.json.

The "new leaderboard" is a standalone static page (plain HTML/CSS/JS, no Hugo
templating). This script reads the same per-profile result files the Hugo
leaderboard consumes and emits a single `window.LB_DATA = {...}` blob the page
renders client-side - both the per-profile explorer and the composite ranking.

The composite mirrors the canonical board: it averages RPS over each profile's
*scored* connection set, applies per-type profile eligibility, and carries the
tpl_*/bandwidth fields needed for the api-4/api-16 (template mix) and json-comp
(compression-ratio) adjustments.

Run after scripts/rebuild_site_data.py (or any time site/data changes):
    python3 scripts/gen_new_leaderboard_data.py
"""

from __future__ import annotations
import json
import re
import posixpath
import html as _html
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "site" / "data"
DOCS = ROOT / "site" / "content" / "docs"
OUT = ROOT / "site" / "static" / "new-leaderboard" / "data.js"

# Benchmark catalog. Each profile:
#   id, label, category, blurb,
#   explorer:  conn counts shown in the explorer (all useful runs),
#   scored:    conn counts that feed the composite (canonical scored set),
#   s/es/is:   scored / engineScored / infraScored eligibility flags.
# scored conns are always a subset of explorer conns.
CATALOG = [
    ("Connection", [
        ("baseline",     "Baseline",    "Mixed GET/POST with query parsing.",       [512,4096,16384],[512,4096], True,True,True),
        ("pipelined",    "Pipelined",   "16x batched HTTP/1.1 pipelining.",         [512,4096,16384],[512,4096], True,True,True),
        ("limited-conn", "Short-lived", "Connections close after 10 requests.",     [512,4096],      [512,4096], True,True,True),
    ]),
    ("Workload", [
        ("json",      "JSON",            "Per-request JSON serialization.",          [4096],              [4096],          True,False,False),
        ("json-comp", "JSON Comp", "gzip/brotli content negotiation.",         [512,4096,16384],    [512,4096,16384],True,False,False),
        ("json-tls",  "JSON TLS",        "JSON over HTTP/1.1 + TLS.",                [4096],              [4096],          True,False,False),
        ("upload",    "Upload",          "Large request-body ingestion.",            [32,64,256,512],     [32,256],        True,False,False),
        ("static",    "Static",          "20-file static asset serving.",            [1024,4096,6800,16384],[1024,4096,6800],True,False,True),
    ]),
    ("Database", [
        ("async-db",  "Async DB",  "Async Postgres sequential scan.",                [1024],     [1024],  True,False,False),
        ("crud",      "CRUD",      "REST API: list, cached read, upsert, update.",   [4096],     [4096],  True,False,False),
        ("fortunes",  "Fortunes",  "DB query + HTML template render (reference).",    [1024],     [1024],  False,False,False),
    ]),
    ("Multi-endpoint", [
        ("api-4",  "API-4",  "Mixed workload, server capped at 4 CPUs.",       [256],  [256],  True,True,False),
        ("api-16", "API-16", "Mixed workload, server capped at 16 CPUs.",      [1024], [1024], True,False,False),
    ]),
    ("HTTP/2", [
        ("baseline-h2",  "Baseline",       "Baseline over h2 (TLS, ALPN).",          [256,1024],     [256,1024],     True,True,False),
        ("static-h2",    "Static",         "Static assets over h2 multiplexing.",    [256,1024],     [256,1024],     True,True,False),
        ("baseline-h2c", "Baseline (h2c)", "Baseline over cleartext h2.",            [256,1024,4096],[256,1024,4096],True,True,False),
        ("json-h2c",     "JSON (h2c)",     "JSON over cleartext h2.",                [1024,4096],    [1024,4096],    True,False,False),
    ]),
    ("HTTP/3", [
        ("baseline-h3", "Baseline", "Baseline over QUIC + TLS 1.3.",                 [64], [64], True,True,False),
        ("static-h3",   "Static",   "Static assets over QUIC.",                      [64], [64], True,True,False),
    ]),
    ("gRPC", [
        ("unary-grpc",     "Unary",     "Unary gRPC over plaintext h2.",             [256,1024],[256,1024],True,True,False),
        ("unary-grpc-tls", "Unary TLS", "Unary gRPC over TLS.",                      [256,1024],[256,1024],True,True,False),
        ("stream-grpc",    "Stream",    "Server-streaming gRPC, plaintext.",         [64],      [64],      True,True,False),
        ("stream-grpc-tls","Stream TLS","Server-streaming gRPC over TLS.",           [64],      [64],      True,True,False),
    ]),
    ("Gateway", [
        ("gateway-64", "Gateway (H2)", "Reverse proxy + server, mixed h2.",          [256,512,1024],[512,1024],True,True,False),
        ("gateway-h3", "Gateway (H3)", "Reverse proxy + server over h3.",            [64,256],      [64,256],  True,True,False),
        ("production-stack", "Production Stack", "Edge + Redis + JWT auth + server.",[256,1024],[256,1024],True,True,False),
    ]),
    ("WebSocket", [
        ("echo-ws",          "Echo",           "WebSocket echo throughput.",         [512,4096,16384],[512,4096,16384],True,True,False),
        ("echo-ws-pipeline", "Echo Pipelined", "Batched WebSocket echo.",            [512,4096,16384],[512,4096,16384],True,True,False),
    ]),
]

# Fields kept per result row. tpl_* only emitted when present (api/gateway/prod).
BASE_FIELDS = ("rps", "avg_latency", "p99_latency", "cpu", "memory", "bandwidth", "input_bw",
               "status_2xx", "status_3xx", "status_4xx", "status_5xx")
TPL_FIELDS = ("tpl_baseline", "tpl_json", "tpl_upload", "tpl_static", "tpl_async_db")

# Map each benchmark profile to its Knowledge Base "Implementation Guidelines"
# page (docs ids differ from profile ids; TLS gRPC variants share one page).
PROFILE_DOC = {
    "baseline":         "test-profiles/h1/isolated/baseline/implementation",
    "pipelined":        "test-profiles/h1/isolated/pipelined/implementation",
    "limited-conn":     "test-profiles/h1/isolated/short-lived/implementation",
    "json":             "test-profiles/h1/isolated/json-processing/implementation",
    "json-comp":        "test-profiles/h1/isolated/json-compressed/implementation",
    "json-tls":         "test-profiles/h1/isolated/json-tls/implementation",
    "upload":           "test-profiles/h1/isolated/upload/implementation",
    "static":           "test-profiles/h1/isolated/static/implementation",
    "async-db":         "test-profiles/h1/isolated/async-database/implementation",
    "crud":             "test-profiles/h1/isolated/crud/implementation",
    "fortunes":         "test-profiles/h1/isolated/fortunes/implementation",
    "api-4":            "test-profiles/h1/workload/api-4/implementation",
    "api-16":           "test-profiles/h1/workload/api-16/implementation",
    "baseline-h2":      "test-profiles/h2/baseline-h2/implementation",
    "static-h2":        "test-profiles/h2/static-h2/implementation",
    "baseline-h2c":     "test-profiles/h2/baseline-h2c/implementation",
    "json-h2c":         "test-profiles/h2/json-h2c/implementation",
    "baseline-h3":      "test-profiles/h3/baseline-h3/implementation",
    "static-h3":        "test-profiles/h3/static-h3/implementation",
    "unary-grpc":       "test-profiles/grpc/unary/implementation",
    "unary-grpc-tls":   "test-profiles/grpc/unary/implementation",
    "stream-grpc":      "test-profiles/grpc/stream/implementation",
    "stream-grpc-tls":  "test-profiles/grpc/stream/implementation",
    "gateway-64":       "test-profiles/gateway/gateway-h2/implementation",
    "gateway-h3":       "test-profiles/gateway/gateway-h3/implementation",
    "production-stack": "test-profiles/gateway/production-stack/implementation",
    "echo-ws":          "test-profiles/ws/echo/implementation",
    "echo-ws-pipeline": "test-profiles/ws/echo-pipeline/implementation",
}


def load(name):
    p = DATA / name
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except Exception as e:
        print(f"[warn] {name}: {e}")
        return None


# ── Knowledge Base (docs) ─────────────────────────────────────────────────
# Pull the docs content into the standalone leaderboard so the Knowledge Base
# is self-contained - no links into the Hugo site. This carries the same *data*,
# not Hugo's rendering: frontmatter is stripped, Hugo shortcodes are reduced to
# plain text (keeping their data), and the body is shown as preformatted text.
# The sidebar tree mirrors the docs hierarchy, ordered like Hugo's default
# .Pages sort: by weight (unset = 0), then title (case-insensitive). Node "u"
# is an internal id (docs-relative path) used to look up content client-side.

def _frontmatter(md_path):
    """Parse (title, weight) from a markdown file's leading YAML frontmatter."""
    title, weight = "", 0
    try:
        text = md_path.read_text()
    except Exception:
        return title, weight
    if not text.startswith("---"):
        return title, weight
    end = text.find("\n---", 3)
    fm = text[3:end] if end != -1 else text[3:]
    for line in fm.splitlines():
        line = line.strip()
        if line.startswith("title:"):
            title = line[6:].strip().strip('"').strip("'")
        elif line.startswith("weight:"):
            try:
                weight = int(line[7:].strip())
            except ValueError:
                pass
    return title, weight


def _strip_frontmatter(text):
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            nl = text.find("\n", end + 1)
            return text[nl + 1:] if nl != -1 else ""
    return text


def _attrs(s):
    return dict(re.findall(r'(\w+)="([^"]*)"', s))


# A small, dependency-free Markdown -> HTML converter, scoped to the dialect the
# docs use (ATX headings, paragraphs, nested lists, GFM tables, fenced code,
# blockquotes, inline code/bold/italic/links) plus the three Hugo shortcodes.
# Internal links route in-page (#doc=<id>); externals open in a new tab.

def _slug(text):
    s = re.sub(r"<[^>]+>", "", text).strip().lower()
    s = re.sub(r"[^a-z0-9\s-]", "", s)
    s = re.sub(r"[\s-]+", "-", s)
    return s.strip("-")


# Per-document context for relative-link resolution: the page's own id and the
# full id set, used as a fallback base when a link doesn't resolve against the
# file's directory (the docs mix both relative-link dialects).
_SELF = ""
_IDS = set()


def _resolve(href, curdir, ids):
    """Return (kind, target, anchor); kind in {ext, doc, anchor}.
    Internal links resolve against the file's dir, then (fallback) the page's
    own id-as-dir - matching the two relative-link dialects used in the docs."""
    anchor = ""
    if "#" in href:
        href, anchor = href.split("#", 1)
    if href.startswith(("http://", "https://", "mailto:")):
        return ("ext", href + ("#" + anchor if anchor else ""), "")
    if not href:
        return ("anchor", "", anchor)
    if href.endswith(".md"):
        href = href[:-3]
    if href.startswith("/docs/"):
        tid = href[len("/docs/"):].strip("/")
    elif href.startswith("/"):
        return ("ext", href + ("#" + anchor if anchor else ""), "")  # other site asset
    else:
        tid = posixpath.normpath(posixpath.join(curdir, href)).strip("/")
        if tid not in _IDS:
            alt = posixpath.normpath(posixpath.join(_SELF, href)).strip("/")
            if alt in _IDS:
                tid = alt
    return ("doc", tid, anchor)


def _fmt(t):
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<!\*)\*(?!\s)(.+?)(?<!\s)\*(?!\*)", r"<em>\1</em>", t)
    t = re.sub(r"(?<![\w\\])_(?!\s)(.+?)(?<!\s)_(?![\w])", r"<em>\1</em>", t)
    return t


def _inline(text, curdir, ids):
    codes = []
    text = re.sub(r"(`+)(.+?)\1",
                  lambda m: codes.append(_html.escape(m.group(2))) or "\x00C%d\x00" % (len(codes) - 1),
                  text)
    links = []

    def link_sub(m):
        label = _fmt(_html.escape(m.group(1)))
        kind, target, anchor = _resolve(m.group(2).strip(), curdir, ids)
        if kind == "ext":
            a = '<a href="%s" target="_blank" rel="noopener">%s</a>' % (_html.escape(target), label)
        elif kind == "anchor":
            a = '<a href="#" data-anchor="%s">%s</a>' % (_html.escape(anchor), label)
        elif target in ids:
            da = ' data-anchor="%s"' % _html.escape(anchor) if anchor else ""
            a = '<a href="#doc=%s" data-doc="%s"%s>%s</a>' % (_html.escape(target), _html.escape(target), da, label)
        else:
            a = label  # unresolved internal link -> plain text (stays self-contained)
        links.append(a)
        return "\x00L%d\x00" % (len(links) - 1)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link_sub, text)
    text = _fmt(_html.escape(text))
    text = re.sub(r"\x00L(\d+)\x00", lambda m: links[int(m.group(1))], text)
    text = re.sub(r"\x00C(\d+)\x00", lambda m: "<code>%s</code>" % codes[int(m.group(1))], text)
    return text


_LIST_RE = re.compile(r"^(\s*)([-*+]|\d+\.)\s+(.*)$")


def _row(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return [c.strip() for c in s.split("|")]


def _table(lines, i, out, curdir, ids):
    header = _row(lines[i])
    i += 2
    body = []
    while i < len(lines) and lines[i].strip() and "|" in lines[i]:
        body.append(_row(lines[i]))
        i += 1
    th = "".join("<th>%s</th>" % _inline(c, curdir, ids) for c in header)
    rows = "".join("<tr>%s</tr>" % "".join("<td>%s</td>" % _inline(c, curdir, ids) for c in r) for r in body)
    out.append("<table><thead><tr>%s</tr></thead><tbody>%s</tbody></table>" % (th, rows))
    return i


def _list(lines, start, out, curdir, ids):
    def parse(idx, indent):
        ordered = bool(re.match(r"\d+\.", _LIST_RE.match(lines[idx]).group(2)))
        tag = "ol" if ordered else "ul"
        items = []
        while idx < len(lines):
            if not lines[idx].strip():
                j = idx + 1
                while j < len(lines) and not lines[j].strip():
                    j += 1
                m2 = _LIST_RE.match(lines[j]) if j < len(lines) else None
                if m2 and len(m2.group(1)) >= indent:
                    idx = j
                    continue
                break
            m = _LIST_RE.match(lines[idx])
            if not m:
                if items and (len(lines[idx]) - len(lines[idx].lstrip())) > indent:
                    items[-1] = items[-1][:-5] + " " + _inline(lines[idx].strip(), curdir, ids) + "</li>"
                    idx += 1
                    continue
                break
            ind = len(m.group(1))
            if ind < indent:
                break
            if ind > indent:
                sub, idx = parse(idx, ind)
                if items:
                    items[-1] = items[-1][:-5] + sub + "</li>"
                continue
            items.append("<li>%s</li>" % _inline(m.group(3), curdir, ids))
            idx += 1
        return "<%s>%s</%s>" % (tag, "".join(items), tag), idx
    html, nxt = parse(start, len(_LIST_RE.match(lines[start]).group(1)))
    out.append(html)
    return nxt


def _md_to_html(body, curdir, ids):
    lines = body.split("\n")
    n = len(lines)
    out, para, i = [], [], 0

    def flush():
        if para:
            out.append("<p>%s</p>" % _inline(" ".join(para).strip(), curdir, ids))
            para.clear()

    while i < n:
        line = lines[i]
        m = re.match(r"^```(\w*)\s*$", line)
        if m:
            flush()
            lang, code = m.group(1), []
            i += 1
            while i < n and not re.match(r"^```\s*$", lines[i]):
                code.append(lines[i])
                i += 1
            i += 1
            cls = ' class="language-%s"' % lang if lang else ""
            out.append("<pre><code%s>%s</code></pre>" % (cls, _html.escape("\n".join(code))))
            continue
        if not line.strip():
            flush()
            i += 1
            continue
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            flush()
            lvl, txt = len(m.group(1)), m.group(2).strip()
            out.append("<h%d id=\"%s\">%s</h%d>" % (lvl, _slug(txt), _inline(txt, curdir, ids), lvl))
            i += 1
            continue
        if re.match(r"^\s*([-*_])(\s*\1){2,}\s*$", line) and not _LIST_RE.match(line):
            flush()
            out.append("<hr>")
            i += 1
            continue
        if "|" in line and i + 1 < n and "|" in lines[i + 1] and set(lines[i + 1].strip()) <= set("|:- ") and "-" in lines[i + 1]:
            flush()
            i = _table(lines, i, out, curdir, ids)
            continue
        if line.lstrip().startswith(">"):
            flush()
            q = []
            while i < n and lines[i].lstrip().startswith(">"):
                q.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            out.append("<blockquote>%s</blockquote>" % _md_to_html("\n".join(q), curdir, ids))
            continue
        if _LIST_RE.match(line):
            flush()
            i = _list(lines, i, out, curdir, ids)
            continue
        para.append(line.strip())
        i += 1
    flush()
    return "\n".join(out)


def _typerules(a, curdir, ids):
    spec = [("production", "Standard", "#22c55e"), ("tuned", "Tuned", "#eab308"), ("engine", "Engine", "#dc2626")]
    tabs = panels = ""
    for idx, (k, lbl, col) in enumerate(spec):
        act = " active" if idx == 0 else ""
        oc = ("var r=this.closest('.type-rules');"
              "r.querySelectorAll('.type-rules-tab').forEach(function(t){t.classList.remove('active')});"
              "this.classList.add('active');"
              "r.querySelectorAll('.type-rules-panel').forEach(function(p){p.classList.remove('active')});"
              "r.querySelector('[data-panel=%s]').classList.add('active')" % k)
        tabs += '<button class="type-rules-tab%s" onclick="%s"><span class="tr-sq" style="background:%s"></span>%s</button>' % (act, oc, col, lbl)
        panels += '<div class="type-rules-panel%s" data-panel="%s">%s</div>' % (act, k, _inline(a.get(k, ""), curdir, ids))
    return '<div class="type-rules"><div class="type-rules-tabs">%s</div>%s</div>' % (tabs, panels)


def _tabs(items, conts, curdir, ids):
    tabs = panels = ""
    for idx, cont in enumerate(conts):
        label = items[idx] if idx < len(items) else ("Tab %d" % (idx + 1))
        act = " active" if idx == 0 else ""
        oc = ("var r=this.closest('.doc-tabset');"
              "r.querySelectorAll('.doc-tab').forEach(function(t){t.classList.remove('active')});"
              "this.classList.add('active');"
              "var ps=r.querySelectorAll('.doc-tabpanel');"
              "ps.forEach(function(p){p.classList.remove('active')});ps[%d].classList.add('active')" % idx)
        tabs += '<button class="doc-tab%s" onclick="%s">%s</button>' % (act, oc, _html.escape(label))
        panels += '<div class="doc-tabpanel%s">%s</div>' % (act, _md_to_html(cont.strip(), curdir, ids))
    return '<div class="doc-tabset"><div class="doc-tabs">%s</div>%s</div>' % (tabs, panels)


def _shortcodes(body, curdir, ids, blocks):
    def stash(html):
        blocks.append(html)
        return "\n\n\x00B%d\x00\n\n" % (len(blocks) - 1)

    body = re.sub(r"\{\{<\s*type-rules\s+(.*?)\s*>\}\}",
                  lambda m: stash(_typerules(_attrs(m.group(1)), curdir, ids)), body, flags=re.S)

    def tabs_sub(m):
        items = [s.strip() for s in _attrs(m.group(1)).get("items", "").split(",") if s.strip()]
        conts = re.findall(r"\{\{<\s*tab\s*>\}\}(.*?)\{\{<\s*/tab\s*>\}\}", m.group(2), flags=re.S)
        return stash(_tabs(items, conts, curdir, ids))
    body = re.sub(r"\{\{<\s*tabs\s+(.*?)\s*>\}\}(.*?)\{\{<\s*/tabs\s*>\}\}", tabs_sub, body, flags=re.S)

    def cards_sub(m):
        out = []
        for c in re.findall(r"\{\{<\s*card\s+(.*?)\s*>\}\}", m.group(1), flags=re.S):
            a = _attrs(c)
            kind, target, _ = _resolve(a.get("link", ""), curdir, ids)
            ttl = _inline(a.get("title", ""), curdir, ids)
            sub = _inline(a.get("subtitle", ""), curdir, ids)
            inner = '<span class="dc-t">%s</span><span class="dc-s">%s</span>' % (ttl, sub)
            if kind == "doc" and target in ids:
                out.append('<a class="doc-card" href="#doc=%s" data-doc="%s">%s</a>' % (_html.escape(target), _html.escape(target), inner))
            elif kind == "ext":
                out.append('<a class="doc-card" href="%s" target="_blank" rel="noopener">%s</a>' % (_html.escape(target), inner))
            else:
                out.append('<div class="doc-card">%s</div>' % inner)
        return stash('<div class="doc-cards">%s</div>' % "".join(out))
    body = re.sub(r"\{\{<\s*cards\s*>\}\}(.*?)\{\{<\s*/cards\s*>\}\}", cards_sub, body, flags=re.S)

    return re.sub(r"\{\{[<%].*?[>%]\}\}", "", body, flags=re.S)  # strip any stragglers


def _doc_html(body, curdir, selfid, ids):
    global _SELF, _IDS
    _SELF, _IDS = selfid, ids
    blocks = []
    body = _shortcodes(body, curdir, ids, blocks)
    out = _md_to_html(body, curdir, ids)
    out = re.sub(r"<p>\x00B(\d+)\x00</p>", lambda m: blocks[int(m.group(1))], out)
    out = re.sub(r"\x00B(\d+)\x00", lambda m: blocks[int(m.group(1))], out)
    return '<div class="doc-body">' + out + "</div>"


def _docs_node(dir_path):
    """Build a sidebar tree node for a docs section directory (has _index.md)."""
    rel = dir_path.relative_to(DOCS).as_posix()
    rel = "" if rel == "." else rel
    title, weight = _frontmatter(dir_path / "_index.md")
    children = []
    for child in sorted(dir_path.iterdir(), key=lambda p: p.name):
        if child.is_dir() and (child / "_index.md").exists():
            children.append(_docs_node(child))
        elif child.is_file() and child.suffix == ".md" and child.name != "_index.md":
            t, w = _frontmatter(child)
            crel = child.relative_to(DOCS).with_suffix("").as_posix()
            children.append({"t": t, "u": crel, "w": w})
    children.sort(key=lambda n: (n["w"], n["t"].lower()))
    node = {"t": title, "u": rel, "w": weight}
    if children:
        node["c"] = [{k: v for k, v in c.items() if k != "w"} for c in children]
    return node


def build_docs():
    """Return (sidebar tree, {id: {t, html}}) for the docs, or (None, {})."""
    if not (DOCS / "_index.md").exists():
        return None, {}
    # First pass: enumerate every page's id and its content directory.
    pages = []
    for p in DOCS.rglob("*.md"):
        rel = p.relative_to(DOCS)
        cur = "" if rel.parent.as_posix() == "." else rel.parent.as_posix()
        did = cur if p.name == "_index.md" else rel.with_suffix("").as_posix()
        pages.append((p, did, cur))
    ids = {d for _, d, _ in pages}
    # Second pass: render. Hugo resolves relative links with relref semantics -
    # against the source file's directory, not the URL - so curdir is that dir.
    content = {}
    for p, did, cur in pages:
        title, _ = _frontmatter(p)
        content[did] = {"t": title, "html": _doc_html(_strip_frontmatter(p.read_text()), cur, did, ids)}
    tree = _docs_node(DOCS)
    tree.pop("w", None)
    return tree, content


# Name of the current (unfinished) benchmark round. Archived rounds come from
# data/rounds/index.json (empty until a round is finalized & snapshotted).
CURRENT_ROUND = "Alpha Round"


def build_rounds():
    idx = load("rounds/index.json")
    archived = idx if isinstance(idx, list) else []
    return {"name": CURRENT_ROUND, "ongoing": True, "archived": archived}


def main():
    frameworks = load("frameworks.json") or {}
    langcolors = load("langcolors.json") or {}
    current = load("current.json") or {}

    meta = {n: {"type": m.get("type", "emerging"),
                "mode": m.get("mode", "standard"),
                "language": m.get("language", ""),
                "repo": m.get("repo", ""),
                "dir": m.get("dir", ""),
                "engine": m.get("engine", ""),
                "desc": m.get("description", "")} for n, m in frameworks.items()}

    docs_tree, docs_content = build_docs()

    profiles, results = [], {}
    for category, entries in CATALOG:
        for pid, label, blurb, explorer, scored, s, es, isc in entries:
            present = []
            for c in explorer:
                rows = load(f"{pid}-{c}.json")
                if not rows:
                    continue
                trimmed = []
                for r in rows:
                    fw = r.get("framework")
                    if not fw:
                        continue
                    row = {"fw": fw, "lang": r.get("language", "")}
                    for f in BASE_FIELDS:
                        row[f] = r.get(f)
                    for f in TPL_FIELDS:
                        if r.get(f):
                            row[f] = r.get(f)
                    trimmed.append(row)
                if trimmed:
                    results[f"{pid}-{c}"] = trimmed
                    present.append(c)
            if present:
                prof = {
                    "id": pid, "label": label, "category": category, "blurb": blurb,
                    "conns": present,
                    "scoredConns": [c for c in scored if c in present],
                    "scored": s, "engineScored": es, "infraScored": isc,
                }
                docid = PROFILE_DOC.get(pid)
                if docid and docid in docs_content:
                    prof["doc"] = docid
                elif docid:
                    print(f"[warn] profile '{pid}' -> implementation doc '{docid}' not found")
                profiles.append(prof)

    payload = {"current": current, "langColors": langcolors, "meta": meta,
               "profiles": profiles, "results": results, "docs": docs_tree,
               "rounds": build_rounds()}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("window.LB_DATA = " + json.dumps(payload, separators=(",", ":")) + ";\n")

    docs_out = OUT.parent / "docs.js"
    docs_out.write_text("window.LB_DOCS = " + json.dumps(docs_content, separators=(",", ":")) + ";\n")

    n_rows = sum(len(v) for v in results.values())
    print(f"wrote {OUT.relative_to(ROOT)} - {len(profiles)} profiles, "
          f"{len(results)} views, {n_rows} rows, {OUT.stat().st_size // 1024} KB")
    print(f"wrote {docs_out.relative_to(ROOT)} - {len(docs_content)} docs pages, "
          f"{docs_out.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
