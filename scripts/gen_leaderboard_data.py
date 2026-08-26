#!/usr/bin/env python3
"""Generate site/leaderboard/data.js from site/data/*.json.

The leaderboard is a standalone static page (plain HTML/CSS/JS, no Hugo
templating). This script reads the per-profile result files under site/data
and emits a single `window.LB_DATA = {...}` blob the page renders client-side -
both the per-profile explorer and the composite ranking.

The composite mirrors the canonical board: it averages RPS over each profile's
*scored* connection set, applies per-type profile eligibility, and carries the
bandwidth field the json-comp compression-ratio adjustment needs.

Run after scripts/rebuild_site_data.py (or any time site/data changes):
    python3 scripts/gen_leaderboard_data.py
"""

from __future__ import annotations
import functools
import json
import re
import shutil
import subprocess
import sys
import posixpath
import html as _html
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import latency_1m_score as _l1m  # noqa: E402  (reference impl for the latency-1m score)
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
    ("Concurrency", [
        # Unscored while the delay range and connection counts are still being
        # tuned (#1310). The other two flags are set for the day it flips:
        # engines are measured on it, infrastructure is not — a reverse proxy
        # has no application handler to await in.
        ("async", "Async Delay", "A 15ms wait named in the route, at 64K held connections.",
                                                    [64000],             [64000],         False,True,False),
    ]),
    ("Efficiency", [
        # Scored. The composite cannot rank this on rps the way it ranks every
        # other profile, because the rate is pinned and every entry that holds it
        # delivers the same one. It contributes its own score instead, which
        # computeComposite() puts on the shared 0-1000 basis.
        #
        # infraScored stays False even though a proxy's CPU efficiency is very
        # much a real thing: scoredForType() reads that flag *ahead* of `scored`,
        # and no infrastructure entry has been measured on this profile yet.
        ("latency-1m", "Latency-1M", "Score out of 100: CPU and both latency tails at a pinned 1M req/s.",
                                                    [1024],              [1024],          True,True,False),
    ]),
    ("Workload", [
        ("json",      "JSON",            "Per-request JSON serialization.",          [4096],              [4096],          True,False,True),
        ("json-comp", "JSON Comp", "gzip/brotli content negotiation.",         [512,4096,16384],    [512,4096,16384],True,False,False),
        ("json-tls",  "JSON TLS",        "JSON over HTTP/1.1 + TLS.",                [4096],              [4096],          True,True,True),
        ("upload",    "Upload",          "Large request-body ingestion.",            [32,64,256,512],     [32,256],        True,False,False),
        ("static",    "Static",          "20-file static asset serving (reference for frameworks).", [1024,4096,6800,16384],[1024,4096,6800],False,False,True),
        ("static-tls","Static TLS",      "20-file static serving over TLS (reference for frameworks).", [1024,4096,6800],    [1024,4096,6800],False,False,True),
    ]),
    ("Database", [
        # Reference-only. The database and its driver dominate these two far
        # more than the framework does, which is the case #1310 makes: they
        # measure the connector, not the HTTP path. Still measured and shown,
        # just no longer deciding the ranking.
        ("async-db",  "Async DB",  "Async Postgres sequential scan (reference).",     [1024],     [1024],  False,True,False),
        ("crud",      "CRUD",      "REST API: list, cached read, upsert, update (reference).",   [4096],     [4096],  False,False,False),
        ("fortunes",  "Fortunes",  "DB query + HTML template render (reference).",    [1024],     [1024],  False,False,False),
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
# Efficiency-only. Emitted like TPL_FIELDS - only where present - so the
# other ~2,300 rows in data.js do not each grow four nulls.
EFF_FIELDS = ("cpu_usec", "cpu_per_req_us", "rate_ratio", "target_rate",
              "p99_9_latency")

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
    "async":            "test-profiles/h1/isolated/async/implementation",
    "latency-1m":      "test-profiles/h1/isolated/latency-1m/implementation",
    "async-db":         "test-profiles/h1/isolated/async-database/implementation",
    "crud":             "test-profiles/h1/isolated/crud/implementation",
    "fortunes":         "test-profiles/h1/isolated/fortunes/implementation",
    "baseline-h2":      "test-profiles/h2/baseline-h2/implementation",
    "static-h2":        "test-profiles/h2/static-h2/implementation",
    "baseline-h2c":     "test-profiles/h2/baseline-h2c/implementation",
    "json-h2c":         "test-profiles/h2/json-h2c/implementation",
    "baseline-h3":      "test-profiles/h3/baseline-h3/implementation",
    "static-h3":        "test-profiles/h3/static-h3/implementation",
    "unary-grpc":       "test-profiles/grpc/unary/implementation",
    "unary-grpc-tls":   "test-profiles/grpc/unary/implementation",
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
              crumbs=None, og_url="", updated=""):
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
         "about": {"@id": SITE + "/#dataset"},
         **({"dateModified": updated} if updated else {})},
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
/* the head-to-head picker and its table */
.cmp-pick{display:flex;align-items:center;gap:.5rem;flex-wrap:wrap;margin:1rem 0}
.cmp-pick select{font:inherit;font-size:.9rem;padding:.35rem .5rem;border-radius:8px;border:1px solid var(--line);background:var(--panel);color:var(--text)}
.doc-body td.n,.doc-body th.n{text-align:right;font-family:var(--mono);font-variant-numeric:tabular-nums}
/* the date the numbers were last published, on every generated page */
.updated{color:var(--muted);font-size:.82rem;margin-top:1.6rem}
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
                         og_url=(_doc_url(did) + "og.png") if with_og else "",
                         updated=_site_dates().get(_doc_source_path(did), ""))
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


@functools.lru_cache(maxsize=None)
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


SITE_SOURCES = ("site/content/docs", "site/data/results", "site/data/frameworks.json")


def _site_dates():
    """The commit dates every page date is taken from - one git pass, cached."""
    return _last_commit_dates(*SITE_SOURCES)


def _site_updated():
    """The day the newest published source changed, or "" without git history.

    dateModified on a benchmark page is a claim about the numbers, so it is the
    date of the data and not the date of the build. A deploy that only changes
    the generator must not move it."""
    return max(_site_dates().values(), default="")


def _updated_line(date, extra=""):
    """The visible date. Same string as dateModified, so a reader and a crawler
    are told the same day."""
    if not date:
        return extra and "<p>" + extra + "</p>"
    return ('<p class="updated">Results updated <time datetime="%s">%s</time>%s</p>'
            % (date, date, " · " + extra if extra else ""))


def _git(args):
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True,
                          encoding="utf-8", check=True).stdout


def _doc_source_path(did):
    """The markdown a doc id came from, for its commit date."""
    section = DOCS / did / "_index.md" if did else DOCS / "_index.md"
    page = DOCS / (did + ".md")
    src = section if section.exists() else page
    return src.relative_to(ROOT).as_posix()


def write_sitemap(content, fw_entries=(), lang_pages=(), compare_pages=()):
    """Root, /frameworks/, /compare/, every language summary and comparison, every
    framework and every /docs/<id>/."""
    # frameworks.json is in here because it supplies the type, mode, language,
    # repo and description on every framework page - dating those pages from the
    # results alone missed metadata edits entirely.
    dates = _site_dates()
    newest = max(dates.values(), default=None)

    urls = [(SITE + "/", newest), (SITE + "/frameworks/", newest)]
    if compare_pages:
        urls.append((SITE + "/compare/", newest))
    for lang in compare_pages:
        urls.append((SITE + _compare_url(lang), newest))
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
    """Average rps/mem/bw over each profile's scored conns. Port of aggregate()
    in index.html."""
    avg, amem, abw = {}, {}, {}
    for p in profiles:
        pid = p["id"]
        sums, ms, bs, cn = {}, {}, {}, {}
        for c in p["scoredConns"]:
            for r in results.get(f"{pid}-{c}", []):
                fw = r["fw"]
                sums[fw] = sums.get(fw, 0) + (r.get("rps") or 0)
                cn[fw] = cn.get(fw, 0) + 1
                ms[fw] = ms.get(fw, 0) + _mem(r.get("memory"))
                bs[fw] = bs.get(fw, 0) + _bw(r.get("bandwidth"))
        avg[pid] = {fw: sums[fw] / cn[fw] for fw in sums}
        amem[pid] = {fw: ms[fw] / cn[fw] for fw in sums}
        abw[pid] = {fw: bs[fw] / cn[fw] for fw in sums}
    return {"avg": avg, "mem": amem, "bw": abw}


