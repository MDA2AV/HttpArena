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
from urllib.parse import quote

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
        ("pipelined",    "Pipelined",   "16x batched HTTP/1.1 pipelining (reference).", [512,4096,16384],[512,4096], False,False),
        ("limited-conn", "Short-lived", "Connections close after 10 requests.",     [512,4096],      [512,4096], True,True),
    ]),
    ("Workload", [
        ("json",      "JSON",            "Per-request JSON serialization.",          [4096],              [4096],          True,False),
        ("json-comp", "JSON Comp", "gzip/brotli content negotiation.",         [512,4096,16384],    [512,4096,16384],True,False),
        ("json-tls",  "JSON TLS",        "JSON over HTTP/1.1 + TLS.",                [4096],              [4096],          True,True),
        ("upload",    "Upload",          "Large request-body ingestion.",            [32,64,256,512],     [32,256],        True,False),
        ("static",    "Static",          "20-file static asset serving.",            [1024,4096,6800,16384],[1024,4096,6800],True,False),
        ("static-tls","Static TLS",      "20-file static serving over TLS.",         [1024,4096,6800],    [1024,4096,6800],True,False),
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
    "static-tls":       "test-profiles/h1/isolated/static-tls/implementation",
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
    """The board's nav, rebuilt statically.

    Same markup and classes as buildNav() produces - .nav-search, .nav-grp /
    .nav-grp-h / .nav-grp-body, .nav-item, .caret - so it is styled by the
    board's own CSS and behaves the same. Groups on the path to the current
    page carry .open, exactly as `expanded` does on the board.
    """
    def on_path(u):
        return u == curid or (u != "" and curid.startswith(u + "/"))

    def walk(nodes, lvl=0):
        out = []
        for n in nodes:
            u, title = n["u"], _html.escape(n["t"])
            kids = n.get("c") or []
            if kids:
                open_cls = " open" if on_path(u) else ""
                head = ('<div class="nav-grp-h%s">'
                        '<a class="nav-grp-link%s" href="%s">%s</a>'
                        '<span class="caret">\u25b8</span></div>'
                        % (" active" if u == curid else "",
                           " active" if u == curid else "", _doc_url(u), title))
                out.append('<div class="nav-grp%s%s">%s'
                           '<div class="nav-grp-body"><div class="nav-grp-inner">%s</div></div>'
                           '</div>'
                           % (" lvl0" if lvl == 0 else "", open_cls, head, walk(kids, lvl + 1)))
            else:
                out.append('<a class="nav-item%s" href="%s">%s</a>'
                           % (" active" if u == curid else "", _doc_url(u), title))
        return "".join(out)

    return (
        '<div class="nav-search"><div class="ns-box">'
        '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
        'stroke-width="2.2"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/></svg>'
        '<input id="navq" type="search" placeholder="Search pages" autocomplete="off" '
        'spellcheck="false" aria-label="Search pages" role="combobox" aria-expanded="false" '
        'aria-controls="navResults"></div></div>'
        '<div class="nav-results" id="navResults" role="listbox" aria-label="Search results" '
        'style="display:none"></div>'
        '<div id="navTree">'
        '<a class="nav-item" href="/">\u2190 Leaderboard</a>'
        '<div class="nav-sec"><div class="nav-grp lvl0 open">'
        '<div class="nav-grp-h%s"><a class="nav-grp-link" href="/docs/">%s</a>'
        '<span class="caret">\u25b8</span></div>'
        '<div class="nav-grp-body"><div class="nav-grp-inner">%s</div></div>'
        '</div></div></div>'
        % (" active" if curid == "" else "",
           _html.escape(tree["t"] or "Knowledge Base"),
           walk(tree.get("c") or []))
    )


BOARD = ROOT / "site" / "leaderboard" / "index.html"

# Selectors the doc pages share with the board. Everything else in the board's
# stylesheet is leaderboard furniture - the table, the filters, its own nav -
# and stays there.
_SHARED_EXACT = {
    ":root", "html", "body", "a", "*",
    ".top", ".brand", ".brand-name", ".brand-name b", ".brand-name:hover",
    ".icon-btn", ".icon-btn:hover", ".icon-btn svg", ".top-links",
}
_SHARED_PREFIX = (".doc-", ".type-rules", ".tr-sq", ".nav", ".ns-box", ".caret")


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
    # a rule can carry a leading /* comment */; that is not part of the selector
    sel = re.sub(r"/\*.*?\*/", " ", rule.split("{", 1)[0], flags=re.S).strip()
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
_NAV_JS = ("<script src=\"/search.js\"></script>"
           "<script>(function(){"
           # accordion: same behaviour as the board's toggleGrp
           "document.querySelectorAll('.nav-grp-h .caret').forEach(function(c){"
           "c.onclick=function(e){e.preventDefault();e.stopPropagation();"
           "c.closest('.nav-grp').classList.toggle('open');};});"
           # page search over the index the generator emits
           "var inp=document.getElementById('navq'),box=document.getElementById('navResults'),"
           "tree=document.getElementById('navTree');if(!inp||!window.LB_SEARCH)return;"
           "function esc(s){return String(s).replace(/[&<>\"]/g,function(c){"
           "return {'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}[c];});}"
           "function snip(x,t){var i=x.toLowerCase().indexOf(t);if(i<0)return esc(x.slice(0,110));"
           "var a=Math.max(0,i-45),b=Math.min(x.length,i+t.length+75);"
           "return (a>0?'\u2026':'')+esc(x.slice(a,i))+'<mark>'+esc(x.slice(i,i+t.length))+'</mark>'"
           "+esc(x.slice(i+t.length,b))+(b<x.length?'\u2026':'');}"
           "function run(){var q=inp.value.trim().toLowerCase();"
           "if(!q){box.style.display='none';tree.style.display='';inp.setAttribute('aria-expanded','false');return;}"
           "var terms=q.split(/\\s+/).filter(Boolean),hits=[];"
           "window.LB_SEARCH.forEach(function(e){var t=(e.t||'').toLowerCase(),"
           "b=((e.d||'')+' '+(e.x||'')).toLowerCase(),sc=0;"
           "for(var i=0;i<terms.length;i++){var ti=t.indexOf(terms[i]),bi=b.indexOf(terms[i]);"
           "if(ti<0&&bi<0)return;sc+=ti===0?60:ti>0?35:0;if(bi>=0)sc+=5;}"
           "if(t===q)sc+=50;hits.push({e:e,sc:sc});});"
           "hits.sort(function(a,b){return b.sc-a.sc||a.e.t.length-b.e.t.length;});"
           "hits=hits.slice(0,25);"
           "tree.style.display='none';box.style.display='';inp.setAttribute('aria-expanded','true');"
           "if(!hits.length){box.innerHTML='<div class=\"nav-empty\">No page matches <b>'+esc(inp.value)+'</b>.</div>';return;}"
           "var h='<div class=\"nav-res-h\"><span>Pages</span><span>'+hits.length+'</span></div>';"
           "hits.forEach(function(hit){var e=hit.e;"
           "h+='<a class=\"nav-res\" href=\"/docs/'+(e.u?e.u+'/':'')+'\">'"
           "+'<span class=\"nav-res-t\">'+esc(e.t)+'</span>'"
           "+'<span class=\"nav-res-c\">'+esc(e.c||'')+'</span>'"
           "+'<span class=\"nav-res-s\">'+snip((e.d||'')+' '+(e.x||''),terms[0])+'</span></a>';});"
           "box.innerHTML=h;}"
           "var t;inp.addEventListener('input',function(){clearTimeout(t);t=setTimeout(run,90);});"
           "inp.addEventListener('keydown',function(e){if(e.key==='Escape'){inp.value='';run();inp.blur();}});"
           "})();</script>")

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
            '<aside class="nav">' + _sidebar(tree, did) + '</aside>'
            '<main class="doc-main"><article class="doc-wrap">'
            '<h1 class="doc-title">' + t + "</h1>"
            + _static_links(body_html)
            + "</article></main></div>")
    return head + header + body + _NAV_JS + _THEME_TOGGLE + "</body></html>"


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
/* Same two-column shape as the board's .layout; the rail itself is the board's
   .nav, styled by the board's own CSS. */
/* wider than the board's 264px rail: this tree goes five levels deep and
   each level costs .8rem of indent, so names would truncate. */
.docs-layout{display:grid;grid-template-columns:320px 1fr;align-items:start}
.doc-main{min-width:0;padding:1.6rem 2rem 4rem;max-width:900px}
.doc-wrap{max-width:none}
.nav-grp-link{display:block;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:inherit;font:inherit;text-decoration:none}
@media (max-width:820px){.docs-layout{grid-template-columns:1fr}.nav{position:static;height:auto;width:100%;border-right:0;border-bottom:1px solid var(--line)}.doc-main{padding:1.1rem 1.1rem 4rem;max-width:100%}.brand{width:auto}}
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


# ── README badges (shields.io endpoint) ──────────────────────────────────────
# A framework's rank in one composite family, as a JSON document shields.io
# renders into an SVG. The maintainer pastes one URL and it follows the board.
#
# The scoring below is a port of computeComposite() in site/leaderboard/index.html
# and MUST track it. It is pinned to the board's *default* state — the score a
# visitor sees when they click through from the badge and touch nothing:
#
#     useMem=false   rescale=false   showTuned=true   q=''
#
# so the only client-side knob left is the type filter, which the leagues below
# reproduce. If the board's defaults or its scoring change, change this too;
# check-badge-parity.js diffs the two and is what should catch the drift.

BADGE_OUT = GEN / "badge"


def _slug(name):
    """URL segment for a display name. Two gateway entries carry spaces and a
    '+', so names can't go in a path as-is. Same rule rebuild_site_data.py uses
    for result filenames, so /badge/<slug>/ lines up with results/<slug>.json."""
    return (re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-") or "unnamed").lower()

# category -> family key. Mirrors familyOf() in index.html; anything unlisted is
# HTTP/1.1 (Connection, Workload, Database, Multi-endpoint).
FAMILY_OF_CAT = {"Gateway": "gw", "HTTP/2": "h2", "HTTP/3": "h3",
                 "gRPC": "grpc", "WebSocket": "ws"}
FAMILY_LABEL = {"h1": "H/1.1", "h2": "H/2", "h3": "H/3",
                "gw": "Gateway", "grpc": "gRPC", "ws": "WebSocket"}

# Leagues are the board's type filter. flagship+emerging is its default view and
# ranks as one field; engine entries are scored on their own profile subset, so
# a framework's 100 is never set by an engine's result (and vice versa).
LEAGUES = [("flagship", "emerging"), ("engine",), ("experimental",)]

# A rank is only worth publishing if something was beaten to earn it.
BADGE_MIN_FIELD = 2

# How long shields.io may hold a rendered badge. 300 is its floor — lower values
# are clamped back up to it. This was an hour, which put a stale rank in front of
# every embed for up to an hour after a deploy on top of GitHub's own Camo cache.
# The extra cost is shields re-reading a ~130-byte static file on Pages twelve
# times as often, which is nothing; on GitHub, Camo still dominates, but anywhere
# outside it (docs sites, dashboards) the badge is now near-live.
BADGE_CACHE_SECONDS = 300

# Label-side colour, carrying the entry's tier. Same four hues as the board's
# type swatch next to every framework name, but in the darker tone the board
# uses for type *text* (.b-* / .type-filter .on in index.html) rather than the
# swatch fill (.tsq-*). Shields paints badge text white and does not adapt to
# the background, and the swatch fills fail against it — experimental worst at
# 2.7:1, flagship 3.4:1. These four all clear 4.5:1 while staying the same
# colour family the board taught the reader.
TYPE_COLOR = {
    "flagship":     "1b7a4e",   # green
    "emerging":     "2b5694",   # blue
    "experimental": "8a5a12",   # amber
    "engine":       "b0463a",   # terracotta
}
TYPE_COLOR_FALLBACK = "1f2937"

# api-4/api-16 template mix — MIXW in index.html.
MIXW = {"baseline": 0.15, "json": 1, "upload": 10, "static": 2, "async_db": 10}

_MEM_RE = re.compile(r"([\d.]+)\s*([KMG]i?B)", re.I)
_BW_RE = re.compile(r"([\d.]+)\s*([KMG]?B)/s", re.I)


def _mem(s):
    """"512 MiB" -> MiB. Mirrors mem() in index.html."""
    m = _MEM_RE.search(str(s or ""))
    if not m:
        return 0.0
    v, u = float(m.group(1)), m.group(2).upper()[0]
    return v * 1024 if u == "G" else v if u == "M" else v / 1024 if u == "K" else v


def _bw(s):
    """"12.30MB/s" -> bytes/s. Mirrors bw() in index.html."""
    m = _BW_RE.search(str(s or ""))
    if not m:
        return 0.0
    v, u = float(m.group(1)), m.group(2).upper()[0]
    return v * 1e9 if u == "G" else v * 1e6 if u == "M" else v * 1e3 if u == "K" else v


def badge_aggregate(profiles, results):
    """Average rps/mem/bw (and the api template mix) over each profile's scored
    conns. Port of aggregate() in index.html."""
    avg, amem, abw, atpl = {}, {}, {}, {}
    for p in profiles:
        pid = p["id"]
        sums, ms, bs, cn, ts = {}, {}, {}, {}, {}
        for c in p["scoredConns"]:
            for r in results.get(f"{pid}-{c}", []):
                fw = r["fw"]
                sums[fw] = sums.get(fw, 0) + (r.get("rps") or 0)
                cn[fw] = cn.get(fw, 0) + 1
                ms[fw] = ms.get(fw, 0) + _mem(r.get("memory"))
                bs[fw] = bs.get(fw, 0) + _bw(r.get("bandwidth"))
                if pid in ("api-4", "api-16"):
                    t = ts.setdefault(fw, dict.fromkeys(MIXW, 0.0) | {"n": 0})
                    for k in MIXW:
                        t[k] += r.get("tpl_" + k) or 0
                    t["n"] += 1
        avg[pid] = {fw: sums[fw] / cn[fw] for fw in sums}
        amem[pid] = {fw: ms[fw] / cn[fw] for fw in sums}
        abw[pid] = {fw: bs[fw] / cn[fw] for fw in sums}
        if pid in ("api-4", "api-16"):
            atpl[pid] = {fw: {k: t[k] / t["n"] for k in MIXW} for fw, t in ts.items()}
    return {"avg": avg, "mem": amem, "bw": abw, "tpl": atpl}


def badge_composite(agg, profiles, meta, scope, types, show_tuned=True, lang=None,
                    fw_lang=None):
    """Composite scores for one family and one league, best first.

    Port of computeComposite(). `show_tuned` and `lang` are the board's two
    display filters, and they behave here the way they behave there with rescale
    off: they narrow *who is listed*, never what anyone scored. The normalizing
    maxima below are deliberately taken over the whole league — that is what
    keeps a framework's number identical whether or not tuned entries are in
    view, and what stops the badge disagreeing with the page it links to.
    """
    prof = {p["id"]: p for p in profiles}
    pids = [p["id"] for p in profiles
            if FAMILY_OF_CAT.get(p["category"], "h1") == scope]
    if not pids:
        return []

    A = agg
    fw_lang = fw_lang or {}
    # outOfLeague in index.html: a separate competition, so excluded from the
    # normalizing maxima as well as from the listing.
    in_league = lambda fw: meta.get(fw, {}).get("type", "emerging") in types

    def shown(fw):
        """hidden() in index.html — display only, never touches the maxima."""
        if not show_tuned and meta.get(fw, {}).get("mode", "standard") == "tuned":
            return False
        if lang and fw_lang.get(fw) != lang:
            return False
        return True

    def is_scored(pid, fw):
        p = prof[pid]
        if not p["scored"]:
            return False
        if meta.get(fw, {}).get("type", "emerging") == "engine":
            return bool(p["engineScored"])
        return True

    # json-comp is scored on bandwidth-adjusted rps: the best compressor sets the
    # bar and everyone else is penalised by the square of their size ratio.
    min_bpr = None
    if "json-comp" in pids and A["avg"].get("json-comp"):
        cand = []
        for fw, rps in A["avg"]["json-comp"].items():
            b = A["bw"]["json-comp"].get(fw, 0)
            if in_league(fw) and rps > 0 and b > 0:
                cand.append(b / rps)
        if cand:
            min_bpr = min(cand)

    def eff(pid, fw):
        rps = A["avg"].get(pid, {}).get(fw, 0)
        if rps <= 0:
            return 0.0
        t = A["tpl"].get(pid, {}).get(fw)
        if pid in ("api-4", "api-16") and t:
            return sum(t[k] * w for k, w in MIXW.items())
        if pid == "json-comp" and min_bpr is not None:
            b = A["bw"][pid].get(fw, 0)
            if b > 0:
                return rps * (min_bpr / (b / rps)) ** 2
        return rps

    max_r = {}
    for pid in pids:
        vals = [eff(pid, fw) for fw in A["avg"].get(pid, {}) if in_league(fw)]
        max_r[pid] = max(vals, default=0.0)

    rows = []
    fwset = {fw for pid in pids for fw in A["avg"].get(pid, {})}
    for fw in fwset:
        if not in_league(fw) or not shown(fw):
            continue
        score, any_result = 0.0, False
        for pid in pids:
            rps = A["avg"].get(pid, {}).get(fw, 0)
            if rps > 0 and max_r[pid] > 0:
                # `any_result` is the board's row test and is deliberately wider
                # than the score: an entry whose only results in this family sit
                # on profiles that do not count for its tier still occupies a
                # row, at 0. pico is one — an engine whose h1 results are json
                # (not engineScored) and pipelined (reference-only). Dropping
                # those rows here made the badge's field one short of what the
                # board renders, which is a number people can count (#1149).
                any_result = True
                if is_scored(pid, fw):
                    score += (eff(pid, fw) / max_r[pid]) * 100
        if any_result:
            rows.append((fw, score))
    rows.sort(key=lambda r: (-r[1], r[0]))
    return rows


def _lang_slug(lang):
    """URL segment for a language name. Not _slug(): that maps C, C# and C++ all
    onto "c", so a C# entry's badge would sit at .../h1-c.json. The punctuation
    is spelled out first, which is also how these read aloud."""
    s = lang.lower().replace("++", "pp").replace("#", "sharp")
    return re.sub(r"[^a-z0-9._-]+", "-", s).strip("-") or "unknown"


def _fw_languages(results):
    """framework -> language, from the result rows the board itself reads."""
    lang = {}
    for rows in results.values():
        for r in rows:
            if r.get("lang"):
                lang[r["fw"]] = r["lang"]
    return lang


def _badge_link(scope, types, lang=None, show_tuned=False):
    """Deep link to the board view the rank was taken in — the whole field, not
    the one entry. Following a badge should show what "#6 of 83" was measured
    against; filtering to the framework alone just restates the badge.

    Every parameter is written out even where it matches a default, which is
    where this deliberately parts company with writeHash(). The board restores
    lb-types and lb-showtuned from localStorage *before* restoreFromHash() runs
    (index.html:1321-1325), and the hash only overrides what it actually
    carries — so a link that omits type= lands a returning visitor on whatever
    league they last filtered to, which for a flagship badge can be a table its
    framework is not in. Spelling it out costs a few characters and makes the
    destination independent of the visitor.

    Parameter order still follows writeHash(): scope, type, tuned.
    """
    parts = []
    if scope != "h1":
        parts.append("scope=" + scope)
    parts.append("type=" + ",".join(sorted(types)))
    parts.append("tuned=1" if show_tuned else "tuned=0")
    if lang:
        # lang=, not q=. The search box matches substrings across name, language
        # and engine, so q=C pulls in 73 of 78 entries and q=V pulls 33 — the
        # denominator would not survive being counted.
        parts.append("lang=" + quote(lang, safe=""))
    return SITE + "/#" + "&".join(parts)


def _badge_color(rank, total):
    """Rank tier, scaled to the field so a 12-entry family isn't graded like a
    90-entry one. Gold for the win, then decile / quartile / half."""
    if rank == 1:
        return "e3b341"
    pct = rank / total
    if rank <= 3 or pct <= 0.10:
        return "brightgreen"
    if pct <= 0.25:
        return "green"
    if pct <= 0.50:
        return "yellowgreen"
    return "blue"


def write_badges(profiles, results, meta):
    """shields.io endpoint documents, plus an index of everything written.

    Path is /badge/<framework>/<family>[-<language>][-with-tuned].json:

        h1.json                  rank among standard entries      (the default)
        h1-with-tuned.json       rank with tuned entries counted
        h1-rust.json             ...same, narrowed to one language
        h1-rust-with-tuned.json

    Both suffixes are filters, not rescores: same scores, same order, a smaller
    field. That is what the board does with rescale off, so a badge and the page
    it links to never disagree about who is ahead of whom.

    The default excludes tuned entries, so the number compares like-for-like
    against stock configurations. A tuned entry has no place in that field, so
    for those the default *is* the tuned-inclusive ranking — the smallest field
    the entry actually belongs to. Otherwise /badge/<tuned-entry>/h1.json would
    have to 404, and it is a URL people have already pasted.
    """
    if BADGE_OUT.exists():
        shutil.rmtree(BADGE_OUT)
    agg = badge_aggregate(profiles, results)
    fw_lang = _fw_languages(results)

    # A language added later must not land on an existing slug — two languages
    # sharing one would silently overwrite each other's badges.
    by_slug = {}
    for lang in sorted(set(fw_lang.values())):
        by_slug.setdefault(_lang_slug(lang), []).append(lang)
    clashes = {s: v for s, v in by_slug.items() if len(v) > 1}
    if clashes:
        raise SystemExit(f"badge: languages share a URL slug, fix _lang_slug(): {clashes}")

    index, written = {}, 0

    is_tuned = lambda fw: meta.get(fw, {}).get("mode", "standard") == "tuned"

    def emit(fw, scope, types, rank, total, score, lang=None, with_tuned=False,
             alias=False):
        """One endpoint document + its index entry.

        `alias` writes the default filename for a tuned entry, whose ranking can
        only come from the tuned-inclusive field.
        """
        nonlocal written
        slug, tier = _slug(fw), meta.get(fw, {}).get("type", "emerging")
        name = scope + (f"-{_lang_slug(lang)}" if lang else "") \
                     + ("-with-tuned" if with_tuned and not alias else "")
        doc = {
            "schemaVersion": 1,
            "label": "HTTP Arena " + FAMILY_LABEL[scope],
            "message": f"#{rank} of {total}" + (f" ({lang})" if lang else ""),
            "color": _badge_color(rank, total),
            "labelColor": TYPE_COLOR.get(tier, TYPE_COLOR_FALLBACK),
            "cacheSeconds": BADGE_CACHE_SECONDS,
        }
        path = BADGE_OUT / slug / f"{name}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(doc, separators=(",", ":")) + "\n", encoding="utf-8")
        written += 1
        # The maintainer should not have to assemble any of this: the index
        # carries the finished line to paste, deep-linked to the view that
        # produced the number.
        link = _badge_link(scope, types, lang, with_tuned)
        shield = f"https://img.shields.io/endpoint?url={SITE}/badge/{slug}/{name}.json"
        e = index.setdefault(slug, {"framework": fw, "type": tier,
                                    "language": fw_lang.get(fw, ""),
                                    "tuned": is_tuned(fw), "scopes": {}})
        entry = {"rank": rank, "of": total, "score": round(score, 1), "link": link,
                 "markdown": f"[![HTTP Arena {FAMILY_LABEL[scope]}]({shield})]({link})"}
        key = ("withTuned" if with_tuned and not alias else "default")
        if lang:
            key = "byLanguage" + ("WithTuned" if with_tuned and not alias else "")
        e["scopes"].setdefault(scope, {})[key] = entry

    def ranked(rows):
        """(fw, rank, total, score) with competition ranking — ties share a rank."""
        out, prev_score, prev_rank = [], None, 0
        for i, (fw, score) in enumerate(rows):
            rank = prev_rank if (prev_score is not None and abs(prev_score - score) < 1e-9) else i + 1
            prev_score, prev_rank = score, rank
            out.append((fw, rank, len(rows), score))
        return out

    def publish(rows, scope, types, lang, with_tuned):
        if len(rows) < BADGE_MIN_FIELD:
            return
        for fw, rank, total, score in ranked(rows):
            # Counted in the field above, but no badge of its own: a 0 means the
            # entry ran nothing that scores in this family, so "#31 of 31" would
            # read as a placing it never competed for.
            if score <= 0:
                continue
            # A tuned entry is absent from the default field entirely, so its
            # place in the tuned-inclusive one is also what its default URL
            # serves. Written twice rather than left to 404.
            if with_tuned and is_tuned(fw):
                emit(fw, scope, types, rank, total, score, lang, True, alias=True)
            emit(fw, scope, types, rank, total, score, lang, with_tuned)

    for scope in FAMILY_LABEL:
        for types in LEAGUES:
            for with_tuned in (False, True):
                rows = badge_composite(agg, profiles, meta, scope, types,
                                       show_tuned=with_tuned)
                publish(rows, scope, types, None, with_tuned)
                for lang in sorted({fw_lang.get(fw, "") for fw, _ in rows} - {""}):
                    sub = badge_composite(agg, profiles, meta, scope, types,
                                          show_tuned=with_tuned, lang=lang,
                                          fw_lang=fw_lang)
                    publish(sub, scope, types, lang, with_tuned)

    BADGE_OUT.mkdir(parents=True, exist_ok=True)
    (BADGE_OUT / "index.json").write_text(
        json.dumps(index, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    return written, len(index)


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
    n_badges, n_badge_fw = write_badges(profiles, results, meta)

    n_rows = sum(len(v) for v in results.values())
    print(f"wrote {OUT.relative_to(ROOT)} - {len(profiles)} profiles, "
          f"{len(results)} views, {n_rows} rows, {OUT.stat().st_size // 1024} KB")
    print(f"wrote {DOCS_OUT.relative_to(ROOT)}/ - {n_pages} static doc pages")
    print(f"wrote {(OUT.parent / 'search.js').relative_to(ROOT)} - {n_search} indexed pages, {search_bytes // 1024} KB")
    print(f"wrote {(GEN / 'sitemap.xml').relative_to(ROOT)} - {n_urls} URLs")
    print(f"wrote {BADGE_OUT.relative_to(ROOT)}/ - {n_badges} badges over {n_badge_fw} frameworks")


if __name__ == "__main__":
    main()
