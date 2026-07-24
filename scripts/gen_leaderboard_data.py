#!/usr/bin/env python3
"""Generate site/leaderboard/data.js from site/data/*.json.

The leaderboard is a standalone static page (plain HTML/CSS/JS, no Hugo
templating). This script reads the per-profile result files under site/data
and emits a single `window.LB_DATA = {...}` blob the page renders client-side -
both the per-profile explorer and the composite ranking.

The composite mirrors the canonical board: it averages RPS over each profile's
*scored* connection set, applies per-type profile eligibility, and carries the
tpl_*/bandwidth fields needed for the api-4/api-16 (template mix) and json-comp
(compression-ratio) adjustments.

Run after scripts/rebuild_site_data.py (or any time site/data changes):
    python3 scripts/gen_leaderboard_data.py
"""

from __future__ import annotations
import json
import re
import shutil
import posixpath
import html as _html
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "site" / "data"
DOCS = ROOT / "site" / "content" / "docs"
OUT = ROOT / "site" / "leaderboard" / "data.js"

# Benchmark catalog. Each profile:
#   id, label, category, blurb,
#   explorer:  conn counts shown in the explorer (all useful runs),
#   scored:    conn counts that feed the composite (canonical scored set),
#   s/es:      scored / engineScored eligibility flags.
# scored conns are always a subset of explorer conns.
CATALOG = [
    ("Connection", [
        ("baseline",     "Baseline",    "Mixed GET/POST with query parsing.",       [512,4096,16384],[512,4096], True,True),
        ("pipelined",    "Pipelined",   "16x batched HTTP/1.1 pipelining.",         [512,4096,16384],[512,4096], True,True),
        ("limited-conn", "Short-lived", "Connections close after 10 requests.",     [512,4096],      [512,4096], True,True),
    ]),
    ("Workload", [
        ("json",      "JSON",            "Per-request JSON serialization.",          [4096],              [4096],          True,False),
        ("json-comp", "JSON Comp", "gzip/brotli content negotiation.",         [512,4096,16384],    [512,4096,16384],True,False),
        ("json-tls",  "JSON TLS",        "JSON over HTTP/1.1 + TLS.",                [4096],              [4096],          True,True),
        ("upload",    "Upload",          "Large request-body ingestion.",            [32,64,256,512],     [32,256],        True,False),
        ("static",    "Static",          "20-file static asset serving.",            [1024,4096,6800,16384],[1024,4096,6800],True,False),
    ]),
    ("Database", [
        ("async-db",  "Async DB",  "Async Postgres sequential scan.",                [1024],     [1024],  True,True),
        ("crud",      "CRUD",      "REST API: list, cached read, upsert, update.",   [4096],     [4096],  True,False),
        ("fortunes",  "Fortunes",  "DB query + HTML template render (reference).",    [1024],     [1024],  False,False),
    ]),
    ("Multi-endpoint", [
        ("api-4",  "API-4",  "Mixed workload, server capped at 4 CPUs.",       [256],  [256],  True,False),
        ("api-16", "API-16", "Mixed workload, server capped at 16 CPUs.",      [1024], [1024], True,False),
    ]),
    ("HTTP/2", [
        ("baseline-h2",  "Baseline",       "Baseline over h2 (TLS, ALPN).",          [256,1024],     [256,1024],     True,True),
        ("static-h2",    "Static",         "Static assets over h2 multiplexing.",    [256,1024],     [256,1024],     True,True),
        ("baseline-h2c", "Baseline (h2c)", "Baseline over cleartext h2.",            [256,1024,4096],[256,1024,4096],True,True),
        ("json-h2c",     "JSON (h2c)",     "JSON over cleartext h2.",                [1024,4096],    [1024,4096],    True,False),
    ]),
    ("HTTP/3", [
        ("baseline-h3", "Baseline", "Baseline over QUIC + TLS 1.3.",                 [64], [64], True,True),
        ("static-h3",   "Static",   "Static assets over QUIC.",                      [64], [64], True,True),
    ]),
    ("gRPC", [
        ("unary-grpc",     "Unary",     "Unary gRPC over plaintext h2.",             [256,1024],[256,1024],True,True),
        ("unary-grpc-tls", "Unary TLS", "Unary gRPC over TLS.",                      [256,1024],[256,1024],True,True),
        ("stream-grpc",    "Stream",    "Server-streaming gRPC, plaintext.",         [64],      [64],      True,True),
        ("stream-grpc-tls","Stream TLS","Server-streaming gRPC over TLS.",           [64],      [64],      True,True),
    ]),
    ("Gateway", [
        ("gateway-64", "Gateway (H2)", "Reverse proxy + server, mixed h2.",          [256,512,1024],[512,1024],True,True),
        ("gateway-h3", "Gateway (H3)", "Reverse proxy + server over h3.",            [64,256],      [64,256],  True,True),
        ("production-stack", "Production Stack", "Edge + Redis + JWT auth + server.",[256,1024],[256,1024],True,True),
    ]),
    ("WebSocket", [
        ("echo-ws",          "Echo",           "WebSocket echo throughput.",         [512,4096,16384],[512,4096,16384],True,True),
        ("echo-ws-pipeline", "Echo Pipelined", "Batched WebSocket echo.",            [512,4096,16384],[512,4096,16384],True,True),
        ("echo-ws-limited",  "Echo Short-lived","WebSocket echo, 10 messages per connection.", [512,4096],[512,4096],True,True),
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
    "echo-ws-limited":  "test-profiles/ws/echo-limited/implementation",
}


RESULTS: dict[str, list] = {}


def load_results():
    """Index site/data/results/*.json as {"<profile>-<conns>": [row, ...]}.

    Results used to live in one array per profile-conns, which meant every
    framework's PR wrote the same files and collided (#751). They are now one
    file per framework; this rebuilds the per-profile view the rest of the
    generator expects.

    Rows are sorted by framework name because that is the order the flat files
    were written in, and the emitted data.js must not churn.
    """
    idx: dict[str, list] = {}
    rdir = DATA / "results"
    if not rdir.is_dir():
        return idx
    for f in sorted(rdir.glob("*.json")):
        try:
            entry = json.loads(f.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"[warn] {f.name}: {e}")
            continue
        for key, row in (entry.get("results") or {}).items():
            idx.setdefault(key, []).append(row)
    for key in idx:
        idx[key].sort(key=lambda r: (r.get("framework") or "").lower())
    return idx


def load(name):
    p = DATA / name
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
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
        text = md_path.read_text(encoding="utf-8")
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


def _seo_meta(md_path):
    """Parse (seo_title, description) from frontmatter.

    `title` is the sidebar label and is often deliberately terse — 26 pages are
    called "Implementation Guidelines" and 26 more "Validation". Those make poor
    <title> tags, because every one of them competes for the same query and a
    search result reading just "Validation" says nothing about which test it
    covers. `seo_title` overrides the tag without touching navigation; pages
    whose title is already specific don't need one.

    `description` is authored per page rather than scraped from the first
    paragraph: the opening line is frequently a cross-reference ("Same workload
    as JSON Processing, but…") which reads as boilerplate in a search result.
    """
    seo_title, description = "", ""
    try:
        text = md_path.read_text(encoding="utf-8")
    except Exception:
        return seo_title, description
    if not text.startswith("---"):
        return seo_title, description
    end = text.find("\n---", 3)
    fm = text[3:end] if end != -1 else text[3:]
    for line in fm.splitlines():
        line = line.strip()
        if line.startswith("seo_title:"):
            seo_title = line[10:].strip().strip('"').strip("'")
        elif line.startswith("description:"):
            description = line[12:].strip().strip('"').strip("'")
    return seo_title, description


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
    spec = [("standard", "Standard", "#22c55e"), ("tuned", "Tuned", "#eab308"), ("engine", "Engine", "#dc2626")]
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
        seo_title, description = _seo_meta(p)
        content[did] = {"t": title, "st": seo_title, "d": description,
                        "html": _doc_html(_strip_frontmatter(p.read_text(encoding="utf-8")), cur, did, ids)}
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


# ── Static docs site (SEO) ────────────────────────────────────────────────
# The Knowledge Base is pre-rendered to real /docs/<id>/ pages so search engines
# can index each doc — hash-routed SPA state (#doc=x) is invisible to crawlers, so
# without this every doc collapses into the single "/" URL. Content is the exact
# HTML build_docs() already produces; only the link scheme differs (#doc=x -> /docs/x/).

SITE = "https://www.http-arena.com"
GEN = ROOT / "site" / "generated"
DOCS_OUT = GEN / "docs"


def _doc_url(did):
    return "/docs/" + did + "/" if did else "/docs/"


def _static_links(html):
    """Rewrite the SPA's in-app doc links (#doc=id [+ data-anchor]) to real
    /docs/id/ URLs, and in-page anchors (href="#" data-anchor=a) to #a."""
    def doc_repl(m):
        tid, anc = m.group(1), m.group(2)
        return 'href="' + _doc_url(tid) + ("#" + anc if anc else "") + '"'
    html = re.sub(r'href="#doc=([^"#]*)"(?: data-doc="[^"]*")?(?: data-anchor="([^"]*)")?', doc_repl, html)
    html = re.sub(r'href="#" data-anchor="([^"]*)"', lambda m: 'href="#' + m.group(1) + '"', html)
    return html


def _meta_desc(html):
    m = re.search(r"<p>(.*?)</p>", html, re.S)
    text = re.sub(r"<[^>]+>", "", m.group(1)) if m else ""
    text = _html.unescape(re.sub(r"\s+", " ", text)).strip()
    if len(text) > 155:
        text = text[:152].rstrip() + "…"
    return text or "HttpArena Knowledge Base — how the open HTTP server benchmarks work."


def _sidebar(tree, curid):
    """Collapsed nav, expanded along the path to the current page.

    Rendering the whole tree flat put all 126 pages on every doc page — a wall
    of links with its own scrollbar, where the board shows a collapsible
    accordion. <details> gives the same behaviour with no JavaScript, and stays
    usable if a crawler or a reader-mode ignores it.
    """
    def on_path(u):
        # the current page, or one of its ancestors
        return u == curid or (u != "" and curid.startswith(u + "/"))

    def walk(nodes):
        out = []
        for n in nodes:
            u, title = n["u"], _html.escape(n["t"])
            cls = ' class="cur"' if u == curid else ""
            link = '<a href="%s"%s>%s</a>' % (_doc_url(u), cls, title)
            kids = n.get("c") or []
            if kids:
                out.append('<li><details%s><summary>%s</summary>%s</details></li>'
                           % (" open" if on_path(u) else "", link, walk(kids)))
            else:
                out.append("<li>%s</li>" % link)
        return "<ul>" + "".join(out) + "</ul>"
    root_cls = ' class="cur"' if curid == "" else ""
    return ('<a class="ds-home" href="/">← Leaderboard</a>'
            '<a class="ds-root"%s href="/docs/">%s</a>%s'
            % (root_cls, _html.escape(tree["t"] or "Knowledge Base"),
               walk(tree["c"]) if tree.get("c") else ""))


BOARD = ROOT / "site" / "leaderboard" / "index.html"

# Selectors the doc pages share with the board. Everything else in the board's
# stylesheet is leaderboard furniture - the table, the filters, its own nav -
# and stays there.
_SHARED_EXACT = {
    ":root", "html", "body", "a", "*",
    ".top", ".brand", ".brand-name", ".brand-name b", ".brand-name:hover",
    ".icon-btn", ".icon-btn:hover", ".icon-btn svg", ".top-links",
}
_SHARED_PREFIX = (".doc-", ".type-rules", ".tr-sq")


def _top_level_rules(css):
    """Split a stylesheet into top-level rules, keeping @media blocks whole."""
    out, buf, depth = [], "", 0
    for ch in css:
        buf += ch
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                out.append(buf.strip())
                buf = ""
    return out


def _is_shared(rule):
    sel = rule.split("{", 1)[0].strip()
    if sel.startswith("@media"):
        # the dark-mode preference block defines the same variables as :root
        return "prefers-color-scheme" in sel
    first = sel.split(",")[0].strip()
    return first in _SHARED_EXACT or first.startswith(_SHARED_PREFIX)


def board_chrome():
    """Header markup and shared CSS, read out of the board at build time.

    The board is the single source of truth for site chrome. Copying it by hand
    is what let the doc pages drift twice - the type-rules widget lost the rules
    that hide its inactive panels, and the header lost its icon buttons - so
    this reads the real thing instead. Editing the board now updates the doc
    pages automatically, and a structural change here fails the build loudly
    rather than silently shipping a half-styled page.
    """
    html = BOARD.read_text(encoding="utf-8")
    brand = re.search(r'<div class="brand">(.*?)</div>', html, re.S)
    links = re.search(r'<div class="top-links">(.*?)</div>', html, re.S)
    style = re.search(r"<style>(.*?)</style>", html, re.S)
    if not (brand and links and style):
        raise SystemExit(f"gen: cannot read site chrome from {BOARD.relative_to(ROOT)} - "
                         "expected .brand, .top-links and a <style> block")
    shared = [r for r in _top_level_rules(style.group(1)) if _is_shared(r)]
    if len(shared) < 40:
        raise SystemExit(f"gen: only {len(shared)} shared CSS rules found in "
                         f"{BOARD.relative_to(ROOT)} - the selector list is stale")
    # the board's brand link drives its in-page router; on a doc page it goes home
    brand_html = brand.group(1).strip().replace('href="#" id="brandHome"', 'href="/"')
    return brand_html, links.group(1).strip(), "\n".join(shared)


# Resolved once at import: the board's chrome, shared by every generated page.
_CHROME = board_chrome()

_THEME_INIT = ("<script>try{var t=localStorage.getItem('lb-theme');"
               "if(t)document.documentElement.setAttribute('data-theme',t);}catch(e){}</script>")
_THEME_TOGGLE = ("<script>var b=document.getElementById('theme');if(b)b.onclick=function(){"
                 "var d=document.documentElement,c=d.getAttribute('data-theme')==='dark'||"
                 "(d.getAttribute('data-theme')!=='light'&&matchMedia('(prefers-color-scheme: dark)').matches);"
                 "var n=c?'light':'dark';d.setAttribute('data-theme',n);"
                 "try{localStorage.setItem('lb-theme',n);}catch(e){}};</script>")


def _doc_page(did, title, body_html, tree, seo_title="", description=""):
    url = SITE + _doc_url(did)
    # Authored metadata wins; the scraped first paragraph stays as the fallback
    # so a page that hasn't been given frontmatter yet still renders sensibly.
    desc = description or _meta_desc(body_html)
    t = _html.escape(seo_title or title)
    d = _html.escape(desc)
    head = ('<!doctype html><html lang="en" data-theme=""><head>'
            '<meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            + _THEME_INIT
            + "<title>" + t + " – HttpArena</title>"
            + '<meta name="description" content="' + d + '">'
            + '<link rel="canonical" href="' + url + '">'
            + '<link rel="icon" href="/favicon.ico" sizes="any">'
            + '<link rel="icon" href="/favicon.svg" type="image/svg+xml">'
            + '<meta property="og:type" content="article">'
            + '<meta property="og:site_name" content="HttpArena">'
            + '<meta property="og:title" content="' + t + '">'
            + '<meta property="og:description" content="' + d + '">'
            + '<meta property="og:url" content="' + url + '">'
            + '<link rel="stylesheet" href="/docs/docs.css">'
            + "</head>")
    # Same markup and classes as the board's header, so crossing between /
    # and /docs/ doesn't change the chrome. The board-only controls (type
    # filters, round selector, hardware chips) are leaderboard state, not site
    # chrome, so they aren't carried over; everything else is identical.
    header = ('<body><header class="top">'
              '<div class="brand">' + _CHROME[0] + '</div>'
              '<a class="brand-sub" href="/docs/">Knowledge Base</a>'
              '<div class="top-links">' + _CHROME[1] + '</div>'
              '</header>')
    body = ('<div class="docs-layout">'
            '<aside class="docs-sidebar">' + _sidebar(tree, did) + '</aside>'
            '<main class="doc-main"><article class="doc-wrap">'
            '<h1 class="doc-title">' + t + "</h1>"
            + _static_links(body_html)
            + "</article></main></div>")
    return head + header + body + _THEME_TOGGLE + "</body></html>"


def _docs_css():
    """The board's shared chrome, plus the rules only these pages need.

    Everything shared - theme variables, reset, header, doc body, cards and the
    shortcode widgets - comes from the board itself, so the two can't diverge.
    Only the standalone-page shell is defined here: the board has no two-column
    docs layout and no sidebar of its own.
    """
    return _CHROME[2] + """
/* ── standalone doc-page shell (not present on the board) ─────────────── */
.brand-sub{color:var(--text-2);font-size:.9rem;padding-left:.7rem;border-left:1px solid var(--line)}
.top-links{margin-left:auto}
.docs-layout{display:flex;align-items:flex-start;gap:2rem;max-width:1200px;margin:0 auto;padding:1.5rem}
.docs-sidebar{position:sticky;top:64px;flex:none;width:250px;max-height:calc(100vh - 84px);overflow-y:auto;font-size:.86rem}
.ds-home{display:block;color:var(--muted);font-size:.8rem;margin-bottom:.9rem}
.ds-home:hover{color:var(--accent)}
.ds-root{display:block;font-weight:700;color:var(--text);margin-bottom:.5rem;padding:.28rem .4rem}
.ds-root.cur{color:var(--accent)}
.docs-sidebar ul{list-style:none;margin:0;padding:0 0 0 .2rem}
.docs-sidebar li>ul{padding-left:.75rem;border-left:1px solid var(--line-soft);margin:.1rem 0 .1rem .35rem}
.docs-sidebar a{display:block;padding:.28rem .4rem;border-radius:6px;color:var(--text-2)}
.docs-sidebar a:hover{background:var(--panel-2);color:var(--text)}
.docs-sidebar a.cur{background:var(--accent-weak);color:var(--accent);font-weight:650}
.docs-sidebar details>summary{list-style:none;display:flex;align-items:center;gap:.2rem;cursor:pointer}
.docs-sidebar details>summary::-webkit-details-marker{display:none}
.docs-sidebar details>summary::before{content:"\u25b8";flex:none;width:.8rem;font-size:.6rem;color:var(--muted);transition:transform .18s ease}
.docs-sidebar details[open]>summary::before{transform:rotate(90deg)}
.docs-sidebar details>summary>a{flex:1;min-width:0}
.doc-main{flex:1;min-width:0;max-width:820px}
.doc-wrap{max-width:none}
@media (max-width:820px){.docs-layout{flex-direction:column;gap:1rem;padding:1rem}.docs-sidebar{position:static;width:100%;max-height:none;padding-bottom:.5rem;border-bottom:1px solid var(--line)}.doc-main{max-width:100%}.brand{width:auto}}
"""


def build_doc_pages(tree, content):
    """Write a real static page per doc under site/generated/docs/<id>/index.html."""
    if not tree:
        return 0
    if DOCS_OUT.exists():
        shutil.rmtree(DOCS_OUT)
    DOCS_OUT.mkdir(parents=True, exist_ok=True)
    (DOCS_OUT / "docs.css").write_text(_docs_css(), encoding="utf-8")
    for did, d in content.items():
        page = _doc_page(did, d["t"] or "Knowledge Base", d["html"], tree,
                         seo_title=d.get("st", ""), description=d.get("d", ""))
        dest = (DOCS_OUT / did / "index.html") if did else (DOCS_OUT / "index.html")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(page, encoding="utf-8")
    return len(content)


def write_search_index(tree, content):
    """Emit window.LB_SEARCH — the Knowledge Base as plain text, for the board's
    page search.

    The board used to search `docs.js`, which shipped every page's rendered
    HTML and had the client strip the tags at runtime. Now that the docs are
    real pages, that blob is gone — but the search still needs something to
    match against, or it silently stops finding documentation (the exact
    complaint of #970, which the search was built for).

    A text index is the right shape for this anyway: it is roughly half the
    size of the HTML it replaces, needs no client-side parsing, and each entry
    carries the URL of the real page so results link out to /docs/<id>/.
    """
    crumbs = {}

    def walk(node, trail):
        crumbs[node["u"]] = " › ".join(trail) if trail else "Knowledge Base"
        for ch in node.get("c") or []:
            walk(ch, trail + [node["t"]] if node["u"] else ["Knowledge Base"])

    if tree:
        walk(tree, [])

    entries = []
    for did, d in sorted(content.items()):
        text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", d["html"]))
        text = _html.unescape(text).strip()
        entries.append({"u": did, "t": d["t"] or "Knowledge Base",
                        "c": crumbs.get(did, "Knowledge Base"),
                        "d": d.get("d", ""), "x": text})
    # Next to data.js, not under generated/: the board loads both with relative
    # <script src>, and the deploy copies them to the site root the same way.
    out = OUT.parent / "search.js"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("window.LB_SEARCH = " + json.dumps(entries, separators=(",", ":")) + ";\n",
                   encoding="utf-8")
    return len(entries), out.stat().st_size


def write_sitemap(content):
    """Root + every /docs/<id>/. Replaces the old Hugo-generated /old/ sitemap."""
    urls = [SITE + "/"] + [SITE + _doc_url(did) for did in sorted(content.keys())]
    body = "".join("<url><loc>%s</loc></url>" % u for u in urls)
    GEN.mkdir(parents=True, exist_ok=True)
    (GEN / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' + body + "</urlset>\n",
        encoding="utf-8")
    return len(urls)


def main():
    global RESULTS
    RESULTS = load_results()
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
        for pid, label, blurb, explorer, scored, s, es in entries:
            present = []
            for c in explorer:
                rows = RESULTS.get(f"{pid}-{c}")
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
                    "scored": s, "engineScored": es,
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

    # Docs are pre-rendered to real /docs/<id>/ pages (SEO); the SPA links out to
    # them. LB_DATA still carries the docs *tree* for the sidebar labels, but the
    # doc *content* is no longer shipped as docs.js.
    n_pages = build_doc_pages(docs_tree, docs_content)
    n_search, search_bytes = write_search_index(docs_tree, docs_content)
    n_urls = write_sitemap(docs_content)

    n_rows = sum(len(v) for v in results.values())
    print(f"wrote {OUT.relative_to(ROOT)} - {len(profiles)} profiles, "
          f"{len(results)} views, {n_rows} rows, {OUT.stat().st_size // 1024} KB")
    print(f"wrote {DOCS_OUT.relative_to(ROOT)}/ - {n_pages} static doc pages")
    print(f"wrote {(OUT.parent / 'search.js').relative_to(ROOT)} - {n_search} indexed pages, {search_bytes // 1024} KB")
    print(f"wrote {(GEN / 'sitemap.xml').relative_to(ROOT)} - {n_urls} URLs")


if __name__ == "__main__":
    main()