# The latency-1m score, from the reference implementation rather than a third
# copy of the formula. Field-wide and computed once, exactly like l1mEnsure() in
# index.html: the bests are taken over every published row, not over whichever
# league or filter happens to be on screen, so a framework's score does not move
# when the view does.
_L1M_CACHE = {}


def l1m_scores():
    if _L1M_CACHE:
        return _L1M_CACHE
    rows = [{"fw": r.get("framework") or r.get("fw"),
             "rps": r.get("rps") or 0,
             "cpu": r.get("cpu_per_req_us"),
             "p99": _l1m.to_us(r.get("p99_latency")),
             "p999": _l1m.to_us(r.get("p99_9_latency"))}
            for key, rs in RESULTS.items() if key.startswith("latency-1m-")
            for r in rs]
    if not rows:
        _L1M_CACHE["__empty__"] = 0.0
        return _L1M_CACHE
    _l1m.score_rows(rows)
    for r in rows:
        if r["fw"]:
            _L1M_CACHE[r["fw"]] = r["score"]
    return _L1M_CACHE


def _scored_for(prof, meta, pid, fw):
    """scoredForType() in index.html. infraScored is read before the `scored`
    short-circuit, not behind it: the infra set is not a subset of the framework
    set — it counts Pipelined, which frameworks do not."""
    p = prof[pid]
    t = meta.get(fw, {}).get("type", "emerging")
    if t == "infrastructure":
        return bool(p["infraScored"])
    if not p["scored"]:
        return False
    if t == "engine":
        return bool(p["engineScored"])
    return True


# Framework tiers are the only ones graded on completeness. Engine and
# infrastructure entries implement none of the four axes, which is why grading
# them is pointless rather than generous: they would all take the same 0.90,
# leaving their order untouched, and each league is normalized against itself
# so their scores are never set against a framework's.
CMP_TYPES = ("flagship", "emerging", "experimental")
CMP_AXES = ("routing", "middleware", "request", "response")
# The four axes are the HTTP request-to-response path, so they only mean
# something on a board measuring that path. cmpInScope() in index.html.
CMP_SCOPES_OUT = ("ws", "grpc")


def _cmp_missing(meta, fw):
    """The axes an entry declares it does not do, in CMP_AXES order."""
    c = meta.get(fw, {}).get("cmp")
    if not isinstance(c, dict):
        return []
    return [a for a in CMP_AXES if c.get(a) is False]


def _cmp_factor(meta, fw, scope=None):
    """cmpFactor() in index.html: the completeness factor as a multiplier on the
    whole composite.

    Not applied on the WebSocket and gRPC boards: a WebSocket echo has no route
    to match, no body to hand over and no response to build, and a gRPC call has
    all four but the generated stub does them. Those boards measure something the
    grade is not about, so every entry scores 1.00 there.

    Four things a framework can do between an arriving request and a finished
    response - routing, middleware, the request it hands you, the response it
    builds. Each one it does not do costs 2.5%, so the factor runs from 1.00
    down to 0.90 and never above it: doing that work is the baseline, not a
    credit.
    An axis that is not declared reads as done, so an ungraded entry scores 1.00
    - ungraded is not the same as missing everything.
    """
    if scope in CMP_SCOPES_OUT:
        return 1.0
    if meta.get(fw, {}).get("type", "emerging") not in CMP_TYPES:
        return 1.0
    return 1.0 - 0.025 * len(_cmp_missing(meta, fw))


def _eff_fn(A, in_league):
    """eff() in index.html: the number a profile is actually ranked on.

    Plain average rps, except for json-comp, which the board scores on
    bandwidth-adjusted rps: the best compressor sets the bar and everyone else
    is penalised by the square of their size ratio. The compression bar is per
    league, which is why this takes `in_league` rather than a finished set.
    """
    min_bpr = None
    if A["avg"].get("json-comp"):
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
        if pid == "json-comp" and min_bpr is not None:
            b = A["bw"][pid].get(fw, 0)
            if b > 0:
                return rps * (min_bpr / (b / rps)) ** 2
        return rps

    return eff


def _ranked(rows):
    """(fw, rank, total, score) with competition ranking — ties share a rank."""
    out, prev_score, prev_rank = [], None, 0
    for i, (fw, score) in enumerate(rows):
        rank = prev_rank if (prev_score is not None and abs(prev_score - score) < 1e-9) else i + 1
        prev_score, prev_rank = score, rank
        out.append((fw, rank, len(rows), score))
    return out


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

    is_scored = lambda pid, fw: _scored_for(prof, meta, pid, fw)
    eff = _eff_fn(A, in_league)

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
                    # 0-1000 per profile; mirrors computeComposite() in
                    # index.html, which check_badge_parity.js diffs against.
                    #
                    # latency-1m cannot be normalised on rps like the rest: its
                    # rate is pinned, so every entry that holds it delivers the
                    # same one and the column would read 1000 for all of them.
                    # It contributes its own score, x10 onto the shared basis.
                    if pid == "latency-1m":
                        score += l1m_scores().get(fw, 0.0) * 10
                    else:
                        score += (eff(pid, fw) / max_r[pid]) * 1000
        if any_result:
            rows.append((fw, score * _cmp_factor(meta, fw, scope)))
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

    def publish(rows, scope, types, lang, with_tuned):
        if len(rows) < BADGE_MIN_FIELD:
            return
        for fw, rank, total, score in _ranked(rows):
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


# ── achievements ────────────────────────────────────────────────────────────
# A medal is a top-three place in a field the site already publishes: the badge
# index for the family composites, overall and within one language, and the
# per-profile ranking the board draws. Nothing is rescored here, so a medal, a
# badge and the table a visitor is looking at cannot disagree.
#
# Every medal is taken in the entry's own league and, for a profile, only where
# that profile counts for its tier - an engine holds no medal on a profile it is
# not scored on. The tuned rule is _published_rank()'s: a standard entry is
# placed in the field without tuned entries, a tuned one in the field with them.
MEDAL_NAME = {1: "gold", 2: "silver", 3: "bronze"}
MEDAL_ORDER = {"gold": 0, "silver": 1, "bronze": 2}
AXIS_ORDER = {"family": 0, "language": 1, "profile": 2}

# A podium takes three, which is more than BADGE_MIN_FIELD asks of a rank: "#1
# of 2" is a fair thing to say and a poor thing to call a gold medal.
MEDAL_MIN_FIELD = 3


def _medal(rank, total):
    """A place is only a medal when someone was beaten for it, so bronze needs a
    field of 4 - bronze of three is last place."""
    if total < MEDAL_MIN_FIELD or rank >= total:
        return None
    return MEDAL_NAME.get(rank)


def _profile_link(pid, conn, types, show_tuned):
    """Deep link to the profile view the medal was taken in. Spelled out the way
    _badge_link() spells it, and for the same reason: the board restores its
    league filter from localStorage, so a link that omits it can land a visitor
    on a table the entry is not in."""
    return SITE + "/#" + "&".join(["p=" + pid, "conns=%d" % conn,
                                   "type=" + ",".join(sorted(types)),
                                   "tuned=1" if show_tuned else "tuned=0"])


def profile_medals(agg, profiles, meta):
    """{framework: [medal]} - top three of every profile."""
    prof = {p["id"]: p for p in profiles}
    is_tuned = lambda fw: meta.get(fw, {}).get("mode", "standard") == "tuned"
    out = {}
    for types in LEAGUES:
        in_league = lambda fw: meta.get(fw, {}).get("type", "emerging") in types
        eff = _eff_fn(agg, in_league)
        for p in profiles:
            pid = p["id"]
            if not p["scoredConns"]:
                continue
            field = [(fw, eff(pid, fw)) for fw in agg["avg"].get(pid, {})
                     if in_league(fw) and _scored_for(prof, meta, pid, fw)]
            field = [(fw, v) for fw, v in field if v > 0]
            for with_tuned in (False, True):
                rows = sorted((r for r in field if with_tuned or not is_tuned(r[0])),
                              key=lambda r: (-r[1], r[0]))
                for fw, rank, total, _v in _ranked(rows):
                    if is_tuned(fw) != with_tuned:
                        continue
                    m = _medal(rank, total)
                    if m:
                        out.setdefault(fw, []).append(
                            {"medal": m, "rank": rank, "of": total, "axis": "profile",
                             "group": p["category"], "label": p["label"],
                             "link": _profile_link(pid, p["scoredConns"][0], types,
                                                   with_tuned)})
    return out


