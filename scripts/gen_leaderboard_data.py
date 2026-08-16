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
import subprocess
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
#   s/es/is:   scored / engineScored / infraScored eligibility flags.
# scored conns are always a subset of explorer conns.
#
# The three flags are three leagues, not three strictness levels. engineScored
# narrows the framework set — an engine is scored on a subset of what a
# framework is. infraScored does not: proxies are scored on Pipelined, which
# frameworks stopped scoring in #1058, so `is` is read on its own rather than
# behind `s`. scoredForType() in index.html is the one place that decides.
CATALOG = [
    ("Connection", [
        ("baseline",     "Baseline",    "Mixed GET/POST with query parsing.",       [512,4096,16384],[512,4096], True,True,True),
        ("pipelined",    "Pipelined",   "16x batched HTTP/1.1 pipelining (reference).", [512,4096,16384],[512,4096], False,False,True),
        ("limited-conn", "Short-lived", "Connections close after 10 requests.",     [512,4096],      [512,4096], True,True,True),
    ]),
    ("Workload", [
        ("json",      "JSON",            "Per-request JSON serialization.",          [4096],              [4096],          True,False,True),
        ("json-comp", "JSON Comp", "gzip/brotli content negotiation.",         [512,4096,16384],    [512,4096,16384],True,False,False),
        ("json-tls",  "JSON TLS",        "JSON over HTTP/1.1 + TLS.",                [4096],              [4096],          True,True,True),
        ("upload",    "Upload",          "Large request-body ingestion.",            [32,64,256,512],     [32,256],        True,False,False),
        ("static",    "Static",          "20-file static asset serving.",            [1024,4096,6800,16384],[1024,4096,6800],True,False,True),
        ("static-tls","Static TLS",      "20-file static serving over TLS.",         [1024,4096,6800],    [1024,4096,6800],True,False,True),
    ]),
    ("Database", [
        ("async-db",  "Async DB",  "Async Postgres sequential scan.",                [1024],     [1024],  True,True,False),
        ("crud",      "CRUD",      "REST API: list, cached read, upsert, update.",   [4096],     [4096],  True,False,False),
        ("fortunes",  "Fortunes",  "DB query + HTML template render (reference).",    [1024],     [1024],  False,False,False),
    ]),
    ("Multi-endpoint", [
        ("api-4",  "API-4",  "Mixed workload, server capped at 4 CPUs.",       [256],  [256],  True,False,False),
        ("api-16", "API-16", "Mixed workload, server capped at 16 CPUs.",      [1024], [1024], True,False,False),
    ]),
    ("HTTP/2", [
        ("baseline-h2",  "Baseline",       "Baseline over h2 (TLS, ALPN).",          [256,1024],     [256,1024],     True,True,True),
        ("static-h2",    "Static",         "Static assets over h2 multiplexing.",    [256,1024],     [256,1024],     True,True,True),
        ("baseline-h2c", "Baseline (h2c)", "Baseline over cleartext h2.",            [256,1024,4096],[256,1024,4096],True,True,False),
        ("json-h2c",     "JSON (h2c)",     "JSON over cleartext h2.",                [1024,4096],    [1024,4096],    True,False,False),
    ]),
    ("HTTP/3", [
        ("baseline-h3", "Baseline", "Baseline over QUIC + TLS 1.3.",                 [64], [64], True,True,True),
        ("static-h3",   "Static",   "Static assets over QUIC.",                      [64], [64], True,True,True),
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
        ("echo-ws-limited",  "Echo Short-lived","WebSocket echo, 10 messages per connection.", [512,4096],[512,4096],True,True,False),
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
    # Infrastructure is scored on 11 of the profiles, not all of them, so its tab
    # appears only where the page actually states a rule for it. The other three
    # always render — an empty Standard panel is a page to fix, an absent
    # Infrastructure one just means proxies don't run that profile.
    if a.get("infrastructure"):
        spec.append(("infrastructure", "Infrastructure", "#0891b2"))
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
    ".fw-btn", ".fw-btn svg", ".fw-btn:hover",
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
    # The Frameworks button lives beside the board's round selector, which no
    # generated page has, so it is lifted separately rather than riding along
    # inside .top-links. Same rule as the rest of the chrome: read the board,
    # never retype it.
    fwbtn = re.search(r'<a class="fw-btn".*?</a>', html, re.S)
    if not (brand and links and style and fwbtn):
        raise SystemExit(f"gen: cannot read site chrome from {BOARD.relative_to(ROOT)} - "
                         "expected .brand, .top-links, .fw-btn and a <style> block")
    shared = [r for r in _top_level_rules(style.group(1)) if _is_shared(r)]
    if len(shared) < 40:
        raise SystemExit(f"gen: only {len(shared)} shared CSS rules found in "
                         f"{BOARD.relative_to(ROOT)} - the selector list is stale")
    # the board's brand link drives its in-page router; on a doc page it goes home
    brand_html = brand.group(1).strip().replace('href="#" id="brandHome"', 'href="/"')
    return (brand_html, links.group(1).strip(), "\n".join(shared),
            fwbtn.group(0).strip())


# Resolved once at import: the board's chrome, shared by every generated page.
_CHROME = board_chrome()

_THEME_INIT = ("<script>try{var t=localStorage.getItem('lb-theme');"
               "if(t)document.documentElement.setAttribute('data-theme',t);}catch(e){}</script>")
# search.js is the whole Knowledge Base as text - 290KB - and it was loaded on
# every doc page for a search box most readers never open. It is fetched on the
# first use of the box instead.
_NAV_JS = ("<script>(function(){"
           # accordion: same behaviour as the board's toggleGrp
           "document.querySelectorAll('.nav-grp-h .caret').forEach(function(c){"
           "c.onclick=function(e){e.preventDefault();e.stopPropagation();"
           "c.closest('.nav-grp').classList.toggle('open');};});"
           # page search over the index the generator emits
           "var inp=document.getElementById('navq'),box=document.getElementById('navResults'),"
           "tree=document.getElementById('navTree');if(!inp)return;"
           "var req=null,cb=null;"
           "function need(f){if(window.LB_SEARCH){f();return;}cb=f;if(req)return;"
           "req=document.createElement('script');req.src='/search.js';"
           "req.onload=function(){var g=cb;cb=null;if(g)g();};"
           # Run the pending callback on failure too, so the box answers "no
           # page matches" instead of staying blank forever, and clear req so
           # the next keystroke can retry the fetch.
           "req.onerror=function(){req=null;var g=cb;cb=null;if(g)g();};"
           "document.head.appendChild(req);}"
           "inp.addEventListener('focus',function(){need(function(){});},{once:true});"
           "function esc(s){return String(s).replace(/[&<>\"]/g,function(c){"
           "return {'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}[c];});}"
           "function snip(x,t){var i=x.toLowerCase().indexOf(t);if(i<0)return esc(x.slice(0,110));"
           "var a=Math.max(0,i-45),b=Math.min(x.length,i+t.length+75);"
           "return (a>0?'\u2026':'')+esc(x.slice(a,i))+'<mark>'+esc(x.slice(i,i+t.length))+'</mark>'"
           "+esc(x.slice(i+t.length,b))+(b<x.length?'\u2026':'');}"
           "function run(){var q=inp.value.trim().toLowerCase();"
           "if(!q){box.style.display='none';tree.style.display='';inp.setAttribute('aria-expanded','false');return;}"
           "var terms=q.split(/\\s+/).filter(Boolean),hits=[];"
           # Guarded the way the board's buildSearchIndex() guards it: a script
           # that loads but defines nothing (proxy error page, blocked fetch)
           # would otherwise throw on every keystroke for the rest of the visit.
           "(window.LB_SEARCH||[]).forEach(function(e){var t=(e.t||'').toLowerCase(),"
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
           "var t;inp.addEventListener('input',function(){clearTimeout(t);"
           "t=setTimeout(function(){if(!inp.value.trim())run();else need(run);},90);});"
           "inp.addEventListener('keydown',function(e){if(e.key==='Escape'){inp.value='';run();inp.blur();}});"
           "})();</script>")

_THEME_TOGGLE = ("<script>var b=document.getElementById('theme');if(b)b.onclick=function(){"
                 "var d=document.documentElement,c=d.getAttribute('data-theme')==='dark'||"
                 "(d.getAttribute('data-theme')!=='light'&&matchMedia('(prefers-color-scheme: dark)').matches);"
                 "var n=c?'light':'dark';d.setAttribute('data-theme',n);"
                 "try{localStorage.setItem('lb-theme',n);}catch(e){}};</script>")


def _doc_page(did, title, body_html, tree, seo_title="", description="",
              crumbs=None, og_url=""):
    url = SITE + _doc_url(did)
    # Authored metadata wins; the scraped first paragraph stays as the fallback
    # so a page that hasn't been given frontmatter yet still renders sensibly.
    desc = description or _meta_desc(body_html)
    t = _html.escape(seo_title or title)
    d = _html.escape(desc)
    # A doc is an article by one publisher, sitting somewhere in a tree. The
    # breadcrumb is the half that shows: search results print the trail instead
    # of the bare URL, which is what tells a reader that a page five levels deep
    # is documentation and not a stray file.
    graph = [
        {"@type": "TechArticle", "@id": url + "#article", "headline": seo_title or title,
         "name": title, "description": desc, "url": url, "inLanguage": "en",
         "mainEntityOfPage": url, "isPartOf": {"@id": SITE + "/#website"},
         "publisher": {"@id": SITE + "/#org"},
         "about": {"@id": SITE + "/#dataset"}},
    ] + _org_nodes()
    if crumbs:
        graph.append({"@type": "BreadcrumbList", "@id": url + "#crumbs",
                      "itemListElement": [{"@type": "ListItem", "position": i + 1,
                                           "name": name, "item": SITE + href}
                                          for i, (name, href) in enumerate(crumbs)]})
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
            + _og_meta(og_url)
            + _jsonld({"@context": "https://schema.org", "@graph": graph})
            + '<link rel="stylesheet" href="/docs/docs.css">'
            + "</head>")
    # Same markup and classes as the board's header, so crossing between /
    # and /docs/ doesn't change the chrome. The board-only controls (type
    # filters, round selector, hardware chips) are leaderboard state, not site
    # chrome, so they aren't carried over; everything else is identical.
    header = ('<body><header class="top">'
              '<div class="brand">' + _CHROME[0] + '</div>'
              '<a class="brand-sub" href="/docs/">Knowledge Base</a>'
              + _CHROME[3]
              + '<div class="top-links">' + _CHROME[1] + '</div>'
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
/* framework pages have no sidebar to sit next to */
.docs-layout.one-col{grid-template-columns:1fr;justify-items:center}
.docs-layout.one-col .doc-main{width:100%}
.fw-kind{color:var(--muted);font-size:.78rem}
/* the "compare these N entries" line under each language heading on /frameworks/ */
.fw-compare{margin:-.4rem 0 .6rem;font-size:.85rem}
/* the one-sentence answer at the top of a language page, before any table */
.lead-answer{font-size:1.02rem;line-height:1.6;padding:.85rem 1rem;margin:0 0 1rem;border-left:3px solid var(--accent);background:var(--panel-2);border-radius:0 8px 8px 0}
.doc-main{min-width:0;padding:1.6rem 2rem 4rem;max-width:900px}
.doc-wrap{max-width:none}
.nav-grp-link{display:block;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:inherit;font:inherit;text-decoration:none}
@media (max-width:820px){.docs-layout{grid-template-columns:1fr}.nav{position:static;height:auto;width:100%;border-right:0;border-bottom:1px solid var(--line)}.doc-main{padding:1.1rem 1.1rem 4rem;max-width:100%}.brand{width:auto}}
"""


def build_doc_pages(tree, content, trails=None, with_og=False):
    """Write a real static page per doc under site/generated/docs/<id>/index.html."""
    if not tree:
        return 0
    if DOCS_OUT.exists():
        shutil.rmtree(DOCS_OUT)
    DOCS_OUT.mkdir(parents=True, exist_ok=True)
    (DOCS_OUT / "docs.css").write_text(_docs_css(), encoding="utf-8")
    trails = trails or {}
    for did, d in content.items():
        page = _doc_page(did, d["t"] or "Knowledge Base", d["html"], tree,
                         seo_title=d.get("st", ""), description=d.get("d", ""),
                         crumbs=trails.get(did),
                         og_url=(_doc_url(did) + "og.png") if with_og else "")
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
    out.write_text(js_payload("LB_SEARCH", entries), encoding="utf-8")
    return len(entries), out.stat().st_size


def _last_commit_dates(*prefixes):
    """path -> the date it was last committed, in one `git log` pass.

    Wanted for <lastmod>, which is only worth publishing if it is true: a crawler
    that is told a page changed and finds it did not learns to ignore the field.
    A shallow clone cannot answer this - it holds one commit and would date the
    whole site to the last deploy - so it answers nothing and the sitemap goes
    out without lastmod rather than with a lie."""
    try:
        shallow = _git(["git", "rev-parse", "--is-shallow-repository"])
        if shallow.strip() == "true":
            print("[warn] shallow clone - sitemap goes out without lastmod "
                  "(set fetch-depth: 0 to get it)")
            return {}
        out = _git(["git", "log", "--pretty=format:%cI", "--name-only",
                               "--", *prefixes])
    except Exception as exc:                                   # no git, no history
        print(f"[warn] no git dates for the sitemap: {exc}")
        return {}

    dates, when = {}, None
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        if line[:1].isdigit() and "T" in line and "/" not in line:
            when = line[:10]
        elif when:
            dates.setdefault(line, when)                       # newest commit first
    return dates


def _git(args):
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True,
                          encoding="utf-8", check=True).stdout


def _doc_source_path(did):
    """The markdown a doc id came from, for its commit date."""
    section = DOCS / did / "_index.md" if did else DOCS / "_index.md"
    page = DOCS / (did + ".md")
    src = section if section.exists() else page
    return src.relative_to(ROOT).as_posix()


def write_sitemap(content, fw_entries=(), lang_pages=()):
    """Root, /frameworks/, every language summary, every framework and every /docs/<id>/."""
    # frameworks.json is in here because it supplies the type, mode, language,
    # repo and description on every framework page - dating those pages from the
    # results alone missed metadata edits entirely.
    dates = _last_commit_dates("site/content/docs", "site/data/results",
                               "site/data/frameworks.json")
    newest = max(dates.values(), default=None)

    urls = [(SITE + "/", newest), (SITE + "/frameworks/", newest)]
    # A framework page is dated from the whole corpus, not from its own results
    # file. Its headline is "rank N of M" across six families, recomputed every
    # build, so any other entry being added or re-run changes this page too.
    # Dating it from its own results said "unchanged for three weeks" on 69 of
    # them while the number on the page moved - which is the untrue lastmod this
    # function exists to avoid, just in the other direction.
    for lang in lang_pages:
        urls.append((SITE + _lang_url(lang), newest))
    for fw, _lang, _kind in fw_entries:
        urls.append((SITE + _fw_url(fw), newest))
    for did in sorted(content):
        urls.append((SITE + _doc_url(did), dates.get(_doc_source_path(did))))

    body = "".join("<url><loc>%s</loc>%s</url>"
                   % (loc, f"<lastmod>{mod}</lastmod>" if mod else "")
                   for loc, mod in urls)
    GEN.mkdir(parents=True, exist_ok=True)
    (GEN / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' + body + "</urlset>\n",
        encoding="utf-8")
    return len(urls), sum(1 for _, mod in urls if mod)


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
# ranks as one field; engine and infrastructure entries are each scored on their
# own profile set, so a framework's 100 is never set by an engine's or a proxy's
# result (and vice versa).
LEAGUES = [("flagship", "emerging"), ("engine",), ("experimental",),
           ("infrastructure",)]

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
    "flagship":       "1b7a4e",   # green
    "emerging":       "2b5694",   # blue
    "experimental":   "8a5a12",   # amber
    "engine":         "b0463a",   # terracotta
    "infrastructure": "277482",   # teal — 5.4:1 on white
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
        """scoredForType() in index.html. infraScored is read before the
        `scored` short-circuit, not behind it: the infra set is not a subset of
        the framework set — it counts Pipelined, which frameworks do not."""
        p = prof[pid]
        t = meta.get(fw, {}).get("type", "emerging")
        if t == "infrastructure":
            return bool(p["infraScored"])
        if not p["scored"]:
            return False
        if t == "engine":
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
    return written, index


# ── off-site visibility: social cards, structured data, llms.txt, prerender ──
# The board is drawn by data.js, so whatever does not run JavaScript arrives on
# an empty page. Google renders and catches up; the crawlers behind the AI
# answers do not, and neither does a single link unfurler on X, Reddit, Discord
# or Slack. The ranking, which is the whole reason the site exists, is invisible
# to all of them, and so is every framework name in it.
#
# Three things fix that and none of them change what a visitor sees:
#   - the default view (H/1.1 composite, the same one the badges are pinned to)
#     is written into index.html at build time and overwritten by renderComposite
#     on boot, so the page has its ranking in the HTML;
#   - every page gets an og:image and a JSON-LD node, so a shared link unfurls
#     and the results are declared as a Dataset;
#   - /llms.txt and /llms-full.txt carry the same ranking and the Knowledge Base
#     as plain text, for readers that will never run a script.

OG_SIZE = (1200, 630)
OG_BG = (26, 27, 30)
OG_ACCENT = (138, 180, 248)
OG_TEXT = (232, 234, 237)
OG_MUTED = (154, 160, 166)

SCOPE_NAME = {"h1": "HTTP/1.1", "h2": "HTTP/2", "h3": "HTTP/3",
              "gw": "Gateway", "grpc": "gRPC", "ws": "WebSocket"}
SCOPE_BLURB = {"h1": "all HTTP/1.1 profiles", "h2": "all HTTP/2 profiles",
               "h3": "all HTTP/3 profiles", "gw": "the gateway & production-stack profiles",
               "grpc": "all gRPC profiles", "ws": "all WebSocket profiles"}
# The board's own default: view=composite, scope=h1, flagship+emerging, tuned
# shown, useMem and rescale off. Prerendering anything else would show a crawler
# a page no visitor lands on.
DEFAULT_SCOPE = "h1"
DEFAULT_TYPES = ("flagship", "emerging")

SITE_DESC = ("Independent webserver benchmarks across every major framework and protocol "
             "(H1, H2, H3, gRPC, WebSocket) in multiple categories.")


def _og_ready():
    """Whether this machine can draw the cards. Pillow is a deploy-time
    dependency and a local run without it should still produce a site: the
    pages simply come out without og:image rather than not at all."""
    try:
        import PIL  # noqa: F401
        return True
    except ImportError:
        return False


def _og_font(size, bold=False):
    from PIL import ImageFont
    names = ("DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf") if bold else \
            ("DejaVuSans.ttf", "LiberationSans-Regular.ttf")
    for base in ("/usr/share/fonts/truetype/dejavu/",
                 "/usr/share/fonts/truetype/liberation/", ""):
        for n in names:
            try:
                return ImageFont.truetype(base + n, size)
            except OSError:
                continue
    try:
        return ImageFont.load_default(size=size)   # Pillow >= 10.1: scalable
    except TypeError:
        return ImageFont.load_default()


def _og_wrap(draw, text, font, width, maxlines):
    lines, cur = [], ""
    for word in str(text).split():
        nxt = (cur + " " + word).strip()
        if cur and draw.textlength(nxt, font=font) > width:
            lines.append(cur)
            cur = word
            if len(lines) == maxlines:
                lines[-1] = lines[-1].rstrip(" .") + "…"
                return lines
        else:
            cur = nxt
    if cur:
        lines.append(cur)
    return lines


def _og_card(dest, kicker, title, rows, footer, blurb=""):
    """A 1200x630 card in the board's dark palette: wordmark, kicker, title, and
    an optional monospaced block (the top of the ranking, on the root card)."""
    from PIL import Image, ImageDraw
    img = Image.new("RGB", OG_SIZE, OG_BG)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, OG_SIZE[0], 9], fill=OG_ACCENT)

    mark = _og_font(36, bold=True)
    d.text((72, 58), "Http", font=mark, fill=OG_ACCENT)
    d.text((72 + d.textlength("Http", font=mark), 58), "Arena", font=mark, fill=OG_TEXT)

    y = 158
    if kicker:
        f = _og_font(26)
        d.text((72, y), _og_wrap(d, kicker, f, 1056, 1)[0], font=f, fill=OG_MUTED)
        y += 46

    # The ranking needs half the card, so a title sharing the space with one gets
    # two lines and a smaller face; a doc title, which is alone here, gets three.
    size, lead, maxlines = (54, 66, 2) if rows else (62, 76, 3)
    ft = _og_font(size, bold=True)
    for line in _og_wrap(d, title, ft, 1056, maxlines):
        d.text((72, y), line, font=ft, fill=OG_TEXT)
        y += lead

    if blurb and not rows:
        fb = _og_font(29)
        y += 18
        for line in _og_wrap(d, blurb, fb, 1056, 4):
            d.text((72, y), line, font=fb, fill=OG_MUTED)
            y += 40

    if rows:
        y = max(y + 22, 350)
        fr = _og_font(29, bold=True)
        for i, (name, right) in enumerate(rows[:5]):
            d.text((72, y), f"{i + 1}.", font=fr, fill=OG_MUTED)
            d.text((122, y), name, font=fr, fill=OG_TEXT)
            d.text((1128 - d.textlength(right, font=fr), y), right, font=fr, fill=OG_ACCENT)
            y += 40

    if footer:
        f = _og_font(23)
        d.text((72, 566), _og_wrap(d, footer, f, 1056, 1)[0], font=f, fill=OG_MUTED)

    dest.parent.mkdir(parents=True, exist_ok=True)
    # Flat background, four ink colours and the antialiasing between them: a
    # palette holds all of it and is a quarter of the truecolor file. 132 cards
    # ship with the site, so it is worth the one line.
    img = img.convert("P", palette=Image.ADAPTIVE, colors=64)
    img.save(dest, "PNG", optimize=True)


def _og_meta(url):
    """og:image tags for one page, or nothing when the cards were not drawn."""
    if not url:
        return ""
    return ('<meta property="og:image" content="' + SITE + url + '">'
            '<meta property="og:image:width" content="1200">'
            '<meta property="og:image:height" content="630">'
            '<meta name="twitter:card" content="summary_large_image">')


def _jsonld(payload):
    """A ld+json block. The escape is the one thing that matters here: an
    unescaped </script> inside the JSON ends the block early."""
    body = json.dumps(payload, separators=(",", ":")).replace("</", "<\\/")
    return '<script type="application/ld+json">' + body + "</script>"


def _crumb_trails(tree):
    """doc id -> [(title, url), ...] from the root of the Knowledge Base down to
    the page itself. Same walk the search index does, kept separate because that
    one only needs the label and this one needs the links too."""
    trails = {}

    def walk(node, trail):
        here = trail + [(node["t"], _doc_url(node["u"]))]
        trails[node["u"]] = here
        for child in node.get("c") or []:
            walk(child, here)

    if tree:
        walk(tree, [])
    return trails


def _org_nodes():
    """The two nodes every page's graph points at, so the site is one publisher
    and not one anonymous publisher per page."""
    return [
        {"@type": "Organization", "@id": SITE + "/#org", "name": "HttpArena",
         "url": SITE + "/", "logo": SITE + "/favicon.svg",
         "sameAs": ["https://github.com/MDA2AV/HttpArena"]},
        {"@type": "WebSite", "@id": SITE + "/#website", "url": SITE + "/",
         "name": "HttpArena", "inLanguage": "en",
         "publisher": {"@id": SITE + "/#org"}},
    ]


def _dataset_node(current, n_entries, n_profiles, round_name):
    """`n_entries` is every entry the dataset covers, not the default board view.
    It was the latter, so the sentence claimed its 97 flagship-and-emerging rows
    included "HTTP engines and reverse proxies" — two tiers that field excludes
    by definition — while the data.json it points at carried all of them."""
    hw = " ".join(x for x in [current.get("cpu", ""), current.get("os", "")] if x)
    return {
        "@type": "Dataset", "@id": SITE + "/#dataset",
        "name": "HttpArena web server benchmark results",
        "description": (f"Throughput, latency, CPU and memory for {n_entries} web frameworks, "
                        f"HTTP engines and reverse proxies over {n_profiles} benchmark profiles "
                        f"(HTTP/1.1, HTTP/2, HTTP/3, gRPC and WebSocket), every entry run on the "
                        f"same machine{' - ' + hw if hw else ''}."),
        "url": SITE + "/", "isAccessibleForFree": True, "inLanguage": "en",
        "license": "https://github.com/MDA2AV/HttpArena/blob/main/LICENSE",
        "creator": {"@id": SITE + "/#org"}, "publisher": {"@id": SITE + "/#org"},
        "keywords": ["web server benchmark", "http benchmark", "framework performance",
                     "requests per second", "latency", "HTTP/2", "HTTP/3", "gRPC", "WebSocket"],
        "measurementTechnique": ("Closed-loop load generation against containerised servers pinned "
                                 "to dedicated cores on a single machine, one connection count per run."),
        "variableMeasured": [{"@type": "PropertyValue", "name": n} for n in
                             ("Requests per second", "Average latency", "p99 latency",
                              "CPU utilisation", "Peak memory", "Bandwidth")],
        "version": round_name,
        "distribution": [{"@type": "DataDownload", "encodingFormat": "application/json",
                          "contentUrl": SITE + "/data.json",
                          "name": "Every published result, as one JSON document"}],
    }


def _ranking_node(scope, rows):
    # numberOfItems counts what the list actually carries. It used to report the
    # whole field while serialising the top 20, so the node contradicted itself.
    listed = rows[:20]
    return {
        "@type": "ItemList", "@id": SITE + "/#ranking-" + scope,
        "name": SCOPE_NAME[scope] + " composite ranking (top %d)" % len(listed),
        "itemListOrder": "https://schema.org/ItemListOrderDescending",
        "numberOfItems": len(listed),
        "itemListElement": [{"@type": "ListItem", "position": i + 1, "name": fw}
                            for i, (fw, _) in enumerate(listed)],
    }


def js_payload(name, payload):
    """`window.<name> = JSON.parse('...')`, the form the board's data ships in.

    V8 parses a JSON string roughly three times faster than the equivalent
    object literal: measured on this payload, compile plus execute went from
    18.1ms to 5.6ms (medians of nine cold runs, node 26). It is main-thread time
    on every visit and it costs nothing to save.

    The JSON goes inside single quotes, because it is full of double ones and
    escaping them all is what makes this trick cost 16% of the file elsewhere.
    ensure_ascii keeps the output free of raw line terminators, so a backslash
    and an apostrophe are the only characters left to escape - 62 of them in
    722KB, and the file comes out byte for byte the same size as the literal.
    """
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=True)
    return f"window.{name} = JSON.parse('" + body.replace("\\", "\\\\").replace("'", "\\'") + "');\n"


def write_data_json(payload):
    """The same document data.js assigns to window.LB_DATA, as plain JSON.

    data.js is a script and can only be consumed by running it; this is the file
    the Dataset node above points at, and the one anybody scripting against the
    results should read."""
    GEN.mkdir(parents=True, exist_ok=True)
    out = GEN / "data.json"
    out.write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
    return out.stat().st_size


def _rank_lines(rows, fw_lang, limit=None):
    return ["%3d. %-26s %-14s %6.0f" % (i + 1, fw, fw_lang.get(fw, "") or "-", score)
            for i, (fw, score) in enumerate(rows[:limit] if limit else rows)]


def write_llms_txt(tree, content, families, fw_lang, current, round_name, fw_entries=()):
    """/llms.txt and /llms-full.txt.

    Same reason as the prerender, for the readers the prerender cannot reach:
    the board has six families and only the default one can be written into the
    page. Here all six fit, as text, next to a link to every doc."""
    trails = _crumb_trails(tree)
    hw = current.get("cpu", "")
    head = [
        "# HttpArena",
        "",
        "> " + SITE_DESC,
        "",
        "Every entry runs in a container on the same machine"
        + (f" ({hw}, {current.get('cores', '?')} cores)" if hw else "")
        + ", pinned to dedicated cores, one connection count per run. Round: " + round_name + ".",
        "",
        "The leaderboard at " + SITE + "/ is rendered client-side, so the ranking below is the "
        "same data as text. Scores are the composite: each profile is worth 100 to the best entry "
        "in the field and a framework's score is the sum over the profiles of that family.",
        "",
    ]

    short, full = list(head), list(head)
    for scope, rows in families:
        if not rows:
            continue
        title = f"## {SCOPE_NAME[scope]} composite ranking - flagship and emerging, {len(rows)} entries"
        short += [title, "", "```", *_rank_lines(rows, fw_lang, 20), "```", ""]
        if len(rows) > 20:
            short += [f"Full field: {SITE}/llms-full.txt", ""]
        full += [title, "", "```", *_rank_lines(rows, fw_lang), "```", ""]

    frameworks = []
    if fw_entries:
        frameworks = [f"## Frameworks ({len(fw_entries)} entries, one results page each)", ""]
        for fw, lang, kind in fw_entries:
            frameworks.append(f"- [{fw}]({SITE}{_fw_url(fw)}): "
                              + ", ".join(x for x in [lang, TYPE_LABEL.get(kind, kind)] if x)
                              + ". Rank per family and every per-profile number.")
        frameworks.append("")

    docs = ["## Documentation", ""]
    for did in sorted(content):
        d = content[did]
        crumb = " > ".join(t for t, _ in trails.get(did, [])[:-1])
        desc = d.get("d") or _meta_desc(d["html"])
        docs.append(f"- [{d['t'] or 'Knowledge Base'}]({SITE}{_doc_url(did)})"
                    + (f" ({crumb})" if crumb else "") + (f": {desc}" if desc else ""))
    docs.append("")

    data = ["## Data", "",
            f"- [data.json]({SITE}/data.json): every published result in one JSON document, "
            "the same one the board reads.",
            f"- [Badge endpoints]({SITE}/badge/index.json): per-framework rank, as shields.io endpoints.",
            f"- [Source and framework entries](https://github.com/MDA2AV/HttpArena): "
            "every server implementation, Dockerfile and validation rule.",
            ""]

    short += frameworks + docs + data + ["## Full text", "",
                                         f"- [llms-full.txt]({SITE}/llms-full.txt): the whole "
                                         "Knowledge Base and the full ranking of every family.", ""]
    full += frameworks + data + ["## Knowledge Base", ""]
    for did in sorted(content):
        d = content[did]
        text = _html.unescape(re.sub(r"<[^>]+>", " ", d["html"]))
        text = re.sub(r"[ \t]+", " ", text)
        text = re.sub(r"\n\s*\n\s*\n+", "\n\n", text).strip()
        full += [f"### {d['t'] or 'Knowledge Base'}", "", f"Source: {SITE}{_doc_url(did)}", "",
                 text, ""]

    GEN.mkdir(parents=True, exist_ok=True)
    (GEN / "llms.txt").write_text("\n".join(short), encoding="utf-8")
    (GEN / "llms-full.txt").write_text("\n".join(full), encoding="utf-8")
    return (GEN / "llms.txt").stat().st_size, (GEN / "llms-full.txt").stat().st_size


def _static_board(rows, fw_lang, round_name):
    """The default view as a plain table, for the HTML."""
    body = []
    for i, (fw, score) in enumerate(rows):
        rank = i + 1
        # the name links to the entry's own page: the only internal links to
        # those pages that exist without running a script
        body.append('<tr><td class="n%s">%d</td><td><a href="%s">%s</a></td>'
                    '<td class="sb-lang">%s</td><td class="n">%.0f</td></tr>'
                    % (" r%d" % rank if rank <= 3 else "", rank, _fw_url(fw),
                       _html.escape(fw), _html.escape(fw_lang.get(fw, "") or ""), score))
    others = ", ".join(SCOPE_NAME[s] for s in SCOPE_NAME if s != DEFAULT_SCOPE)
    return ('<table class="sb"><thead><tr><th>#</th><th>Framework</th><th>Language</th>'
            '<th class="n">Composite</th></tr></thead><tbody>' + "".join(body) + "</tbody></table>"
            '<p class="sb-note">' + _html.escape(round_name) + ", " + str(len(rows)) +
            " entries, best first. The interactive board - per-profile numbers, memory efficiency, "
            "the other families (" + _html.escape(others) + ") - needs JavaScript; every entry has "
            'a <a href="/frameworks/">page of its own</a>, and the same rankings are published as '
            'text at <a href="/llms.txt">/llms.txt</a>.</p>')


def build_index_page(rows, fw_lang, current, round_name, n_profiles, n_entries, og_url):
    """site/generated/index.html: the board with its default view already in it.

    Written from the checked-in page rather than replacing it, so the source
    stays the thing you open locally. Every marker is required to appear exactly
    once: if the board's markup moves, this fails the deploy instead of quietly
    shipping an empty page again."""
    src = (ROOT / "site" / "leaderboard" / "index.html").read_text(encoding="utf-8")

    # once() fails the deploy when the board's markup moves, but an empty
    # ranking used to sail through it: a 0-row table, "0 frameworks", a 0-item
    # ItemList and a blank social card, all with exit status 0. That is the same
    # "quietly shipping an empty page" this function was written to stop, just
    # reached through the data rather than the markup.
    if not rows:
        raise SystemExit("[fatal] prerender: the default composite view is empty - "
                         "refusing to publish a board with no ranking")

    def once(html, needle, repl, what):
        if html.count(needle) != 1:
            raise SystemExit(f"[fatal] prerender: expected exactly one {what} in "
                             f"site/leaderboard/index.html, found {html.count(needle)}")
        return html.replace(needle, repl, 1)

    graph = _org_nodes() + [
        _dataset_node(current, n_entries, n_profiles, round_name),
        _ranking_node(DEFAULT_SCOPE, rows),
    ]
    # The theme has to be applied before the first paint. Every other page this
    # generator writes inlines _THEME_INIT in its head; the board did not need it
    # while #rows was empty, because only bare chrome could flash. Now that a
    # full ranking paints before any script runs, a dark-mode reader would watch
    # the whole table render light and then invert.
    head = (_THEME_INIT
            + '<meta property="og:type" content="website">'
            '<meta property="og:site_name" content="HttpArena">'
            '<meta property="og:title" content="HTTP Web Server Benchmarks – HttpArena">'
            '<meta property="og:description" content="' + _html.escape(SITE_DESC) + '">'
            '<meta property="og:url" content="' + SITE + '/">'
            + _og_meta(og_url)
            + _jsonld({"@context": "https://schema.org", "@graph": graph}))

    # The three header fields renderHead() fills for the default view, filled
    # with the same strings so the pre-rendered page and the rendered one say
    # the same thing.
    blurb = ("Normalized score summed across " + SCOPE_BLURB[DEFAULT_SCOPE] +
             " (each profile worth 100 to its leader in the full field, so filtering does not "
             'change the numbers), per framework type. Higher is better. '
             '<a href="/docs/scoring/composite-score/">How it works →</a>')

    out = once(src, "</head>", head + "</head>", "</head>")
    out = once(out, '<div class="cat" id="pcat"></div>',
               '<div class="cat" id="pcat">Composite ranking</div>', "#pcat")
    out = once(out, '<h1 id="ptitle"></h1>',
               '<h1 id="ptitle">' + SCOPE_NAME[DEFAULT_SCOPE] + "</h1>", "#ptitle")
    out = once(out, '<p id="pblurb"></p>', '<p id="pblurb">' + blurb + "</p>", "#pblurb")
    out = once(out, '<span class="count" id="count"></span>',
               '<span class="count" id="count">' + str(len(rows)) + " frameworks</span>", "#count")
    out = once(out, '<div id="rows"></div>',
               '<div id="rows">' + _static_board(rows, fw_lang, round_name) + "</div>", "#rows")

    GEN.mkdir(parents=True, exist_ok=True)
    (GEN / "index.html").write_text(out, encoding="utf-8")
    return (GEN / "index.html").stat().st_size


# ── a page per framework ─────────────────────────────────────────────────────
# The board is one URL. Every state it can be in is a #hash, and a hash is not a
# page: "axum benchmark" has nowhere to land, and a framework that is in here has
# nothing of its own to be found by. These pages are that missing half - one URL
# per entry, carrying its rank in every family it runs and every number behind
# it, from the same data the board draws.

FW_OUT = GEN / "frameworks"

TYPE_LABEL = {"flagship": "Flagship", "emerging": "Emerging",
              "experimental": "Experimental", "engine": "Engine",
              "infrastructure": "Infrastructure"}

# Standard/Tuned is a framework distinction. Engines and reverse proxies have no
# mode in meta.json, so nothing should claim one on their behalf.
MODE_TYPES = ("flagship", "emerging", "experimental")


def kind_has_mode(kind):
    return kind in MODE_TYPES


# What an entry of this tier is, in a sentence. Used where prose would otherwise
# call a reverse proxy a web framework.
_KIND_NOUN = {"engine": "an HTTP engine",
              "infrastructure": "a reverse proxy or static-file server"}


def _a_kind(kind):
    return _KIND_NOUN.get(kind, "a web framework")


def _fw_url(fw):
    return "/frameworks/" + _slug(fw) + "/"


def _lang_url(lang):
    # Under lang/ rather than beside the entries: _lang_slug keeps C, C# and C++
    # apart, but a language and a framework could still want the same segment.
    return "/frameworks/lang/" + _lang_slug(lang) + "/"




def _published_rank(scope_entry):
    """The rank to quote for one entry and family: the smallest published field
    it actually belongs to.

    `default` is the tuned-excluded field and is right for almost everyone. Two
    kinds of entry have none. A tuned entry is absent from that field, and
    write_badges already aliases the tuned-inclusive one into `default` for it.
    The mirror case has no alias: a standard entry whose tuned-excluded field
    holds only itself is skipped by BADGE_MIN_FIELD, so nothing is published
    under `default` at all - effinitive, the one standard entry among two
    experimental ones. Reading `default` alone dropped the Composite rank
    section off its page and had the language summary claim it had no composite,
    when it has 808 on H/1.1.
    """
    return (scope_entry or {}).get("default") or (scope_entry or {}).get("withTuned")


def _fw_ranks(fw, badge_index):
    """[(family, rank, field size, score, board link)] straight out of the badge index.

    Read from write_badges()' own index rather than recomputed. The badge is
    already this project's published answer to "where does this entry place",
    and it applies four rules a second implementation got wrong: competition
    ranking so ties share a place, no rank from a field of one, nothing for an
    entry whose composite is 0 (it never competed), and the tuned-excluded
    field for standard entries with the tuned-inclusive one aliased in for
    tuned ones. The link comes from the same place, so the page deep-links to
    the board view the number was taken in — filtered to the right league —
    instead of to whatever the visitor last looked at.

    A page that disagrees with the badge about the same entry is worse than a
    page that omits the number, and these were disagreeing on all 71 standard
    H/1.1 entries.
    """
    scopes = (badge_index.get(_slug(fw)) or {}).get("scopes", {})
    out = []
    for scope in SCOPE_NAME:
        d = _published_rank(scopes.get(scope))
        if d:
            out.append((scope, d["rank"], d["of"], d["score"], d["link"]))
    return out


def _fw_results(fw, profiles, results):
    """[(profile, conns, row)] in catalog order - every run this entry has."""
    out = []
    for p in profiles:
        for c in p["conns"]:
            for r in results.get(f"{p['id']}-{c}", []):
                if r["fw"] == fw:
                    out.append((p, c, r))
                    break
    return out


def _fw_body(fw, m, lang, ranks, runs, round_name, lang_url=""):
    e = _html.escape
    facts = [TYPE_LABEL.get(m.get("type", "emerging"), m.get("type", "")), lang]
    if m.get("engine") and m["engine"] != fw:
        facts.append("engine: " + m["engine"])
    # mode is a framework-only field. Engines and reverse proxies never declare
    # one, and the board's modal shows nothing for them, so asserting "standard
    # configuration" on all 44 of them made the crawlable page say something the
    # interactive board does not.
    if kind_has_mode(m.get("type", "emerging")):
        facts.append("tuned configuration" if m.get("mode") == "tuned"
                     else "standard configuration")
    out = ["<p>" + e(" · ".join(x for x in facts if x)) + "</p>"]
    if m.get("desc"):
        out.append("<p>" + e(m["desc"]) + "</p>")

    links = []
    if m.get("repo"):
        links.append('<li><a href="%s" rel="noopener">Official repository</a></li>' % e(m["repo"]))
    links.append('<li><a href="https://github.com/MDA2AV/HttpArena/tree/main/frameworks/%s" '
                 'rel="noopener">Benchmark implementation</a></li>' % quote(m.get("dir") or fw))
    if lang_url:
        links.append('<li><a href="%s">All %s entries, compared</a></li>'
                     % (lang_url, e(lang)))
    links.append('<li><a href="/">Open the leaderboard</a></li>')
    out.append("<ul>" + "".join(links) + "</ul>")

    if ranks:
        out.append('<h2 id="rank">Composite rank</h2>')
        out.append("<p>Each profile of a family is worth 100 to the entry that leads it, and the "
                   "composite is the sum over the family. The field is this entry's own league: "
                   "engines and reverse proxies are scored apart from frameworks. "
                   '<a href="/docs/scoring/composite-score/">How it works</a>.</p>')
        rows = "".join(
            '<tr><td><a href="%s">%s</a></td><td>%d of %d</td><td>%.0f</td></tr>'
            % (e(link), e(SCOPE_NAME[scope]), rank, field, score)
            for scope, rank, field, score, link in ranks)
        out.append("<table><thead><tr><th>Family</th><th>Rank</th><th>Composite</th></tr></thead>"
                   "<tbody>" + rows + "</tbody></table>")

    if runs:
        out.append('<h2 id="results">Every result</h2>')
        out.append("<p>%s, %d runs. Requests per second is the best of three; latency, CPU and "
                   "memory come from that run.</p>" % (e(round_name), len(runs)))
        body = "".join(
            "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td>"
            "<td>%s</td></tr>"
            % (e(p["category"]), e(p["label"]), f"{c:,}",
               f"{round(r.get('rps') or 0):,}" if r.get("rps") else "-",
               e(r.get("avg_latency") or "-"), e(r.get("p99_latency") or "-"),
               e(r.get("cpu") or "-"), e(r.get("memory") or "-"))
            for p, c, r in runs)
        out.append("<table><thead><tr><th>Category</th><th>Profile</th><th>Conns</th>"
                   "<th>Req/sec</th><th>Avg</th><th>p99</th><th>CPU</th><th>Memory</th></tr></thead>"
                   "<tbody>" + body + "</tbody></table>")

    out.append('<p><a href="/docs/">How the benchmark is run</a> · '
               '<a href="/docs/hardware/">The machine</a> · '
               '<a href="/docs/add-framework/">Add or fix an entry</a></p>')
    return '<div class="doc-body">' + "".join(out) + "</div>"


def _fw_page(fw, m, lang, ranks, runs, round_name, og_url, lang_url=""):
    e = _html.escape
    url = SITE + _fw_url(fw)
    title = f"{fw} benchmark results"
    # the main family when the entry runs it, its first one otherwise. Quoting
    # whichever rank happens to be best would read as picked, and be picked
    lead = next((r for r in ranks if r[0] == DEFAULT_SCOPE), ranks[0] if ranks else None)
    desc = (f"{fw}" + (f" ({lang})" if lang else "") + " in the HttpArena benchmark: "
            + (f"ranked {lead[1]} of {lead[2]} on {SCOPE_NAME[lead[0]]}, " if lead else "")
            + f"throughput, latency, CPU and memory over {len(runs)} runs on the same machine.")
    graph = [
        {"@type": "WebPage", "@id": url + "#page", "name": title, "description": desc,
         "url": url, "inLanguage": "en", "isPartOf": {"@id": SITE + "/#website"},
         "publisher": {"@id": SITE + "/#org"}, "about": {"@id": url + "#software"},
         "mainEntityOfPage": url},
        {"@type": "SoftwareApplication", "@id": url + "#software", "name": fw,
         "applicationCategory": "DeveloperApplication",
         **({"programmingLanguage": lang} if lang else {}),
         **({"codeRepository": m["repo"]} if m.get("repo") else {}),
         **({"description": m["desc"]} if m.get("desc") else {})},
        {"@type": "BreadcrumbList", "@id": url + "#crumbs", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "Frameworks",
             "item": SITE + "/frameworks/"},
            {"@type": "ListItem", "position": 2, "name": fw, "item": url}]},
    ] + _org_nodes()
    head = ('<!doctype html><html lang="en" data-theme=""><head>'
            '<meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            + _THEME_INIT
            + "<title>" + e(title) + " – HttpArena</title>"
            + '<meta name="description" content="' + e(desc) + '">'
            + '<link rel="canonical" href="' + url + '">'
            + '<link rel="icon" href="/favicon.ico" sizes="any">'
            + '<link rel="icon" href="/favicon.svg" type="image/svg+xml">'
            + '<meta property="og:type" content="article">'
            + '<meta property="og:site_name" content="HttpArena">'
            + '<meta property="og:title" content="' + e(title) + '">'
            + '<meta property="og:description" content="' + e(desc) + '">'
            + '<meta property="og:url" content="' + url + '">'
            + _og_meta(og_url)
            + _jsonld({"@context": "https://schema.org", "@graph": graph})
            + '<link rel="stylesheet" href="/docs/docs.css">'
            + "</head>")
    header = ('<body><header class="top">'
              '<div class="brand">' + _CHROME[0] + '</div>'
              '<a class="brand-sub" href="/frameworks/">Frameworks</a>'
              '<div class="top-links">' + _CHROME[1] + '</div>'
              '</header>')
    body = ('<div class="docs-layout one-col"><main class="doc-main">'
            '<article class="doc-wrap"><h1 class="doc-title">' + e(fw) + "</h1>"
            + _fw_body(fw, m, lang, ranks, runs, round_name, lang_url)
            + "</article></main></div>")
    return head + header + body + _THEME_TOGGLE + "</body></html>"


def _lang_faq(lang, scopes, n_entries, round_name):
    """[(question, answer)] for one language, generated from its own rows.

    "fastest <language> web framework" is the question these pages exist to
    answer, and it is a question people type and assistants get asked. Neither
    reads a table cell: they quote a sentence. So the answers are written out as
    sentences, from the same rows the tables are built from, and emitted again
    as FAQPage data so a machine reading the markup gets the same numbers.

    "Fastest" is the word people use; the composite is what is actually being
    compared, so each answer names it rather than letting the word stand alone.
    """
    e = _html.escape
    qa = []
    lead = scopes.get(DEFAULT_SCOPE) or (next(iter(scopes.values())) if scopes else None)
    if lead:
        fw, kind, tuned, score, rank, of, _link, lrank, lof = lead[0]
        # nginx is not a C web framework and swerver is not a Zig one. Ask the
        # question the leader can actually answer, and answer the framework one
        # separately with the quickest entry that is a framework.
        is_fw = kind_has_mode(kind)
        qa.append((
            f"What is the fastest {lang} web framework?" if is_fw
            else f"What is the fastest {lang} HTTP server?",
            f"{fw}"
            + ("" if is_fw else f", {_a_kind(kind)},")
            + f" leads the {lang} entries in HttpArena with a composite score of "
              f"{score:.0f} on {SCOPE_NAME[DEFAULT_SCOPE]}, measured over {round_name}. "
              f"The composite sums a normalized score across the profiles of a family, "
              f"where the leader of each profile scores 100. Against every language, "
              f"{fw} ranks {rank} of {of} in its own league."
            + (f" It is a tuned entry, so it is ranked in the field that includes "
               f"tuned configurations." if tuned else "")))
        if not is_fw:
            top_fw = next((r for r in lead if kind_has_mode(r[1])), None)
            if top_fw:
                qa.append((
                    f"What is the fastest {lang} web framework?",
                    f"{top_fw[0]}, with a composite of {top_fw[3]:.0f} on "
                    f"{SCOPE_NAME[DEFAULT_SCOPE]}. {fw} scores higher but is "
                    f"{_a_kind(kind)}, not a framework, and is ranked in its own league."))
    for scope, rows in scopes.items():
        if scope == DEFAULT_SCOPE or not rows:
            continue
        fw, _k, _t, score, rank, of, _l, _lr, _lo = rows[0]
        qa.append((
            f"What is the fastest {lang} {SCOPE_NAME[scope]} server?",
            f"{fw}, with a composite of {score:.0f} on {SCOPE_NAME[scope]} and "
            f"{rank} of {of} against all languages in its league."))
    qa.append((
        f"How many {lang} web frameworks are benchmarked?",
        f"{n_entries} {lang} " + ("entry is" if n_entries == 1 else "entries are")
        + f" measured, covering {', '.join(SCOPE_NAME[s] for s in scopes) or 'no family'}"
          f". Every one runs on the same machine, in the same round ({round_name}), "
          f"against the same profiles."))
    if lead:
        fw = lead[0][0]
        qa.append((
            f"Is {lang} fast for web servers?",
            f"The quickest {lang} entry, {fw}, places {lead[0][4]} of {lead[0][5]} on "
            f"{SCOPE_NAME[DEFAULT_SCOPE]} across every language in its league, so that "
            f"placing is the honest answer for {lang} at its best rather than for "
            f"{lang} in general. The tables below show the spread across all "
            f"{n_entries} " + ("entry" if n_entries == 1 else "entries") + "."))
    return [(e(q), e(a)) for q, a in qa]


def _lang_page(lang, scopes, all_entries, round_name):
    """/frameworks/lang/<language>/ - one language's entries, compared family by family.

    Every number is read out of the badge index, the same source the entry pages
    read. Nothing is recomputed and no placing is invented: the rows are ordered
    by composite and the only ranks shown are ones already published elsewhere.
    A position column would be a third implementation of the ranking, which is
    exactly what put the entry pages out of step with the badges (#1185).
    """
    e = _html.escape
    url = SITE + _lang_url(lang)
    title = lang + " web framework benchmarks"
    n = len(all_entries)
    fams = ", ".join(SCOPE_NAME[s] for s in scopes)
    faq = _lang_faq(lang, scopes, n, round_name)
    lead_row = (scopes.get(DEFAULT_SCOPE) or (next(iter(scopes.values())) if scopes else None))
    lead_fw = lead_row[0][0] if lead_row else ""
    # Description leads with the answer rather than describing the page: it is
    # the search snippet, and the first line an assistant reads.
    desc = ((f"The fastest {lang} "
             + ("web framework" if kind_has_mode(lead_row[0][1]) else "HTTP server")
             + f" in HttpArena is {lead_fw} "
               f"(composite {lead_row[0][3]:.0f} on {SCOPE_NAME[DEFAULT_SCOPE]}). "
             if lead_row else "")
            + f"All {n} {lang} entr{'y' if n == 1 else 'ies'} compared on {fams}: "
              f"composite score, rank overall and rank among {lang}.")

    tables = []
    for scope, rows in scopes.items():
        head_cells = ("<tr><th>Framework</th><th>Type</th><th>Composite</th>"
                      "<th>Rank overall</th><th>Rank among " + e(lang) + "</th></tr>")
        body = "".join(
            '<tr><td><a href="%s">%s</a></td><td>%s</td><td>%.0f</td>'
            '<td><a href="%s">%d of %d</a></td><td>%s</td></tr>'
            % (_fw_url(fw), e(fw),
               e(TYPE_LABEL.get(kind, kind)) + (' <span class="fw-kind">tuned</span>'
                                                if tuned else ""),
               score, e(link), rank, of,
               ("%d of %d" % (lrank, lof)) if lrank else "&mdash;")
            for fw, kind, tuned, score, rank, of, link, lrank, lof in rows)
        tables.append("<h2 id=\"%s\">%s</h2>" % (scope, e(SCOPE_NAME[scope]))
                      + "<table><thead>" + head_cells + "</thead><tbody>" + body
                      + "</tbody></table>")

    has_tuned = any(r[2] for rows in scopes.values() for r in rows)
    listed = {fw for rows in scopes.values() for fw, *_ in rows}
    rest = sorted((fw for fw, _k in all_entries if fw not in listed), key=str.lower)
    every = "".join('<li><a href="%s">%s</a></li>' % (_fw_url(fw), e(fw))
                    for fw, _k in sorted(all_entries, key=lambda x: x[0].lower()))

    graph = [
        {"@type": "CollectionPage", "@id": url + "#page", "name": title, "description": desc,
         "url": url, "inLanguage": "en", "isPartOf": {"@id": SITE + "/#website"},
         "publisher": {"@id": SITE + "/#org"}},
        {"@type": "BreadcrumbList", "@id": url + "#crumbs", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "Frameworks",
             "item": SITE + "/frameworks/"},
            {"@type": "ListItem", "position": 2, "name": lang, "item": url}]},
    ] + ([{"@type": "FAQPage", "@id": url + "#faq", "mainEntity": [
            {"@type": "Question", "name": q,
             "acceptedAnswer": {"@type": "Answer", "text": a}} for q, a in faq]}]
         if faq else []) + _org_nodes()
    head = ('<!doctype html><html lang="en" data-theme=""><head>'
            '<meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            + _THEME_INIT
            + "<title>" + e(title) + " – HttpArena</title>"
            + '<meta name="description" content="' + e(desc) + '">'
            + '<link rel="canonical" href="' + url + '">'
            + '<link rel="icon" href="/favicon.ico" sizes="any">'
            + '<link rel="icon" href="/favicon.svg" type="image/svg+xml">'
            + '<meta property="og:type" content="website">'
            + '<meta property="og:site_name" content="HttpArena">'
            + '<meta property="og:title" content="' + e(title) + '">'
            + '<meta property="og:description" content="' + e(desc) + '">'
            + '<meta property="og:url" content="' + url + '">'
            + _jsonld({"@context": "https://schema.org", "@graph": graph})
            + '<link rel="stylesheet" href="/docs/docs.css">'
            + "</head>")
    header = ('<body><header class="top">'
              '<div class="brand">' + _CHROME[0] + '</div>'
              '<a class="brand-sub" href="/frameworks/">Frameworks</a>'
              '<div class="top-links">' + _CHROME[1] + '</div>'
              '</header>')
    # The answer first, in a sentence, before any table. Both a reader skimming
    # and an assistant summarising take the first paragraph.
    answer = ""
    if lead_row:
        fw, kind, tuned, score, rank, of, link, _lr, _lo = lead_row[0]
        is_fw = kind_has_mode(kind)
        extra = ""
        if not is_fw:
            top_fw = next((r for r in lead_row if kind_has_mode(r[1])), None)
            if top_fw:
                extra = (' The quickest %s <i>framework</i> is <a href="%s"><b>%s</b></a>, '
                         'at %.0f.' % (e(lang), _fw_url(top_fw[0]), e(top_fw[0]), top_fw[3]))
        answer = ('<p class="lead-answer">The fastest %s %s in HttpArena is '
                  '<a href="%s"><b>%s</b></a>%s, with a composite of %.0f on %s &mdash; '
                  '<a href="%s">%d of %d</a> against every language in its league. '
                  'Measured over %s, every entry on the same machine.%s%s</p>'
                  % (e(lang), "web framework" if is_fw else "HTTP server",
                     _fw_url(fw), e(fw), "" if is_fw else " (%s)" % e(_a_kind(kind)),
                     score, e(SCOPE_NAME[DEFAULT_SCOPE]),
                     e(link), rank, of, e(round_name),
                     " This is a tuned entry." if tuned else "", extra))
    intro = ("<p>Every %s entry in the benchmark, compared on the composite score of each "
             "family. The composite sums a normalized score over the profiles of that family, "
             "where the leader of each profile scores 100. Rank overall is the entry's place in "
             "its own league across all languages; rank among %s narrows the same field to this "
             "language. Both link through to the board view they were taken in. "
             '<a href="/docs/scoring/composite-score/">How the score works</a>.</p>'
             % (e(lang), e(lang)))
    if has_tuned:
        # Composites are normalized over the whole league either way, so the
        # score column compares directly; only the field a rank is taken in
        # differs, which is why a tuned row's "of" is the larger number.
        intro += ("<p>Composite scores compare directly across every row. Ranks do not "
                  "always share a field: a tuned entry has no place in the standard-only "
                  "ranking, so its rank is taken from the field that includes tuned "
                  "entries and counts more of them.</p>")
    if rest:
        # "no composite" was wrong for an entry that has one but no publishable
        # rank; what these are missing is a place in a field worth ranking in.
        intro += ("<p>%s %s no published rank in any family yet, so %s below the "
                  "tables only.</p>"
                  % (", ".join(e(x) for x in rest),
                     "has" if len(rest) == 1 else "have",
                     "it is listed" if len(rest) == 1 else "they are listed"))
    body = ('<div class="docs-layout one-col"><main class="doc-main">'
            '<article class="doc-wrap"><h1 class="doc-title">' + e(title) + "</h1>"
            '<div class="doc-body">' + answer + intro + "".join(tables)
            + ("<h2 id=\"faq\">Questions</h2>"
               + "".join('<h3>%s</h3><p>%s</p>' % (q, a) for q, a in faq) if faq else "")
            + "<h2>Every " + e(lang) + " entry</h2><ul>" + every + "</ul>"
            + '<p>' + e(round_name) + ' · <a href="/frameworks/">All languages</a> · '
              '<a href="/">Open the leaderboard</a></p>'
            + "</div></article></main></div>")
    return head + header + body + _THEME_TOGGLE + "</body></html>"


def _fw_index_page(entries, lang_pages=()):
    """/frameworks/ - one link per entry, grouped by language. Also the page that
    makes every framework page reachable by following links from the board."""
    e = _html.escape
    url = SITE + "/frameworks/"
    title = "Every framework in the benchmark"
    desc = (f"All {len(entries)} frameworks, HTTP engines and reverse proxies measured by "
            "HttpArena, with a results page each.")
    by_lang = {}
    for fw, lang, kind in entries:
        by_lang.setdefault(lang or "Other", []).append((fw, kind))
    sections = []
    for lang in sorted(by_lang, key=lambda x: (x == "Other", x.lower())):
        items = "".join('<li><a href="%s">%s</a> <span class="fw-kind">%s</span></li>'
                        % (_fw_url(fw), e(fw), e(TYPE_LABEL.get(kind, kind)))
                        for fw, kind in sorted(by_lang[lang], key=lambda x: x[0].lower()))
        # Languages whose entries have no composite anywhere get no summary page,
        # so the heading stays plain text rather than linking to a 404.
        heading = ('<a href="%s">%s</a>' % (_lang_url(lang), e(lang))
                   if lang in lang_pages else e(lang))
        n = len(by_lang[lang])
        compare = ('<p class="fw-compare"><a href="%s">%s →</a></p>'
                   % (_lang_url(lang),
                      ("See the %s summary" % e(lang)) if n == 1
                      else "Compare the %d %s entries" % (n, e(lang)))
                   if lang in lang_pages else "")
        sections.append("<h2>" + heading + "</h2>" + compare + "<ul>" + items + "</ul>")
    graph = [
        {"@type": "CollectionPage", "@id": url + "#page", "name": title, "description": desc,
         "url": url, "inLanguage": "en", "isPartOf": {"@id": SITE + "/#website"},
         "publisher": {"@id": SITE + "/#org"}},
    ] + _org_nodes()
    head = ('<!doctype html><html lang="en" data-theme=""><head>'
            '<meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            + _THEME_INIT
            + "<title>" + e(title) + " – HttpArena</title>"
            + '<meta name="description" content="' + e(desc) + '">'
            + '<link rel="canonical" href="' + url + '">'
            + '<link rel="icon" href="/favicon.ico" sizes="any">'
            + '<link rel="icon" href="/favicon.svg" type="image/svg+xml">'
            + '<meta property="og:type" content="website">'
            + '<meta property="og:site_name" content="HttpArena">'
            + '<meta property="og:title" content="' + e(title) + '">'
            + '<meta property="og:description" content="' + e(desc) + '">'
            + '<meta property="og:url" content="' + url + '">'
            + _jsonld({"@context": "https://schema.org", "@graph": graph})
            + '<link rel="stylesheet" href="/docs/docs.css">'
            + "</head>")
    header = ('<body><header class="top">'
              '<div class="brand">' + _CHROME[0] + '</div>'
              '<a class="brand-sub" href="/frameworks/">Frameworks</a>'
              '<div class="top-links">' + _CHROME[1] + '</div>'
              '</header>')
    body = ('<div class="docs-layout one-col"><main class="doc-main">'
            '<article class="doc-wrap"><h1 class="doc-title">' + e(title) + "</h1>"
            '<div class="doc-body"><p>' + e(desc) + " Ranks and every per-profile number live on "
            'the page of each entry; the <a href="/">leaderboard</a> compares them.</p>'
            + "".join(sections) + "</div></article></main></div>")
    return head + header + body + _THEME_TOGGLE + "</body></html>"


def build_fw_pages(profiles, results, meta, fw_lang, badge_index, round_name, with_og):
    """A page per framework that has results, plus the index over them."""
    if FW_OUT.exists():
        shutil.rmtree(FW_OUT)
    FW_OUT.mkdir(parents=True, exist_ok=True)

    named = sorted({r["fw"] for rows in results.values() for r in rows})

    # Results published under a name frameworks.json does not carry: meta.get()
    # would hand it the "emerging" default and the page would assert a tier its
    # own meta.json contradicts, in the sitemap and in a SoftwareApplication
    # node. zix-grpc and zix-ws hit this - they share the display_name "zix" but
    # publish results under their directory name. Skip and report; the board
    # still lists them.
    unknown = [fw for fw in named if fw not in meta]
    if unknown:
        print("[warn] no frameworks.json entry for " + ", ".join(unknown)
              + " - no page written (results published under a name that is not"
                " a display_name)")
        named = [fw for fw in named if fw in meta]

    # Two display names collapsing to one slug would silently overwrite each
    # other's directory. write_badges guards the language analogue the same way.
    by_slug = {}
    for fw in named:
        by_slug.setdefault(_slug(fw), []).append(fw)
    clashes = {s: v for s, v in by_slug.items() if len(v) > 1}
    if clashes:
        raise SystemExit(f"frameworks: entries share a URL slug, fix _slug(): {clashes}")
    if "lang" in by_slug:
        raise SystemExit('frameworks: an entry slugs to "lang", which is where the '
                         "per-language summary pages live - rename it or move them")

    # Which languages get a summary page, decided before any page is written so
    # the entry pages can link to one only where it exists. A language whose
    # entries hold no composite in any family has nothing to compare.
    langs = {}
    for fw in named:
        lang = fw_lang.get(fw) or meta[fw].get("language", "")
        if lang:
            langs.setdefault(lang, []).append(fw)
    lang_pages = {lang for lang, fws in langs.items()
                  if any((badge_index.get(_slug(f)) or {}).get("scopes") for f in fws)}

    entries, cards = [], 0
    for fw in named:
        m = meta[fw]
        kind = m.get("type", "emerging")
        lang = fw_lang.get(fw) or m.get("language", "")
        lang_url = _lang_url(lang) if lang in lang_pages else ""
        ranks = _fw_ranks(fw, badge_index)
        runs = _fw_results(fw, profiles, results)
        og_url = (_fw_url(fw) + "og.png") if with_og else ""
        dest = FW_OUT / _slug(fw)
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "index.html").write_text(
            _fw_page(fw, m, lang, ranks, runs, round_name, og_url, lang_url), encoding="utf-8")
        if with_og:
            _og_card(dest / "og.png", "Benchmark results", fw,
                     [(SCOPE_NAME[s], "#%d of %d" % (rank, field))
                      for s, rank, field, _, _link in ranks],
                     " · ".join(x for x in [lang, TYPE_LABEL.get(kind, kind),
                                            round_name, "www.http-arena.com"] if x),
                     blurb=m.get("desc", ""))
            cards += 1
        entries.append((fw, lang, kind))

    # Per-language summary pages, from the same badge index the entry pages read.
    kinds = dict((fw, kind) for fw, _l, kind in entries)
    for lang in sorted(lang_pages, key=str.lower):
        members = [(fw, kinds[fw]) for fw in sorted(langs[lang], key=str.lower)]
        scopes = {}
        for scope in SCOPE_NAME:
            rows = []
            for fw, kind in members:
                sc = ((badge_index.get(_slug(fw)) or {}).get("scopes", {}).get(scope)) or {}
                d = _published_rank(sc)
                bl = sc.get("byLanguage") or sc.get("byLanguageWithTuned")
                if d:
                    tuned = bool((badge_index.get(_slug(fw)) or {}).get("tuned"))
                    rows.append((fw, kind, tuned, d["score"], d["rank"], d["of"], d["link"],
                                 bl["rank"] if bl else None, bl["of"] if bl else None))
            if rows:
                scopes[scope] = sorted(rows, key=lambda r: -r[3])
        dest = FW_OUT / "lang" / _lang_slug(lang)
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "index.html").write_text(
            _lang_page(lang, scopes, members, round_name), encoding="utf-8")

    (FW_OUT / "index.html").write_text(_fw_index_page(entries, lang_pages), encoding="utf-8")
    return entries, cards, sorted(lang_pages, key=str.lower)


def build_og_images(content, trails, rows, fw_lang, round_name):
    """One card for the board and one per doc. Returns the root card's URL (or
    "" when Pillow is missing), plus how many were written."""
    if not _og_ready():
        print("[warn] Pillow not installed - no og:image cards, pages ship without them")
        # an earlier run's card would otherwise stay behind, with no page left
        # pointing at it
        (GEN / "og.png").unlink(missing_ok=True)
        return "", 0

    GEN.mkdir(parents=True, exist_ok=True)
    top = [(fw, "%.0f" % score) for fw, score in rows[:5]]
    _og_card(GEN / "og.png",
             "Composite ranking · " + SCOPE_NAME[DEFAULT_SCOPE],
             "Which web framework is actually fastest?",
             top,
             f"{len(rows)} entries · {round_name} · www.http-arena.com")
    written = 1

    for did, d in content.items():
        crumb = " › ".join(t for t, _ in trails.get(did, [])[:-1]) or "Knowledge Base"
        _og_card(DOCS_OUT / did / "og.png" if did else DOCS_OUT / "og.png",
                 crumb, d["t"] or "Knowledge Base", [],
                 "HttpArena Knowledge Base · www.http-arena.com",
                 blurb=d.get("d") or _meta_desc(d["html"]))
        written += 1
    return "/og.png", written


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
        for pid, label, blurb, explorer, scored, s, es, isf in entries:
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
                    "scored": s, "engineScored": es, "infraScored": isf,
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
    OUT.write_text(js_payload("LB_DATA", payload))

    # Docs are pre-rendered to real /docs/<id>/ pages (SEO); the SPA links out to
    # them. LB_DATA still carries the docs *tree* for the sidebar labels, but the
    # doc *content* is no longer shipped as docs.js.
    has_og = _og_ready()
    trails = _crumb_trails(docs_tree)
    n_pages = build_doc_pages(docs_tree, docs_content, trails, with_og=has_og)
    n_search, search_bytes = write_search_index(docs_tree, docs_content)
    n_badges, badge_index = write_badges(profiles, results, meta)

    # The board's default view, and the same view for the other five families.
    # Same port of computeComposite() the badges use, so the ranking written into
    # the page cannot disagree with the one the page draws over it.
    agg = badge_aggregate(profiles, results)
    fw_lang = _fw_languages(results)
    families = [(scope, badge_composite(agg, profiles, meta, scope, DEFAULT_TYPES,
                                        show_tuned=True, fw_lang=fw_lang))
                for scope in SCOPE_NAME]
    board = dict(families)[DEFAULT_SCOPE]
    round_name = payload["rounds"]["name"]

    fw_entries, n_fw_cards, lang_pages = build_fw_pages(profiles, results, meta, fw_lang,
                                                        badge_index, round_name, has_og)
    n_urls, n_dated = write_sitemap(docs_content, fw_entries, lang_pages)

    # og cards go in after build_doc_pages: that one clears site/generated/docs/
    # before it writes, and the per-doc cards live inside it.
    og_url, n_cards = build_og_images(docs_content, trails, board, fw_lang, round_name)
    json_bytes = write_data_json(payload)
    # Every entry the dataset covers, not the default board view — see _dataset_node.
    n_entries = len({r["fw"] for rows_ in results.values() for r in rows_})
    index_bytes = build_index_page(board, fw_lang, current, round_name, len(profiles),
                                   n_entries, og_url)
    llms_bytes, llms_full_bytes = write_llms_txt(docs_tree, docs_content, families,
                                                 fw_lang, current, round_name, fw_entries)

    n_rows = sum(len(v) for v in results.values())
    print(f"wrote {OUT.relative_to(ROOT)} - {len(profiles)} profiles, "
          f"{len(results)} views, {n_rows} rows, {OUT.stat().st_size // 1024} KB")
    print(f"wrote {DOCS_OUT.relative_to(ROOT)}/ - {n_pages} static doc pages")
    print(f"wrote {(OUT.parent / 'search.js').relative_to(ROOT)} - {n_search} indexed pages, {search_bytes // 1024} KB")
    print(f"wrote {(GEN / 'sitemap.xml').relative_to(ROOT)} - {n_urls} URLs, "
          f"{n_dated} with lastmod")
    print(f"wrote {BADGE_OUT.relative_to(ROOT)}/ - {n_badges} badges over {len(badge_index)} frameworks")
    print(f"wrote {FW_OUT.relative_to(ROOT)}/ - {len(fw_entries)} framework pages "
          f"+ {len(lang_pages)} language summaries + index")
    print(f"wrote {(GEN / 'index.html').relative_to(ROOT)} - board with the "
          f"{SCOPE_NAME[DEFAULT_SCOPE]} composite ({len(board)} entries) pre-rendered, "
          f"{index_bytes // 1024} KB")
    print(f"wrote {(GEN / 'data.json').relative_to(ROOT)} - {json_bytes // 1024} KB")
    print(f"wrote {(GEN / 'llms.txt').relative_to(ROOT)} - {llms_bytes // 1024} KB, "
          f"llms-full.txt {llms_full_bytes // 1024} KB")
    print(f"wrote {n_cards + n_fw_cards} og:image cards"
          if n_cards else "no og:image cards (Pillow missing)")


if __name__ == "__main__":
    main()