def composite_medals(badge_index, meta):
    """{framework: [medal]} - top three of a family composite, and top three of
    a family among the entries written in the same language."""
    out = {}
    for e in badge_index.values():
        fw = e["framework"]
        for scope, sc in e["scopes"].items():
            for axis, d in (("family", _published_rank(sc)),
                            ("language", sc.get("byLanguage") or sc.get("byLanguageWithTuned"))):
                if not d:
                    continue
                m = _medal(d["rank"], d["of"])
                if not m:
                    continue
                group = "Composite" if axis == "family" else (
                    e["language"] or meta.get(fw, {}).get("language", "") or "Language")
                out.setdefault(fw, []).append(
                    {"medal": m, "rank": d["rank"], "of": d["of"], "axis": axis,
                     "group": group, "label": SCOPE_NAME[scope], "link": d["link"]})
    return out


def compute_achievements(agg, profiles, meta, badge_index):
    """{framework: [medal]}, gold first. Fed to the board and written into every
    framework page, so both read one list."""
    out = {}
    for src in (composite_medals(badge_index, meta), profile_medals(agg, profiles, meta)):
        for fw, items in src.items():
            out.setdefault(fw, []).extend(items)
    for items in out.values():
        items.sort(key=lambda a: (MEDAL_ORDER[a["medal"]], AXIS_ORDER[a["axis"]],
                                  a["group"], a["label"]))
    return out


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
# The board's <h1> per family. renderHead() writes the same strings, so the
# pre-rendered heading and the rendered one match.
SCOPE_H1 = {"h1": "HTTP/1.1 web server benchmarks", "h2": "HTTP/2 web server benchmarks",
            "h3": "HTTP/3 web server benchmarks",
            "gw": "Gateway and production stack benchmarks",
            "grpc": "gRPC server benchmarks", "ws": "WebSocket server benchmarks"}
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
        **({"dateModified": _site_updated()} if _site_updated() else {}),
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
        # Every listed entry has a page of its own, so the list points at it. A
        # ListItem with a name and no url is a string in a list; with one it is
        # the same ranking the reader can click through.
        "itemListElement": [{"@type": "ListItem", "position": i + 1, "name": fw,
                             "url": SITE + _fw_url(fw)}
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


def write_llms_txt(tree, content, families, fw_lang, current, round_name, fw_entries=(),
                   compare_pages=()):
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
        "in the field and a framework's score is the sum over the profiles of that family, scaled "
        "by its completeness factor - the entry loses 2.5% for each of routing, middleware, the "
        "request it hands you and the response it builds that it does not do, so the factor runs "
        "from 1.00 down to 0.90. Engine and infrastructure entries are not graded on it.",
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

    compare = []
    if compare_pages:
        compare = ["## Head-to-head comparisons", ""]
        for lang, n in compare_pages:
            compare.append(
                f"- [{lang}]({SITE}{_compare_url(lang)}): every profile of any two "
                f"of the {n} {lang} entries, side by side."
                if lang else
                f"- [Every language]({SITE}{_compare_url(None)}): every profile of any two of "
                f"the {n} entries, side by side, whatever they are written in.")
        compare.append("")

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

    short += frameworks + compare + docs + data + ["## Full text", "",
                                         f"- [llms-full.txt]({SITE}/llms-full.txt): the whole "
                                         "Knowledge Base and the full ranking of every family.", ""]
    full += frameworks + compare + data + ["## Knowledge Base", ""]
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


def _faq_html(qa):
    """The questions as headings and paragraphs. Both halves are already escaped."""
    return "".join("<h3>%s</h3><p>%s</p>" % (q, a) for q, a in qa)


def _faq_text(html):
    """One answer as text. These are JSON strings, not markup: a <b> and an
    "&amp;" both reach the reader as themselves."""
    return _html.unescape(re.sub(r"<[^>]+>", "", html)).strip()


def _faq_node(url, qa):
    """FAQPage over the same pairs the page prints."""
    return {"@type": "FAQPage", "@id": url + "#faq",
            "mainEntity": [{"@type": "Question", "name": _faq_text(q),
                            "acceptedAnswer": {"@type": "Answer", "text": _faq_text(a)}}
                           for q, a in qa]}


def _board_faq(rows, fw_lang, current, round_name, n_profiles, n_entries):
    """The questions the board answers, answered in sentences.

    The board is a table and a table is not an answer: "what is the fastest web
    framework" is the query this page competes for and nothing on it said so in
    a sentence. Every number here comes from the ranking that was just written
    into the page, so the prose cannot drift from the table above it."""
    e = _html.escape
    top = [(fw, score, fw_lang.get(fw, "")) for fw, score in rows[:3]]
    lead = top[0]
    # best entry of each language, in board order, so "which language" is
    # answered from the ranking rather than from an opinion
    by_lang, seen = [], set()
    for fw, score in rows:
        lang = fw_lang.get(fw, "")
        if lang and lang not in seen:
            seen.add(lang)
            by_lang.append((lang, fw, score))
    hw = current.get("cpu", "")
    qa = [
        ("What is the fastest web framework?",
         "%s%s leads the %s composite with %.0f, ahead of %s and %s. The composite adds a "
         "normalized score over every profile of the family, where the leader of each profile "
         "scores 100, so it ranks an entry over the whole suite instead of on one test. The "
         "sum is then reduced by 2.5%% for each of routing, middleware, the request it hands you "
         "and the response it builds that the entry does not do for you, so a framework that "
         "does none of the four keeps 90%% of what it scored on throughput."
         % (e(lead[0]), " (%s)" % e(lead[2]) if lead[2] else "", SCOPE_NAME[DEFAULT_SCOPE],
            lead[1], ", ".join("%s (%.0f)" % (e(f), sc) for f, sc, _l in top[1:2]),
            ", ".join("%s (%.0f)" % (e(f), sc) for f, sc, _l in top[2:3]))),
        ("Which language has the fastest web frameworks?",
         "%s, through %s. The quickest entry of each language on %s: %s."
         % (e(lead[2] or "-"), e(lead[0]), SCOPE_NAME[DEFAULT_SCOPE],
            ", ".join("%s %s (%.0f)" % (e(lang), e(fw), sc)
                      for lang, fw, sc in by_lang[:8]))),
        ("How many web frameworks are benchmarked?",
         "%d entries - web frameworks, HTTP engines and reverse proxies - over %d test "
         "profiles. The ranking above is the %d flagship and emerging frameworks scored on %s; "
         "engines and reverse proxies are ranked in their own league."
         % (n_entries, n_profiles, len(rows), SCOPE_NAME[DEFAULT_SCOPE])),
        ("How are the benchmarks run?",
         "Every entry runs in a container on the same machine%s, pinned to dedicated cores, one "
         "connection count per run. Requests per second is the best of three runs; latency, CPU "
         "and memory come from that run. Round: %s."
         % (" (%s, %s cores)" % (e(hw), e(current.get("cores", "?"))) if hw else "",
            e(round_name))),
        ("Can I add my own framework?",
         "Yes. Every entry is a directory in the public repository with its own Dockerfile and "
         "its own implementation of the profiles, and a pull request that adds one is benchmarked "
         "on the same machine as everything else."),
    ]
    return qa


def _board_seo(rows, fw_lang, current, round_name, n_profiles, n_entries,
               lang_pages, updated):
    """The copy under the board: what the page measures, the questions in
    sentences, and a link to every hub. #boardSeo is empty in the source page
    and filled here, so only the deployed board carries it."""
    e = _html.escape
    qa = _board_faq(rows, fw_lang, current, round_name, n_profiles, n_entries)
    langs = "".join('<li><a href="%s">%s web framework benchmarks</a></li>'
                    % (_lang_url(l), e(l)) for l in lang_pages)
    return qa, (
        "<h2>What HttpArena measures</h2>"
        "<p>Every framework, HTTP engine and reverse proxy in the ranking above runs the same "
        "%d test profiles - plain and pipelined requests, JSON, compression, TLS, uploads, static "
        "files, Postgres, templates and mixed endpoints - on one dedicated machine, in a "
        "container pinned to its own cores. Nothing is self-reported: the implementations are in "
        "the public repository and the raw numbers behind every row are published with them.</p>"
        "<h2>Questions</h2>" % n_profiles
        + _faq_html(qa)
        + "<h2>Browse by language</h2><ul>" + langs + "</ul>"
        + '<p><a href="/frameworks/">Every entry, one page each</a> · '
          '<a href="/compare/">Head-to-head comparisons</a> · '
          '<a href="/docs/">How the benchmark works</a> · '
          '<a href="/docs/add-framework/">Add a framework</a> · '
          '<a href="/llms.txt">The rankings as text</a></p>'
        + _updated_line(updated))


def build_index_page(rows, fw_lang, current, round_name, n_profiles, n_entries,
                     og_url, lang_pages=(), updated=""):
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

    qa, seo = _board_seo(rows, fw_lang, current, round_name, n_profiles, n_entries,
                         lang_pages, updated)
    graph = _org_nodes() + [
        _dataset_node(current, n_entries, n_profiles, round_name),
        _ranking_node(DEFAULT_SCOPE, rows),
        _faq_node(SITE + "/", qa),
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
               '<h1 id="ptitle">' + SCOPE_H1[DEFAULT_SCOPE] + "</h1>", "#ptitle")
    out = once(out, '<p id="pblurb"></p>', '<p id="pblurb">' + blurb + "</p>", "#pblurb")
    out = once(out, '<span class="count" id="count"></span>',
               '<span class="count" id="count">' + str(len(rows)) + " frameworks</span>", "#count")
    out = once(out, '<div id="rows"></div>',
               '<div id="rows">' + _static_board(rows, fw_lang, round_name) + "</div>", "#rows")
    out = once(out, '<section class="board-seo" id="boardSeo"></section>',
               '<section class="board-seo" id="boardSeo">' + seo + "</section>", "#boardSeo")

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


MEDAL_ICON = {"gold": "🥇", "silver": "🥈", "bronze": "🥉"}
MEDAL_LABEL = {"gold": "Gold", "silver": "Silver", "bronze": "Bronze"}
AXIS_LABEL = {"family": "Family composite", "language": "Within its language",
              "profile": "Test profile"}


def _medal_counts(items):
    """[(medal, how many)] gold first, medals the entry does not hold left out."""
    return [(m, sum(1 for a in items if a["medal"] == m))
            for m in ("gold", "silver", "bronze")
            if any(a["medal"] == m for a in items)]


def _fw_achievements(items):
    """The Achievements section of a framework page."""
    e = _html.escape
    head = " · ".join("%s %d %s" % (MEDAL_ICON[m], n, MEDAL_LABEL[m])
                      for m, n in _medal_counts(items))
    rows = "".join(
        '<tr><td>%s %s</td><td>%s</td><td>%s</td><td><a href="%s">%d of %d</a></td></tr>'
        % (MEDAL_ICON[a["medal"]], MEDAL_LABEL[a["medal"]], e(AXIS_LABEL[a["axis"]]),
           e(a["group"] + " · " + a["label"]), e(a["link"]), a["rank"], a["of"])
        for a in items)
    return ('<h2 id="achievements">Achievements</h2>'
            "<p>" + e(head) + ". Top three of a field, taken in this entry's own league: "
            "the family composite, the same composite among entries written in the same "
            "language, and each test profile it is scored on. Every field is the one the "
            "badges publish, so a medal and a badge always say the same thing. "
            '<a href="/docs/scoring/achievements/">How medals are awarded</a>.</p>'
            "<table><thead><tr><th>Medal</th><th>Award</th><th>Field</th><th>Rank</th>"
            "</tr></thead><tbody>" + rows + "</tbody></table>")


def _fw_neighbours(fw, scopes):
    """(family, rows, index of fw) for the language field this entry sits in.

    Its own family when it runs one, the first it appears in otherwise. An entry
    page used to link nowhere except its language summary, which left every one
    of them a leaf: the entries directly around it are the pages a reader wants
    next, and the ones a crawler needs to reach the rest of the language from
    here."""
    for scope in [DEFAULT_SCOPE] + [x for x in scopes if x != DEFAULT_SCOPE]:
        rows = scopes.get(scope) or []
        for i, r in enumerate(rows):
            if r[0] == fw:
                return scope, rows, i
    return "", [], -1


def _fw_compare(fw, lang, scopes, lang_url, has_compare=False):
    """The entries either side of this one, and the leader of its language."""
    e = _html.escape
    scope, rows, i = _fw_neighbours(fw, scopes)
    cmp_url = _compare_url(lang)
    # The cross-language link is not gated on has_compare. That flag is about
    # this entry's *language* having a page, and an entry whose language has only
    # one of it - the F# entry, say - had no way to be compared with anything at
    # all before /compare/all/ existed (#1222).
    links = ("<p>" + ('<a href="%s">Compare %s with any %s entry</a> · '
                      % (cmp_url, e(fw), e(lang)) if has_compare else "")
             + '<a href="%s#%s">Compare %s with any entry, in any language</a>'
               % (_compare_url(None), quote(fw), e(fw))
             + (' · <a href="%s">Every %s entry, ranked</a>' % (lang_url, e(lang))
                if lang_url else "") + "</p>")
    # Nothing to put in a table: the links still belong on the page, a heading
    # over "there is nothing to compare" does not.
    if i < 0 or len(rows) < 2:
        return links if lang else ""
    mine = rows[i][3]
    near = list(range(max(0, i - 2), i)) + list(range(i + 1, min(len(rows), i + 3)))
    if 0 not in near and i != 0:
        near = [0] + near
    body = "".join(
        '<tr><td><a href="%s">%s</a></td><td class="n">%.0f</td><td class="n">%s</td>%s</tr>'
        % (_fw_url(rows[j][0]), e(rows[j][0]), rows[j][3],
           ("+%.0f%%" if rows[j][3] >= mine else "%.0f%%")
           % ((rows[j][3] - mine) / mine * 100 if mine else 0),
           ('<td><a href="%s#%s-vs-%s">head to head</a></td>'
            % (cmp_url, quote(fw), quote(rows[j][0]))) if has_compare else "")
        for j in sorted(set(near)))
    return ("<h2 id=\"compare\">Compared with</h2>"
            "<p>The %s entries around %s on the %s composite, and the one leading them.%s</p>"
            % (e(lang), e(fw), SCOPE_NAME.get(scope, scope),
               " The last column shows every profile side by side." if has_compare else "")
            + "<table><thead><tr><th>Entry</th><th class=\"n\">Composite</th>"
              "<th class=\"n\">vs %s</th>%s</tr></thead><tbody>"
              % (e(fw), "<th></th>" if has_compare else "")
            + body + "</tbody></table>" + links)


def _fw_body(fw, m, lang, ranks, runs, round_name, lang_url="", achievements=(),
             lang_scopes=None, updated="", has_compare=False):
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
    # Same reason as mode: only framework entries are graded on completeness,
    # and an unassessed one is left silent rather than shown as the 4/4 it is
    # scored at - the page should not assert a grade nobody gave it.
    if m.get("type", "emerging") in CMP_TYPES and isinstance(m.get("cmp"), dict):
        facts.append("completeness %d/4" % (4 - len([a for a in CMP_AXES
                                                     if m["cmp"].get(a) is False])))
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

    if achievements:
        out.append(_fw_achievements(achievements))

    if ranks:
        out.append('<h2 id="rank">Composite rank</h2>')
        out.append("<p>Each profile of a family is worth 100 to the entry that leads it, and the "
                   "composite is the sum over the family, less 2.5% for each of routing, "
                   "middleware, request and response the entry does not do for you - its "
                   '<a href="/docs/scoring/completeness/">completeness factor</a>, which the '
                   "WebSocket and gRPC families do not carry. The field is this entry's own "
                   "league: engines and reverse proxies are scored apart from frameworks. "
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

    if lang and lang_scopes:
        out.append(_fw_compare(fw, lang, lang_scopes, lang_url, has_compare))

    out.append(_updated_line(updated,
                             '<a href="/docs/">How the benchmark is run</a> · '
                             '<a href="/docs/hardware/">The machine</a> · '
                             '<a href="/docs/add-framework/">Add or fix an entry</a>'))
    return '<div class="doc-body">' + "".join(out) + "</div>"


def _fw_page(fw, m, lang, ranks, runs, round_name, og_url, lang_url="", achievements=(),
             lang_scopes=None, updated="", has_compare=False):
    e = _html.escape
    url = SITE + _fw_url(fw)
    title = f"{fw} performance benchmark & ranking"
    # the main family when the entry runs it, its first one otherwise. Quoting
    # whichever rank happens to be best would read as picked, and be picked
    lead = next((r for r in ranks if r[0] == DEFAULT_SCOPE), ranks[0] if ranks else None)
    # "web framework" vs "HTTP server" mirrors the wording the lang pages use,
    # so a search snippet for this entry and for its language list read as the
    # same vocabulary rather than two different ways of describing one thing.
    kind_word = "web framework" if kind_has_mode(m.get("type", "emerging")) else "HTTP server"
    desc = (f"{fw}" + (f" ({lang})" if lang else "") + f" {kind_word} performance: "
            + (f"ranked {lead[1]} of {lead[2]} in HttpArena, " if lead else "benchmarked in HttpArena, ")
            + f"compared on throughput, latency, CPU and memory over {len(runs)} runs.")
    graph = [
        {"@type": "WebPage", "@id": url + "#page", "name": title, "description": desc,
         "url": url, "inLanguage": "en", "isPartOf": {"@id": SITE + "/#website"},
         "publisher": {"@id": SITE + "/#org"}, "about": {"@id": url + "#software"},
         "mainEntityOfPage": url,
         **({"dateModified": updated} if updated else {})},
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
            + _fw_body(fw, m, lang, ranks, runs, round_name, lang_url, achievements,
                       lang_scopes, updated, has_compare)
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


def _lang_page(lang, scopes, all_entries, round_name, siblings=(), updated="",
               has_compare=False):
    """/frameworks/lang/<language>/ - one language's entries, compared family by family.

    Every number is read out of the badge index, the same source the entry pages
    read. Nothing is recomputed and no placing is invented: the rows are ordered
    by composite and the only ranks shown are ones already published elsewhere.
    A position column would be a third implementation of the ranking, which is
    exactly what put the entry pages out of step with the badges (#1185).
    """
    e = _html.escape
    url = SITE + _lang_url(lang)
    title = lang + " web framework benchmarks: performance comparison"
    n = len(all_entries)
    faq = _lang_faq(lang, scopes, n, round_name)
    lead_row = (scopes.get(DEFAULT_SCOPE) or (next(iter(scopes.values())) if scopes else None))
    # Kept short on purpose: this is the search-snippet and og:description, not
    # the page. The composite-score sentence with its numbers belongs to the
    # on-page "answer" paragraph below, which a reader (or an assistant) reaches
    # after clicking through; stuffing that detail into the tag just makes the
    # snippet unreadable.
    desc = (f"Which {lang} web framework is fastest? See the full list of {n} "
            f"{lang} web frameworks and HTTP servers, compared by performance "
            f"in a composite score table.")

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

    ranked = scopes.get(DEFAULT_SCOPE) or (next(iter(scopes.values())) if scopes else [])
    graph = [
        {"@type": "CollectionPage", "@id": url + "#page", "name": title, "description": desc,
         "url": url, "inLanguage": "en", "isPartOf": {"@id": SITE + "/#website"},
         "publisher": {"@id": SITE + "/#org"},
         **({"dateModified": updated} if updated else {})},
        {"@type": "BreadcrumbList", "@id": url + "#crumbs", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "Frameworks",
             "item": SITE + "/frameworks/"},
            {"@type": "ListItem", "position": 2, "name": lang, "item": url}]},
    ] + (([{"@type": "ItemList", "@id": url + "#ranking",
           "name": lang + " " + SCOPE_NAME[DEFAULT_SCOPE] + " composite ranking",
           "itemListOrder": "https://schema.org/ItemListOrderDescending",
           "numberOfItems": len(ranked),
           "itemListElement": [{"@type": "ListItem", "position": i + 1, "name": r[0],
                                "url": SITE + _fw_url(r[0])}
                               for i, r in enumerate(ranked)]}] if ranked else [])
         + ([_faq_node(url, faq)] if faq else [])) + _org_nodes()
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
    intro = ('<p><a href="%s">Compare any two %s entries profile by profile →</a></p>'
             % (_compare_url(lang), e(lang)) if has_compare else "")
    intro += ("<p>Every %s entry in the benchmark, compared on the composite score of each "
             "family. The composite sums a normalized score over the profiles of that family, "
             "where the leader of each profile scores 100, and scales the sum by the entry's "
             '<a href="/docs/scoring/completeness/">completeness factor</a>. '
             "Rank overall is the entry's place in "
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
            + ("<h2 id=\"faq\">Questions</h2>" + _faq_html(faq) if faq else "")
            + "<h2>Every " + e(lang) + " entry</h2><ul>" + every + "</ul>"
            + ('<h2>Other languages</h2><p>' + " · ".join(
                '<a href="%s">%s</a>' % (_lang_url(x), e(x)) for x in siblings if x != lang)
               + "</p>" if siblings else "")
            + _updated_line(updated, e(round_name) + " · "
                            + ('<a href="%s">Compare two %s entries</a> · '
                               % (_compare_url(lang), e(lang)) if has_compare else "")
                            + '<a href="/frameworks/">All languages</a> · '
                              '<a href="/">Open the leaderboard</a>')
            + "</div></article></main></div>")
    return head + header + body + _THEME_TOGGLE + "</body></html>"


def _fw_index_page(entries, lang_pages=(), updated="", compare_langs=()):
    """/frameworks/ - one link per entry, grouped by language. Also the page that
    makes every framework page reachable by following links from the board."""
    e = _html.escape
    url = SITE + "/frameworks/"
    title = "Web framework & HTTP server benchmarks: full list"
    desc = (f"Browse the full list of {len(entries)} web frameworks, HTTP engines "
            "and reverse proxies benchmarked by HttpArena, compared by language "
            "and performance.")
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
        compare = ('<p class="fw-compare"><a href="%s">%s →</a>'
                   % (_lang_url(lang),
                      ("See the %s summary" % e(lang)) if n == 1
                      else "Compare the %d %s entries" % (n, e(lang)))
                   + (' · <a href="%s">head to head</a>' % _compare_url(lang)
                      if lang in compare_langs else "")
                   + "</p>" if lang in lang_pages else "")
        sections.append("<h2>" + heading + "</h2>" + compare + "<ul>" + items + "</ul>")
    graph = [
        {"@type": "CollectionPage", "@id": url + "#page", "name": title, "description": desc,
         "url": url, "inLanguage": "en", "isPartOf": {"@id": SITE + "/#website"},
         "publisher": {"@id": SITE + "/#org"},
         **({"dateModified": updated} if updated else {})},
        {"@type": "BreadcrumbList", "@id": url + "#crumbs", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "Frameworks", "item": url}]},
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
            'the page of each entry; the <a href="/">leaderboard</a> compares them, and '
            '<a href="/compare/">the comparisons</a> put any two of one language side by side.</p>'
            + "".join(sections)
            + _updated_line(updated) + "</div></article></main></div>")
    return head + header + body + _THEME_TOGGLE + "</body></html>"


# -- head to head -------------------------------------------------------------
# "actix vs axum" is a question people type, and the board answers it only after
# two filter clicks nobody finds. One page per language holds every pair of that
# language: the default pair is written into the HTML, the picker swaps in any
# other from the numbers embedded beside it. Per language and not per pair on
# purpose - 155 entries make 11,935 pairs, and a page each would be eleven
# thousand tables with nothing of their own to say.

COMPARE_OUT = GEN / "compare"


# The cross-language comparison is addressed as lang=None, from the URL down
# through _compare_page and into the sitemap and llms.txt lists. One sentinel
# rather than a parallel set of functions: everything a language page does, the
# cross-language page does too, with different copy and a wider entry list.
COMPARE_ALL_SLUG = "all"


def _compare_url(lang):
    """`lang=None` is the comparison across every language."""
    return "/compare/" + (_lang_slug(lang) if lang else COMPARE_ALL_SLUG) + "/"


def _cmp_views(profiles, results, entries):
    """[(view key, profile, conns)] every view at least two of these entries ran."""
    out = []
    for p in profiles:
        for c in p["conns"]:
            key = f"{p['id']}-{c}"
            have = sum(1 for r in results.get(key, []) if r["fw"] in entries)
            if have >= 2:
                out.append((key, p, c))
    return out


def _cmp_data(views, results, entries):
    """fw -> view key -> [rps, avg, p99, cpu, memory], the numbers the picker draws."""
    data = {fw: {} for fw in entries}
    for key, _p, _c in views:
        for r in results.get(key, []):
            if r["fw"] in data and r.get("rps"):
                data[r["fw"]][key] = [round(r["rps"]), r.get("avg_latency") or "",
                                      r.get("p99_latency") or "", r.get("cpu") or "",
                                      r.get("memory") or ""]
    return data


def _cmp_wins(data, views, a, b):
    """(views a leads, views b leads, views both ran) on requests per second."""
    wa = wb = both = 0
    for key, _p, _c in views:
        ra, rb = data[a].get(key), data[b].get(key)
        if not ra or not rb:
            continue
        both += 1
        if ra[0] > rb[0]:
            wa += 1
        elif rb[0] > ra[0]:
            wb += 1
    return wa, wb, both


def _cmp_table(data, views, a, b):
    e = _html.escape
    body = []
    for key, p, c in views:
        ra, rb = data[a].get(key), data[b].get(key)
        if not ra or not rb:
            continue
        d = (ra[0] - rb[0]) / rb[0] * 100 if rb[0] else 0
        body.append('<tr><td>%s</td><td>%s</td><td class="n">%s</td><td class="n">%s</td>'
                    '<td class="n">%s</td><td class="n">%s</td><td class="n">%s</td></tr>'
                    % (e(p["label"]), f"{c:,}", f"{ra[0]:,}", f"{rb[0]:,}",
                       ("+%.0f%%" if d >= 0 else "%.0f%%") % d, e(ra[2] or "-"), e(rb[2] or "-")))
    if not body:
        return "<p>These two entries share no test profile.</p>"
    return ('<table class="cmp-table"><thead><tr><th>Profile</th><th>Conns</th>'
            '<th class="n">%s req/sec</th><th class="n">%s req/sec</th><th class="n">Delta</th>'
            '<th class="n">%s p99</th><th class="n">%s p99</th></tr></thead><tbody>'
            % (e(a), e(b), e(a), e(b)) + "".join(body) + "</tbody></table>")


def _cmp_verdict(data, views, scores, a, b):
    """One sentence on who is ahead, from the profile wins and the composite."""
    e = _html.escape
    wa, wb, both = _cmp_wins(data, views, a, b)
    if not both:
        return ("%s and %s share no test profile, so there is nothing to compare directly."
                % (e(a), e(b)))
    lead, other, wl, wo = (a, b, wa, wb) if wa >= wb else (b, a, wb, wa)
    out = ("<b>%s</b> is quicker than <b>%s</b> on %d of the %d profiles they both run"
           % (e(lead), e(other), wl, both))
    out += (", and behind on %d." % wo) if wo else "."
    sa, sb = scores.get(a), scores.get(b)
    if sa and sb:
        out += (" On the %s composite they score %.0f and %.0f."
                % (SCOPE_NAME[DEFAULT_SCOPE], sa, sb))
    return out


def _cmp_faq(data, views, scores, pairs, lang):
    e = _html.escape
    qa = [("Is %s faster than %s?" % (e(a), e(b)),
           _cmp_verdict(data, views, scores, a, b)
           + " Both run on the same machine, in the same round, against the same profiles.")
          for a, b in pairs[:4]]
    if scores:
        top = max(scores, key=lambda k: scores[k])
        qa.append(("Which %sframework is fastest overall?" % (e(lang) + " " if lang else ""),
                   "%s holds the highest %s composite of the %s, at %.0f. The composite "
                   "is throughput over the whole suite; if a service is one shape of workload, "
                   "compare that profile on its own in the table above, because the order "
                   "changes." % (e(top), SCOPE_NAME[DEFAULT_SCOPE],
                                 ("%s entries" % e(lang)) if lang else "entries it ranks",
                                 scores[top])))
    if not lang:
        qa.append(("Can I compare frameworks written in different languages?",
                   "Yes - that is what this page is for. Every entry runs the same profiles on "
                   "the same machine, so an F# entry and a C# one are measured the same way and "
                   "the numbers line up. The per-language pages under "
                   "<a href=\"/compare/\">Comparisons</a> narrow the same table to one language "
                   "when that is the choice you are making."))
    return qa


_CMP_JS = """<script>
(function(){
  var D=window.CMP, views=D.v, data=D.d, sel=D.e;
  var a=document.getElementById('cmpA'), b=document.getElementById('cmpB'),
      out=document.getElementById('cmpOut'), head=document.getElementById('cmpLead');
  if(!a||!b||!out) return;
  function esc(s){ return String(s).replace(/[&<>]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;'}[c];}); }
  function num(n){ return n.toLocaleString('en-US'); }
  function draw(){
    var x=a.value, y=b.value, rows='', wx=0, wy=0, both=0;
    for(var i=0;i<views.length;i++){
      var v=views[i], rx=(data[x]||{})[v[0]], ry=(data[y]||{})[v[0]];
      if(!rx||!ry) continue;
      both++; if(rx[0]>ry[0])wx++; else if(ry[0]>rx[0])wy++;
      var d=ry[0]?(rx[0]-ry[0])/ry[0]*100:0;
      rows+='<tr><td>'+esc(v[1])+'</td><td>'+num(v[2])+'</td><td class="n">'+num(rx[0])+'</td>'
           +'<td class="n">'+num(ry[0])+'</td><td class="n">'+(d>=0?'+':'')+d.toFixed(0)+'%</td>'
           +'<td class="n">'+esc(rx[2]||'-')+'</td><td class="n">'+esc(ry[2]||'-')+'</td></tr>';
    }
    out.innerHTML = rows
      ? '<table class="cmp-table"><thead><tr><th>Profile</th><th>Conns</th><th class="n">'
        +esc(x)+' req/sec</th><th class="n">'+esc(y)+' req/sec</th><th class="n">Delta</th>'
        +'<th class="n">'+esc(x)+' p99</th><th class="n">'+esc(y)+' p99</th></tr></thead><tbody>'
        +rows+'</tbody></table>'
      : '<p>These two entries share no test profile.</p>';
    if(head) head.innerHTML = both
      ? '<b>'+esc(wx>=wy?x:y)+'</b> is quicker on '+Math.max(wx,wy)+' of the '+both
        +' profiles they both run, <b>'+esc(wx>=wy?y:x)+'</b> on '+Math.min(wx,wy)+'.'
      : 'These two entries share no test profile.';
    if(location.hash.slice(1)!==x+'-vs-'+y) history.replaceState(null,'','#'+x+'-vs-'+y);
  }
  function fromHash(){
    var h=decodeURIComponent(location.hash.slice(1)), m=h.split('-vs-');
    if(m.length===2 && sel.indexOf(m[0])>=0 && sel.indexOf(m[1])>=0 && m[0]!==m[1]){
      a.value=m[0]; b.value=m[1]; draw(); return;
    }
    // A bare entry name lands with that entry on the left and leaves the other
    // side on its default, which is what a link from an entry's own page wants.
    // If it IS the default other side, the two swap rather than collapsing into
    // one entry compared with itself.
    if(m.length===1 && sel.indexOf(h)>=0){
      if(h===b.value) b.value=a.value;
      a.value=h; draw();
    }
  }
  a.onchange=b.onchange=draw;
  window.addEventListener('hashchange',fromHash);
  if(location.hash) fromHash();
})();
</script>"""


def _compare_langs(profiles, results, members_by_lang):
    """The languages a comparison can be written for: two entries or more with
    results in a view they share. Every link to /compare/<language>/ is gated on
    this set, so nothing points at a page that was never written."""
    out = set()
    for lang, members in members_by_lang.items():
        names = {fw for fw, _k in members}
        if len(names) < 2:
            continue
        data = _cmp_data(_cmp_views(profiles, results, names), results, names)
        if sum(1 for fw in names if data[fw]) >= 2:
            out.add(lang)
    return out


def _compare_page(lang, ranked, members, profiles, results, round_name, updated,
                  og_url="", fw_lang=None):
    """/compare/<language>/ - any two entries of one language, side by side.

    `lang=None` writes /compare/all/ instead: the same table over every entry in
    the benchmark, whatever it is written in. Everything is measured on one
    machine against one set of profiles, so a cross-language row is exactly as
    comparable as a same-language one - the split existed because picking a
    language usually comes first, not because the numbers stop lining up.
    """
    e = _html.escape
    url = SITE + _compare_url(lang)
    ranked_names = [r[0] for r in ranked]
    entries = ranked_names + sorted((fw for fw, _k in members if fw not in set(ranked_names)),
                                    key=str.lower)
    views = _cmp_views(profiles, results, set(entries))
    data = _cmp_data(views, results, entries)
    # An entry with no run in any shared view has nothing to put in a column.
    entries = [fw for fw in entries if data[fw]]
    if len(entries) < 2:
        return ""
    scores = {r[0]: r[3] for r in ranked}
    # The pair written into the page, and the pairs offered as links, are the
    # flagship entries first: "django vs fastapi" is what gets asked, and the two
    # leaders of a language are often two entries nobody has heard of.
    kind_of = dict(members)
    flagship = [fw for fw in entries if kind_of.get(fw) == "flagship"]
    featured = (flagship + [fw for fw in entries if fw not in flagship])[:4]
    if not lang and fw_lang:
        # The cross-language page opens on two entries that are not in the same
        # language - the default pair is the page explaining itself, and two C#
        # entries would not.
        lead = featured[0]
        other = (next((fw for fw in featured[1:] if fw_lang.get(fw) != fw_lang.get(lead)), None)
                 or next((fw for fw in entries if fw_lang.get(fw) != fw_lang.get(lead)), None))
        if other:
            featured = [lead, other] + [fw for fw in featured if fw not in (lead, other)]
    a, b = featured[0], featured[1]
    pairs = [(x, y) for i, x in enumerate(featured) for y in featured[i + 1:]]
    qa = _cmp_faq(data, views, scores, pairs, lang)

    # The page holds every pair, so the heading names none of them: the pair in
    # it would be the default one, and the sentence under it says which that is
    # and changes with the picker.
    if lang:
        title = "%s web framework comparison: any two, head to head" % lang
        desc = ("Compare %d %s web frameworks and HTTP servers head to head: requests per "
                "second, p99 latency and the delta on every test profile, all measured on the "
                "same machine." % (len(entries), lang))
    else:
        title = "Web framework comparison: any two entries, any language"
        desc = ("Compare any two of %d web frameworks and HTTP servers head to head, across "
                "every language: requests per second, p99 latency and the delta on every test "
                "profile, all measured on the same machine." % len(entries))

    def opts(cur):
        def one(fw):
            return ('<option value="%s"%s>%s</option>'
                    % (e(fw), " selected" if fw == cur else "", e(fw)))
        if lang or not fw_lang:
            return "".join(one(fw) for fw in entries)
        # Every entry in one flat list is not something anyone can pick from, and
        # the language is what people navigate by - "the F# one". Ranked order is
        # kept inside each group.
        by = {}
        for fw in entries:
            by.setdefault(fw_lang.get(fw) or "Other", []).append(fw)
        return "".join('<optgroup label="%s">%s</optgroup>'
                       % (e(l), "".join(one(fw) for fw in by[l]))
                       for l in sorted(by, key=str.lower))

    quick = " · ".join('<a href="#%s-vs-%s">%s vs %s</a>' % (e(x), e(y), e(x), e(y))
                       for x, y in pairs[:6])
    graph = [
        {"@type": "WebPage", "@id": url + "#page", "name": title, "description": desc,
         "url": url, "inLanguage": "en", "isPartOf": {"@id": SITE + "/#website"},
         "publisher": {"@id": SITE + "/#org"}, "about": {"@id": SITE + "/#dataset"},
         "mainEntityOfPage": url,
         **({"dateModified": updated} if updated else {})},
        {"@type": "BreadcrumbList", "@id": url + "#crumbs", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "Comparisons",
             "item": SITE + "/compare/"},
            {"@type": "ListItem", "position": 2, "name": lang or "Every language",
             "item": url}]},
        _faq_node(url, qa),
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
            + _og_meta(og_url)
            + _jsonld({"@context": "https://schema.org", "@graph": graph})
            + '<link rel="stylesheet" href="/docs/docs.css">'
            + "</head>")
    header = ('<body><header class="top">'
              '<div class="brand">' + _CHROME[0] + '</div>'
              '<a class="brand-sub" href="/compare/">Comparisons</a>'
              '<div class="top-links">' + _CHROME[1] + '</div>'
              '</header>')
    picker = ('<div class="cmp-pick"><label for="cmpA">Compare</label>'
              '<select id="cmpA">' + opts(a) + "</select>"
              '<label for="cmpB">with</label>'
              '<select id="cmpB">' + opts(b) + "</select></div>")
    how = ("Requests per second is the best of three runs and the delta is the first column "
           "against the second; every row is the same profile at the same connection count, on "
           'the same machine. <a href="/docs/test-profiles/">What each profile measures</a>.')
    intro = ("<p>Pick any two of the %d %s entries. %s</p>" % (len(entries), e(lang), how)
             if lang else
             "<p>Pick any two of the %d entries, in any language - the picker is grouped by "
             "language, and the two sides do not have to match. %s</p>" % (len(entries), how))
    body = ('<div class="docs-layout one-col"><main class="doc-main">'
            '<article class="doc-wrap"><h1 class="doc-title">' + e(title) + "</h1>"
            '<div class="doc-body">'
            '<p class="lead-answer" id="cmpLead">' + _cmp_verdict(data, views, scores, a, b)
            + "</p>" + intro + picker
            + '<div id="cmpOut">' + _cmp_table(data, views, a, b) + "</div>"
            + ("<h2>Common comparisons</h2><p>" + quick + "</p>" if quick else "")
            + "<h2>Questions</h2>" + _faq_html(qa)
            + ("<h2>Every " + e(lang) + " entry</h2><ul>"
               + "".join('<li><a href="%s">%s</a></li>' % (_fw_url(fw), e(fw))
                         for fw in entries)
               + "</ul>" if lang else "")
            + _updated_line(updated,
                            ('<a href="%s">%s composite ranking</a> · '
                             '<a href="%s">Compare across languages</a> · '
                             '<a href="/compare/">Other languages</a> · '
                             '<a href="/">Open the leaderboard</a>'
                             % (_lang_url(lang), e(lang), _compare_url(None)))
                            if lang else
                            ('<a href="/compare/">One language at a time</a> · '
                             '<a href="/frameworks/">Every entry, one page each</a> · '
                             '<a href="/">Open the leaderboard</a>'))
            + "</div></article></main></div>")
    payload = js_payload("CMP", {"v": [[k, p["label"], c] for k, p, c in views],
                                 "d": data, "e": entries})
    return (head + header + body + "<script>" + payload + "</script>" + _CMP_JS
            + _THEME_TOGGLE + "</body></html>")


def _compare_index_page(langs, updated, og_url=""):
    """/compare/ - the cross-language page, one link per language, and what each
    of them does. `langs` carries the cross-language page as (None, n)."""
    e = _html.escape
    url = SITE + "/compare/"
    title = "Compare web frameworks head to head"
    desc = ("Pick any two web frameworks - the same language or not - and compare requests per "
            "second, p99 latency and the delta on every test profile, measured on the same "
            "machine.")
    every = next((n for l, n in langs if l is None), 0)
    items = "".join('<li><a href="%s">Compare %s web frameworks</a> '
                    '<span class="fw-kind">%d entries</span></li>'
                    % (_compare_url(l), e(l), n) for l, n in langs if l is not None)
    graph = [
        {"@type": "CollectionPage", "@id": url + "#page", "name": title, "description": desc,
         "url": url, "inLanguage": "en", "isPartOf": {"@id": SITE + "/#website"},
         "publisher": {"@id": SITE + "/#org"},
         **({"dateModified": updated} if updated else {})},
        {"@type": "BreadcrumbList", "@id": url + "#crumbs", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "Comparisons", "item": url}]},
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
            + _og_meta(og_url)
            + _jsonld({"@context": "https://schema.org", "@graph": graph})
            + '<link rel="stylesheet" href="/docs/docs.css">'
            + "</head>")
    header = ('<body><header class="top">'
              '<div class="brand">' + _CHROME[0] + '</div>'
              '<a class="brand-sub" href="/compare/">Comparisons</a>'
              '<div class="top-links">' + _CHROME[1] + '</div>'
              '</header>')
    body = ('<div class="docs-layout one-col"><main class="doc-main">'
            '<article class="doc-wrap"><h1 class="doc-title">' + e(title) + "</h1>"
            '<div class="doc-body"><p>' + e(desc) + " Every entry runs the same profiles on the "
            "same machine, so two entries in different languages are measured the same way and "
            "the numbers line up.</p>"
            + ('<p><a href="%s"><b>Compare any two entries, in any language</b></a> - all %d of '
               "them, in one picker grouped by language. Start here if the language is not what "
               "you are choosing.</p>" % (_compare_url(None), every) if every else "")
            + "<h2>One language at a time</h2>"
            "<p>Narrower, for when the language is already settled: the same table over just "
            "the entries written in it.</p>"
            "<ul>" + items + "</ul>"
            + _updated_line(updated, '<a href="/">Composite ranking</a> · '
                                     '<a href="/frameworks/">Every entry, one page each</a> · '
                                     '<a href="/docs/">How the benchmark works</a>')
            + "</div></article></main></div>")
    return head + header + body + _THEME_TOGGLE + "</body></html>"


def build_compare_pages(profiles, results, lang_rows, members_by_lang, compare_langs,
                        round_name, updated, with_og=False, fw_lang=None):
    """A head-to-head page per language, the cross-language one, and the index.

    `members_by_lang` is every language, not just the ones that earn a page:
    /compare/all/ is built from all of them, which is what gives an entry whose
    language has only one of it somewhere to be compared (#1222).
    """
    if COMPARE_OUT.exists():
        shutil.rmtree(COMPARE_OUT)
    COMPARE_OUT.mkdir(parents=True, exist_ok=True)
    written, cards = [], 0
    for lang in sorted(members_by_lang, key=str.lower):
        members = members_by_lang[lang]
        if lang not in compare_langs or len(members) < 2:
            continue
        rows = lang_rows.get(lang, [])
        page = _compare_page(lang, rows, members, profiles, results, round_name, updated,
                             (_compare_url(lang) + "og.png") if with_og else "")
        if not page:
            continue
        dest = COMPARE_OUT / _lang_slug(lang)
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "index.html").write_text(page, encoding="utf-8")
        if with_og:
            _og_card(dest / "og.png", "Head to head · " + SCOPE_NAME[DEFAULT_SCOPE],
                     lang + " web frameworks, compared",
                     [(r[0], "%.0f" % r[3]) for r in rows[:5]],
                     "%d entries · %s · www.http-arena.com" % (len(members), round_name))
            cards += 1
        written.append((lang, len(members)))

    # Every entry, whatever it is written in. Deliberately not gated on
    # compare_langs: a language with a single entry never gets a page of its
    # own, so this is the only place that entry can be compared at all.
    all_members = [m for l in sorted(members_by_lang, key=str.lower)
                   for m in members_by_lang[l]]
    all_rows = sorted((r for rows in lang_rows.values() for r in rows), key=lambda r: -r[3])
    all_page = _compare_page(None, all_rows, all_members, profiles, results, round_name,
                             updated, (_compare_url(None) + "og.png") if with_og else "",
                             fw_lang)
    if all_page:
        dest = COMPARE_OUT / COMPARE_ALL_SLUG
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "index.html").write_text(all_page, encoding="utf-8")
        if with_og:
            _og_card(dest / "og.png", "Head to head · every language",
                     "Compare any two entries, whatever they are written in",
                     [(r[0], "%.0f" % r[3]) for r in all_rows[:5]],
                     "%d entries · %s · www.http-arena.com" % (len(all_members), round_name))
            cards += 1
        written.insert(0, (None, len(all_members)))

    if with_og:
        _og_card(COMPARE_OUT / "og.png", "Head to head",
                 "Compare two web frameworks, profile by profile",
                 [(lang or "Every language", "%d entries" % n) for lang, n in
                  sorted(written, key=lambda x: -x[1])[:5]],
                 "%d languages · %s · www.http-arena.com" % (len(written), round_name))
        cards += 1
    (COMPARE_OUT / "index.html").write_text(
        _compare_index_page(written, updated, "/compare/og.png" if with_og else ""),
        encoding="utf-8")
    return written, cards


def build_fw_pages(profiles, results, meta, fw_lang, badge_index, achievements,
                   round_name, with_og, updated=""):
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

    # The per-language tables are built before the entry pages, not after: an
    # entry page now links to the entries either side of it, which is a place in
    # its language's ranking, and that ranking is this.
    kinds = {fw: meta[fw].get("type", "emerging") for fw in named}
    members_by_lang, lang_scopes = {}, {}
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
        members_by_lang[lang] = members
        lang_scopes[lang] = scopes
    # decided before the first page is written: an entry page links to the
    # comparison of its language, and only where there is one to link to
    compare_langs = _compare_langs(profiles, results, members_by_lang)

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
            _fw_page(fw, m, lang, ranks, runs, round_name, og_url, lang_url,
                     achievements.get(fw, ()), lang_scopes.get(lang), updated,
                     lang in compare_langs),
            encoding="utf-8")
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
    siblings = sorted(lang_pages, key=str.lower)
    for lang in siblings:
        dest = FW_OUT / "lang" / _lang_slug(lang)
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "index.html").write_text(
            _lang_page(lang, lang_scopes[lang], members_by_lang[lang], round_name,
                       siblings, updated, lang in compare_langs), encoding="utf-8")

    (FW_OUT / "index.html").write_text(
        _fw_index_page(entries, lang_pages, updated, compare_langs), encoding="utf-8")
    return entries, cards, siblings, lang_scopes, members_by_lang, compare_langs


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

    # tls_check verdicts, written by validate.sh when an entry opts in. Keyed by directory name, which is what validate.sh is given;
    # meta is keyed by display name, so the mapping goes through "dir".
    tls_check = {}
    tls_dir = ROOT / "site" / "data" / "tls"
    if tls_dir.is_dir():
        for f in sorted(tls_dir.glob("*.json")):
            try:
                v = json.loads(f.read_text())
            except Exception:
                continue
            if v.get("check"):
                tls_check[f.stem] = v["check"]

    meta = {n: {"type": m.get("type", "emerging"),
                "mode": m.get("mode", "standard"),
                "language": m.get("language", ""),
                "repo": m.get("repo", ""),
                "dir": m.get("dir", ""),
                "engine": m.get("engine", ""),
                "cmp": m.get("completeness"),
                "desc": m.get("description", ""),
                # Only ever set when the probes ran and were clean. Absent
                # means unverified, which the board renders as no shield
                # rather than as a failure.
                # "pass" only when the opt-in section ran and its own checks
                # were clean. Absent for every entry that did not opt in.
                "tlsCheck": tls_check.get(m.get("dir", ""))} for n, m in frameworks.items()}

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
                    for f in EFF_FIELDS:
                        if r.get(f) is not None:
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

    # Badges first: the medals are read out of the index it returns, and they
    # ship inside the board's own payload.
    n_badges, badge_index = write_badges(profiles, results, meta)
    agg = badge_aggregate(profiles, results)
    achievements = compute_achievements(agg, profiles, meta, badge_index)

    payload = {"current": current, "langColors": langcolors, "meta": meta,
               "profiles": profiles, "results": results, "docs": docs_tree,
               "achievements": achievements, "rounds": build_rounds()}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(js_payload("LB_DATA", payload))

    # Docs are pre-rendered to real /docs/<id>/ pages (SEO); the SPA links out to
    # them. LB_DATA still carries the docs *tree* for the sidebar labels, but the
    # doc *content* is no longer shipped as docs.js.
    has_og = _og_ready()
    trails = _crumb_trails(docs_tree)
    n_pages = build_doc_pages(docs_tree, docs_content, trails, with_og=has_og)
    n_search, search_bytes = write_search_index(docs_tree, docs_content)

    # The board's default view, and the same view for the other five families.
    # Same port of computeComposite() the badges use, so the ranking written into
    # the page cannot disagree with the one the page draws over it.
    fw_lang = _fw_languages(results)
    families = [(scope, badge_composite(agg, profiles, meta, scope, DEFAULT_TYPES,
                                        show_tuned=True, fw_lang=fw_lang))
                for scope in SCOPE_NAME]
    board = dict(families)[DEFAULT_SCOPE]
    round_name = payload["rounds"]["name"]

    updated = _site_updated()
    (fw_entries, n_fw_cards, lang_pages, lang_scopes,
     members_by_lang, compare_langs) = build_fw_pages(profiles, results, meta, fw_lang,
                                                      badge_index, achievements,
                                                      round_name, has_og, updated)
    compare_pages, n_cmp_cards = build_compare_pages(
        profiles, results, {l: s.get(DEFAULT_SCOPE, []) for l, s in lang_scopes.items()},
        members_by_lang, compare_langs, round_name, updated, has_og, fw_lang)
    n_urls, n_dated = write_sitemap(docs_content, fw_entries, lang_pages,
                                    [l for l, _n in compare_pages])

    # og cards go in after build_doc_pages: that one clears site/generated/docs/
    # before it writes, and the per-doc cards live inside it.
    og_url, n_cards = build_og_images(docs_content, trails, board, fw_lang, round_name)
    json_bytes = write_data_json(payload)
    # Every entry the dataset covers, not the default board view — see _dataset_node.
    n_entries = len({r["fw"] for rows_ in results.values() for r in rows_})
    index_bytes = build_index_page(board, fw_lang, current, round_name, len(profiles),
                                   n_entries, og_url, lang_pages, updated)
    llms_bytes, llms_full_bytes = write_llms_txt(docs_tree, docs_content, families,
                                                 fw_lang, current, round_name, fw_entries,
                                                 compare_pages)

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
    print(f"wrote {COMPARE_OUT.relative_to(ROOT)}/ - {len(compare_pages)} head-to-head "
          f"pages + index")
    print(f"wrote {(GEN / 'index.html').relative_to(ROOT)} - board with the "
          f"{SCOPE_NAME[DEFAULT_SCOPE]} composite ({len(board)} entries) pre-rendered, "
          f"{index_bytes // 1024} KB")
    print(f"wrote {(GEN / 'data.json').relative_to(ROOT)} - {json_bytes // 1024} KB")
    print(f"wrote {(GEN / 'llms.txt').relative_to(ROOT)} - {llms_bytes // 1024} KB, "
          f"llms-full.txt {llms_full_bytes // 1024} KB")
    print(f"wrote {n_cards + n_fw_cards + n_cmp_cards} og:image cards"
          if n_cards else "no og:image cards (Pillow missing)")


if __name__ == "__main__":
    main()
