---
title: Leaderboard
layout: wide
toc: false
---

<style>
article > h1.hx\:text-center { display: none; }
article > br { display: none; }
article { max-width: 100% !important; }
</style>

<div style="margin-bottom:1.5rem;">
<h1 class="not-prose hx:text-4xl hx:font-bold hx:leading-none hx:tracking-tighter hx:md:text-5xl hx:py-2 hx:bg-clip-text hx:text-transparent hx:bg-gradient-to-r hx:from-gray-900 hx:to-gray-600 hx:dark:from-gray-100 hx:dark:to-gray-400">Leaderboard</h1>

{{< round-selector >}}

<div class="lb-card" style="margin-top:0.75rem; padding:0.35rem;">
<div id="http-version-tabs" style="display:flex; gap:0.35rem;">
<span class="http-ver active" data-ver="composite">Composite</span>
<span class="http-ver" data-ver="h1iso">H/1.1 Isolated</span>
<span class="http-ver" data-ver="h1wk">H/1.1 Workload</span>
<span class="http-ver" data-ver="h2">H/2</span>
<span class="http-ver" data-ver="gateway">Gateway</span>
<span class="http-ver" data-ver="h3">H/3</span>
<span class="http-ver" data-ver="grpc">gRPC</span>
<span class="http-ver" data-ver="ws">WebSocket</span>
</div>
</div>
<style>
.http-ver {
  flex: 1;
  text-align: center;
  padding: 0.65rem 1.2rem;
  font-size: 0.9rem;
  font-weight: 600;
  color: #64748b;
  cursor: pointer;
  border-radius: 4px;
  background: transparent;
  transition: all 0.2s ease;
  user-select: none;
  letter-spacing: -0.01em;
}
.http-ver:hover { color: #1e293b; background: rgba(255,255,255,0.5); }
.http-ver[data-ver="h1iso"].active { color: #1e40af; background: rgba(59,130,246,0.1); box-shadow: 0 2px 8px rgba(59,130,246,0.15), 0 1px 3px rgba(0,0,0,0.08); font-weight: 700; }
.http-ver[data-ver="h1wk"].active { color: #1d4ed8; background: rgba(37,99,235,0.1); box-shadow: 0 2px 8px rgba(37,99,235,0.15), 0 1px 3px rgba(0,0,0,0.08); font-weight: 700; }
.http-ver[data-ver="h2"].active { color: #92400e; background: rgba(234,179,8,0.12); box-shadow: 0 2px 8px rgba(234,179,8,0.15), 0 1px 3px rgba(0,0,0,0.08); font-weight: 700; }
.http-ver[data-ver="gateway"].active { color: #92400e; background: rgba(234,179,8,0.12); box-shadow: 0 2px 8px rgba(234,179,8,0.15), 0 1px 3px rgba(0,0,0,0.08); font-weight: 700; }
.http-ver[data-ver="h3"].active { color: #166534; background: rgba(34,197,94,0.12); box-shadow: 0 2px 8px rgba(34,197,94,0.15), 0 1px 3px rgba(0,0,0,0.08); font-weight: 700; }
.http-ver[data-ver="composite"].active { color: #9a3412; background: rgba(249,115,22,0.12); box-shadow: 0 2px 8px rgba(249,115,22,0.15), 0 1px 3px rgba(0,0,0,0.08); font-weight: 700; }
.http-ver[data-ver="grpc"].active { color: #7c3aed; background: rgba(124,58,237,0.12); box-shadow: 0 2px 8px rgba(124,58,237,0.15), 0 1px 3px rgba(0,0,0,0.08); font-weight: 700; }
html.dark .http-ver { color: #64748b; }
html.dark .http-ver:hover { color: #94a3b8; background: rgba(255,255,255,0.03); }
html.dark .http-ver[data-ver="h1iso"].active { color: #60a5fa; background: rgba(59,130,246,0.15); }
html.dark .http-ver[data-ver="h1wk"].active { color: #93c5fd; background: rgba(37,99,235,0.15); }
html.dark .http-ver[data-ver="h2"].active { color: #fbbf24; background: rgba(234,179,8,0.15); }
html.dark .http-ver[data-ver="gateway"].active { color: #fbbf24; background: rgba(234,179,8,0.15); }
html.dark .http-ver[data-ver="h3"].active { color: #4ade80; background: rgba(34,197,94,0.15); }
html.dark .http-ver[data-ver="composite"].active { color: #fb923c; background: rgba(249,115,22,0.15); }
.http-ver[data-ver="grpc"].active { color: #7c3aed; background: rgba(124,58,237,0.12); box-shadow: 0 2px 8px rgba(124,58,237,0.15), 0 1px 3px rgba(0,0,0,0.08); font-weight: 700; }
html.dark .http-ver[data-ver="grpc"].active { color: #a78bfa; background: rgba(124,58,237,0.15); }
.http-ver[data-ver="ws"].active { color: #0891b2; background: rgba(8,145,178,0.12); box-shadow: 0 2px 8px rgba(8,145,178,0.15), 0 1px 3px rgba(0,0,0,0.08); font-weight: 700; }
html.dark .http-ver[data-ver="ws"].active { color: #22d3ee; background: rgba(8,145,178,0.15); }
</style>
<script>
(function() {
  var tabs = document.querySelectorAll('.http-ver');
  tabs.forEach(function(tab) {
    tab.addEventListener('click', function() {
      tabs.forEach(function(t) { t.classList.remove('active'); });
      tab.classList.add('active');
      var ver = tab.dataset.ver;
      document.getElementById('lb-h1iso-wrapper').style.display = ver === 'h1iso' ? '' : 'none';
      document.getElementById('lb-h1wk-wrapper').style.display = ver === 'h1wk' ? '' : 'none';
      document.getElementById('lb-h2-wrapper').style.display = ver === 'h2' ? '' : 'none';
      document.getElementById('lb-h3-wrapper').style.display = ver === 'h3' ? '' : 'none';
      document.getElementById('lb-gateway-wrapper').style.display = ver === 'gateway' ? '' : 'none';
      document.getElementById('lb-composite-wrapper').style.display = ver === 'composite' ? '' : 'none';
      document.getElementById('lb-grpc-wrapper').style.display = ver === 'grpc' ? '' : 'none';
      document.getElementById('lb-ws-wrapper').style.display = ver === 'ws' ? '' : 'none';
      /* Reset type filters to Production + Tuned active */
      document.querySelectorAll('.lb-type-filter').forEach(function(f) {
        var t = f.dataset.type;
        f.classList.toggle('active', t === 'production' || t === 'tuned');
      });
      document.querySelectorAll('.composite-type-filter').forEach(function(f) {
        var t = f.dataset.type;
        f.classList.toggle('active', t === 'production' || t === 'tuned');
      });
      /* Sync language filters — capture active langs, apply to all, then trigger re-filter */
      var activeLangs = new Set();
      var allActive = false;
      document.querySelectorAll('.lb-lang-filter').forEach(function(f) {
        if (f.classList.contains('active')) {
          if (f.dataset.lang === 'all') allActive = true;
          else activeLangs.add(f.dataset.lang);
        }
      });
      document.querySelectorAll('.lb-lang-filter').forEach(function(f) {
        if (f.dataset.lang === 'all') f.classList.toggle('active', allActive);
        else f.classList.toggle('active', allActive || activeLangs.has(f.dataset.lang));
      });
      /* Trigger re-filter on every wrapper so the newly-reset
       * Production+Tuned type filter actually takes effect on the
       * just-switched-to table. h2/h3/gateway/grpc/ws were previously
       * missing and their tables kept stale rows visible even though
       * the Production/Tuned buttons were visually toggled. */
      if (typeof applyH1IsoFilters === 'function') applyH1IsoFilters();
      if (typeof applyH1WkFilters === 'function') applyH1WkFilters();
      if (typeof applyFilters_h2 === 'function') applyFilters_h2();
      if (typeof applyFilters_h3 === 'function') applyFilters_h3();
      if (typeof applyFilters_gw === 'function') applyFilters_gw();
      if (typeof applyFilters_prodstack === 'function') applyFilters_prodstack();
      if (typeof applyFilters_grpc === 'function') applyFilters_grpc();
      if (typeof applyFilters_ws === 'function') applyFilters_ws();
      if (typeof renderComposite === 'function') renderComposite();
      if (typeof updateCompositeNote === 'function') updateCompositeNote();
    });
  });
})();
</script>
</div>

<div id="timeline-link-bar" style="display:flex; margin-top:0.5rem; padding:0.45rem 0.9rem; justify-content:flex-end; align-items:center; gap:0.5rem; font-size:0.8rem; color:#64748b;">
  <span aria-hidden="true">📈</span>
  <span id="timeline-link-prefix">Browse historical benchmark results on</span>
  <a id="timeline-link"
     href="https://kaliumhexacyanoferrat.github.io/HttpArena-Timeline/"
     target="_blank" rel="noopener"
     style="color:#7c3aed; text-decoration:none; font-weight:600;">HttpArena Timeline →</a>
</div>
<style>
html.dark #timeline-link-bar { color:#94a3b8; }
html.dark #timeline-link { color:#a78bfa; }
#timeline-link:hover { text-decoration:underline; }
</style>
<script>
(function() {
  var TIMELINE_BASE = 'https://kaliumhexacyanoferrat.github.io/HttpArena-Timeline/';
  /* Per-version: wrapper id and panel class. Composite has no entry here. */
  var VERSION_CFG = {
    h1iso:   { wrapper: 'lb-h1iso-wrapper',   panel: 'lb-panel'         },
    h1wk:    { wrapper: 'lb-h1wk-wrapper',    panel: 'lb-panel'         },
    h2:      { wrapper: 'lb-h2-wrapper',      panel: 'lb-panel-h2'      },
    gateway: { wrapper: 'lb-gateway-wrapper', panel: 'lb-panel-gw'      },
    h3:      { wrapper: 'lb-h3-wrapper',      panel: 'lb-panel-h3'      },
    grpc:    { wrapper: 'lb-grpc-wrapper',    panel: 'lb-panel-grpc'    },
    ws:      { wrapper: 'lb-ws-wrapper',      panel: 'lb-panel-ws'      }
  };
  var GENERIC_PREFIX  = 'Browse historical benchmark results on';
  var SPECIFIC_PREFIX = 'Track this test over time:';
  function setGeneric() {
    var p = document.getElementById('timeline-link-prefix');
    var l = document.getElementById('timeline-link');
    if (p) p.textContent = GENERIC_PREFIX;
    if (l) l.href = TIMELINE_BASE;
  }
  function update() {
    var verEl = document.querySelector('.http-ver.active');
    var v = verEl ? verEl.dataset.ver : 'composite';
    var cfg = VERSION_CFG[v];
    if (!cfg) { setGeneric(); return; }
    var wrap = document.getElementById(cfg.wrapper);
    if (!wrap) { setGeneric(); return; }
    var panel = wrap.querySelector('.' + cfg.panel + '.active');
    if (!panel || !panel.dataset.panel) { setGeneric(); return; }
    var test = panel.dataset.panel;
    var connTab = panel.querySelector('.lb-conn-tab.active');
    var conns = connTab ? connTab.dataset.conns : null;
    if (!conns || conns === 'best') {
      /* "Best" aggregates across conn counts; pick the highest numeric value declared on the panel for the timeline deep link. */
      var declared = (panel.dataset.conns || '').split(',').filter(function(c) { return /^\d+$/.test(c); }).map(Number);
      if (!declared.length) { setGeneric(); return; }
      conns = Math.max.apply(null, declared);
    }
    var p = document.getElementById('timeline-link-prefix');
    var l = document.getElementById('timeline-link');
    if (p) p.textContent = SPECIFIC_PREFIX;
    if (l) l.href = TIMELINE_BASE + '#test=' + test + '-' + conns;
  }
  /* Poll once a frame for the first 2 seconds in case shortcode scripts mutate state asynchronously, then settle into a low-frequency check that catches any tab/filter interaction we didn't event-hook. */
  var ticks = 0;
  var fast = setInterval(function() {
    update();
    if (++ticks > 30) { clearInterval(fast); setInterval(update, 400); }
  }, 60);
})();
</script>

<div id="lb-h1iso-wrapper" style="display:none;">
{{< leaderboard-h1-isolated >}}
</div>

<div id="lb-h1wk-wrapper" style="display:none;">
{{< leaderboard-h1-workload >}}
</div>

<div id="lb-h2-wrapper" style="display:none;">
{{< leaderboard-h2 >}}
</div>

<div id="lb-h3-wrapper" style="display:none;">
{{< leaderboard-h3 >}}
</div>

<div id="lb-gateway-wrapper" style="display:none;">
{{< leaderboard-gateway >}}
</div>

<div id="lb-grpc-wrapper" style="display:none;">
{{< leaderboard-grpc >}}
</div>

<div id="lb-ws-wrapper" style="display:none;">
{{< leaderboard-ws >}}
</div>

<div id="lb-composite-wrapper">
{{< leaderboard-composite >}}
</div>

<style>
.lb-row { position:relative; padding-left:1.75rem !important; }
.lb-fav-star { position:absolute; left:0; top:0; bottom:0; width:1.75rem; display:flex; align-items:center; justify-content:center; cursor:pointer; font-size:1.15rem; color:transparent; transition:color 0.15s; user-select:none; z-index:2; border-right:1px solid rgba(0,0,0,0.06); }
.lb-header .lb-fav-star { cursor:default; font-size:0.65rem; color:#94a3b8 !important; border-right:none; }
.lb-row:not(.lb-header):hover .lb-fav-star { color:#d1d5db; }
.lb-fav-star:hover { color:#fbbf24 !important; }
.lb-fav-star.lb-fav-active { color:#f59e0b !important; }
.lb-fav { box-shadow:inset 3px 0 0 #f59e0b; background:rgba(245,158,11,0.10) !important; padding-top:0.25rem !important; padding-bottom:0.25rem !important; }
.lb-fav:hover { background:rgba(245,158,11,0.16) !important; }
.lb-fav .lb-name { font-weight:700 !important; }
html.dark .lb-fav-star { border-right-color:rgba(255,255,255,0.06); }
html.dark .lb-header .lb-fav-star { color:#64748b !important; }
html.dark .lb-row:not(.lb-header):hover .lb-fav-star { color:#4b5563; }
html.dark .lb-fav-star:hover { color:#fbbf24 !important; }
html.dark .lb-fav-star.lb-fav-active { color:#f59e0b !important; }
html.dark .lb-fav { background:rgba(245,158,11,0.14) !important; }
html.dark .lb-fav:hover { background:rgba(245,158,11,0.22) !important; }
</style>
<script>
(function() {
  /* Favorites — star toggle on leaderboard rows, stored in localStorage */
  var STOR = 'httparena-favorites';
  var favs = new Set();
  try { JSON.parse(localStorage.getItem(STOR) || '[]').forEach(function(f) { favs.add(f); }); } catch(e) {}
  function save() { try { localStorage.setItem(STOR, JSON.stringify(Array.from(favs))); } catch(e) {} }

  function applyFavorites() {
    /* Header rows — add column marker */
    document.querySelectorAll('.lb-row.lb-header').forEach(function(hdr) {
      if (hdr.querySelector('.lb-fav-star')) return;
      var s = document.createElement('span');
      s.className = 'lb-fav-star';
      s.textContent = '\u2605';
      hdr.appendChild(s);
    });
    /* Data rows — add interactive star */
    document.querySelectorAll('.lb-row:not(.lb-header)').forEach(function(row) {
      var name = row.dataset.name;
      if (!name) return;
      var star = row.querySelector('.lb-fav-star');
      if (!star) {
        star = document.createElement('span');
        star.className = 'lb-fav-star';
        star.textContent = '\u2605';
        row.appendChild(star);
      }
      var isFav = favs.has(name);
      star.classList.toggle('lb-fav-active', isFav);
      row.classList.toggle('lb-fav', isFav);
    });
  }

  /* Star click — capture phase + stopPropagation to prevent row popup */
  document.addEventListener('click', function(e) {
    var star = e.target.closest('.lb-fav-star');
    if (!star) return;
    e.stopPropagation();
    e.preventDefault();
    var row = star.closest('.lb-row');
    var name = row ? row.dataset.name : null;
    if (!name) return;
    if (favs.has(name)) favs.delete(name); else favs.add(name);
    save();
    applyFavorites();
  }, true);

  /* Apply on load */
  applyFavorites();

  /* Watch for DOM changes (tab/filter/round switches rebuild rows) */
  var favTimer = 0;
  var obs = new MutationObserver(function() {
    clearTimeout(favTimer);
    favTimer = setTimeout(applyFavorites, 50);
  });
  ['lb-h1iso-wrapper','lb-h1wk-wrapper','lb-h2-wrapper','lb-gateway-wrapper','lb-h3-wrapper','lb-grpc-wrapper','lb-ws-wrapper','lb-composite-wrapper'].forEach(function(id) {
    var el = document.getElementById(id);
    if (el) obs.observe(el, { childList: true, subtree: true });
  });
  window.applyFavorites = applyFavorites;
})();
</script>

<script>
(function() {
  /* Deep linking — encode/restore full leaderboard UI state via URL hash
     Format: #v=h1iso&t=baseline&c=4096&type=production,tuned&lang=Rust,Go&engine=tokio&q=text */

  var dlConfig = {
    h1iso: { root: 'lb-h1iso-root', tab: 'lb-tab', panel: 'lb-panel', connPanel: 'lb-conn-panel', dd: 'lbH1IsoDropdownState', sync: 'lbH1IsoSyncDropdowns', eng: 'lbH1IsoEngineLabels', filter: 'applyH1IsoFilters' },
    h1wk:  { root: 'lb-h1wk-root',  tab: 'lb-tab', panel: 'lb-panel', connPanel: 'lb-conn-panel', dd: 'lbH1WkDropdownState',  sync: 'lbH1WkSyncDropdowns',  eng: 'lbH1WkEngineLabels',  filter: 'applyH1WkFilters' },
    h2:    { root: 'lb-h2-wrapper',   tab: 'lb-tab-h2',   panel: 'lb-panel-h2',   connPanel: 'lb-conn-panel-h2',   dd: 'lbDropdownState_h2',   sync: 'lbSyncDropdowns_h2',   eng: 'lbEngineLabels_h2',   filter: 'applyFilters_h2' },
    gateway: { root: 'lb-gateway-wrapper', tab: 'lb-tab-gw', panel: 'lb-panel-gw', connPanel: 'lb-conn-panel-gw', dd: 'lbDropdownState_gw', sync: 'lbSyncDropdowns_gw', eng: 'lbEngineLabels_gw', filter: 'applyFilters_gw' },
    h3:    { root: 'lb-h3-wrapper',   tab: 'lb-tab-h3',   panel: 'lb-panel-h3',   connPanel: 'lb-conn-panel-h3',   dd: 'lbDropdownState_h3',   sync: 'lbSyncDropdowns_h3',   eng: 'lbEngineLabels_h3',   filter: 'applyFilters_h3' },
    grpc:  { root: 'lb-grpc-wrapper', tab: 'lb-tab-grpc', panel: 'lb-panel-grpc', connPanel: 'lb-conn-panel-grpc', dd: 'lbDropdownState_grpc', sync: 'lbSyncDropdowns_grpc', eng: 'lbEngineLabels_grpc', filter: 'applyFilters_grpc' },
    ws:    { root: 'lb-ws-wrapper',   tab: 'lb-tab-ws',   panel: 'lb-panel-ws',   connPanel: 'lb-conn-panel-ws',   dd: 'lbDropdownState_ws',   sync: 'lbSyncDropdowns_ws',   eng: 'lbEngineLabels_ws',   filter: 'applyFilters_ws' }
  };

  var wrappers = { composite:'lb-composite-wrapper', h1iso:'lb-h1iso-wrapper', h1wk:'lb-h1wk-wrapper', h2:'lb-h2-wrapper', gateway:'lb-gateway-wrapper', h3:'lb-h3-wrapper', grpc:'lb-grpc-wrapper', ws:'lb-ws-wrapper' };

  function parseHash() {
    var h = location.hash.slice(1);
    if (!h) return {};
    var p = {};
    h.split('&').forEach(function(s) {
      var i = s.indexOf('=');
      if (i > 0) p[s.slice(0, i)] = decodeURIComponent(s.slice(i + 1));
    });
    return p;
  }

  function readState() {
    var verEl = document.querySelector('.http-ver.active');
    var v = verEl ? verEl.dataset.ver : 'composite';
    var state = { v: v };

    if (v === 'composite') {
      /* View (table vs graph) */
      if (typeof window.compositeGetView === 'function') {
        var cv = window.compositeGetView();
        if (cv && cv !== 'table') state.view = cv;
      }
      /* Protocol */
      var protos = [];
      document.querySelectorAll('.composite-proto-select.active').forEach(function(p) { protos.push(p.dataset.proto); });
      if (protos.length > 0 && protos.join(',') !== 'h1iso') state.proto = protos.join(',');
      /* Type */
      var ctypes = [];
      document.querySelectorAll('.composite-type-filter.active').forEach(function(f) { ctypes.push(f.dataset.type); });
      var ctypeStr = ctypes.sort().join(',');
      if (ctypeStr !== 'production,tuned') state.type = ctypeStr;
      /* Test profile filters — only if not all active */
      var activeProto = protos[0] || 'h1iso';
      var groupFilters = document.querySelectorAll('.composite-profile-filter.cp-' + activeProto);
      var allActive = document.querySelector('.composite-profile-filter[data-profile="all"]');
      if (allActive && !allActive.classList.contains('active')) {
        var tests = [];
        groupFilters.forEach(function(f) { if (f.classList.contains('active')) tests.push(f.dataset.profile); });
        if (tests.length > 0) state.tests = tests.join(',');
      }
      /* Language/engine dropdown */
      var cdd = window.compositeDropdownState;
      if (cdd) {
        if (cdd.lang && cdd.lang.selected.size < cdd.lang.all.size) {
          state.lang = Array.from(cdd.lang.selected).sort().join(',');
        }
        if (cdd.engine && cdd.engine.selected.size < cdd.engine.all.size) {
          state.engine = Array.from(cdd.engine.selected).sort().join(',');
        }
      }
      /* Resource factors */
      var res = [];
      document.querySelectorAll('.composite-resource-toggle.active').forEach(function(r) { res.push(r.dataset.resource); });
      if (res.length > 0) state.res = res.join(',');
      /* Search */
      var csi = document.querySelector('.composite-search-input');
      if (csi && csi.value.trim()) state.q = csi.value.trim();
      return state;
    }

    var cfg = dlConfig[v];
    if (!cfg) return state;
    var root = document.getElementById(cfg.root);
    if (!root) return state;

    /* Active test panel */
    var ap = root.querySelector('.' + cfg.panel + '.active');
    if (ap) state.t = ap.dataset.panel;

    /* Active conn tab — look in the active panel first, then in root */
    var connScope = ap || root;
    var ct = connScope.querySelector('.lb-conn-tab.active');
    if (ct && ct.dataset.conns !== 'best') state.c = ct.dataset.conns;

    /* Type filters — read from active panel, fallback to root */
    var typeScope = ap || root;
    var types = [];
    typeScope.querySelectorAll('.lb-type-filter.active').forEach(function(f) { types.push(f.dataset.type); });
    var typeStr = types.sort().join(',');
    if (typeStr && typeStr !== 'production,tuned') state.type = typeStr;

    /* Language/engine dropdown state */
    var dd = window[cfg.dd];
    if (dd) {
      if (dd.lang && dd.lang.selected.size < dd.lang.all.size) {
        state.lang = Array.from(dd.lang.selected).sort().join(',');
      }
      if (dd.engine && dd.engine.selected.size < dd.engine.all.size) {
        state.engine = Array.from(dd.engine.selected).sort().join(',');
      }
    }

    /* Search text */
    var si = root.querySelector('.lb-search-input');
    if (si && si.value.trim()) state.q = si.value.trim();

    return state;
  }

  function updateHash() {
    var state = readState();
    var parts = [];
    if (state.v) parts.push('v=' + state.v);
    if (state.t) parts.push('t=' + state.t);
    if (state.c) parts.push('c=' + state.c);
    if (state.type) parts.push('type=' + state.type);
    if (state.proto) parts.push('proto=' + state.proto);
    if (state.tests) parts.push('tests=' + state.tests);
    if (state.res) parts.push('res=' + state.res);
    if (state.lang) parts.push('lang=' + encodeURIComponent(state.lang));
    if (state.engine) parts.push('engine=' + encodeURIComponent(state.engine));
    if (state.q) parts.push('q=' + encodeURIComponent(state.q));
    if (state.view) parts.push('view=' + state.view);
    var newHash = parts.length > 0 ? '#' + parts.join('&') : '';
    if (location.hash !== newHash) history.replaceState(null, '', newHash || location.pathname);
  }

  var dlTimer = 0;
  window.dlScheduleUpdate = function() { clearTimeout(dlTimer); dlTimer = setTimeout(updateHash, 60); };

  function restore() {
    var p = parseHash();
    if (!p.v) return;
    var v = p.v;

    /* Show correct wrapper, set version tab */
    Object.keys(wrappers).forEach(function(k) {
      var el = document.getElementById(wrappers[k]);
      if (el) el.style.display = k === v ? '' : 'none';
    });
    document.querySelectorAll('.http-ver').forEach(function(t) {
      t.classList.toggle('active', t.dataset.ver === v);
    });

    if (v === 'composite') {
      /* Protocol */
      if (p.proto) {
        var protos = p.proto.split(',');
        document.querySelectorAll('.composite-proto-select').forEach(function(el) {
          el.classList.toggle('active', protos.indexOf(el.dataset.proto) !== -1);
        });
      }
      /* Sync test filters for the active protocol, then apply test selection */
      if (typeof window.compositeSyncTestFilters === 'function') window.compositeSyncTestFilters();
      if (p.tests) {
        var tests = p.tests.split(',');
        var activeProto = (p.proto || 'h1iso').split(',')[0];
        document.querySelectorAll('.composite-profile-filter.cp-' + activeProto).forEach(function(f) {
          f.classList.toggle('active', tests.indexOf(f.dataset.profile) !== -1);
        });
        var allBtn = document.querySelector('.composite-profile-filter[data-profile="all"]');
        if (allBtn) allBtn.classList.remove('active');
      }
      /* Type */
      if (p.type) {
        var types = p.type.split(',');
        document.querySelectorAll('.composite-type-filter').forEach(function(f) {
          f.classList.toggle('active', types.indexOf(f.dataset.type) !== -1);
        });
      }
      /* Language/engine dropdown */
      var cdd = window.compositeDropdownState;
      if (cdd) {
        if (p.lang) cdd.lang.selected = new Set(p.lang.split(','));
        if (p.engine) cdd.engine.selected = new Set(p.engine.split(','));
        if (window.compositeLangDd) window.compositeLangDd.populate();
        if (window.compositeEngineDd) window.compositeEngineDd.populate();
        /* populate() resets to all-selected, so re-apply after */
        if (p.lang) {
          cdd.lang.selected = new Set(p.lang.split(','));
          var lm = document.querySelector('.composite-dropdown[data-filter="lang"] .composite-dropdown-menu');
          if (lm) {
            lm.querySelectorAll('[data-val]:not([data-val="__all__"])').forEach(function(item) {
              item.classList.toggle('selected', cdd.lang.selected.has(item.dataset.val));
            });
            var la = lm.querySelector('[data-val="__all__"]');
            if (la) la.classList.toggle('selected', cdd.lang.selected.size === cdd.lang.all.size);
            var lc = document.querySelector('.composite-dropdown[data-filter="lang"] .composite-dropdown-count');
            var isAllLang = cdd.lang.selected.size === cdd.lang.all.size;
            if (lc) { lc.style.display = isAllLang ? 'none' : ''; lc.textContent = isAllLang ? '' : cdd.lang.selected.size; }
          }
        }
        if (p.engine) {
          cdd.engine.selected = new Set(p.engine.split(','));
          var em = document.querySelector('.composite-dropdown[data-filter="engine"] .composite-dropdown-menu');
          if (em) {
            em.querySelectorAll('[data-val]:not([data-val="__all__"])').forEach(function(item) {
              item.classList.toggle('selected', cdd.engine.selected.has(item.dataset.val));
            });
            var ea = em.querySelector('[data-val="__all__"]');
            if (ea) ea.classList.toggle('selected', cdd.engine.selected.size === cdd.engine.all.size);
            var ec = document.querySelector('.composite-dropdown[data-filter="engine"] .composite-dropdown-count');
            var isAllEng = cdd.engine.selected.size === cdd.engine.all.size;
            if (ec) { ec.style.display = isAllEng ? 'none' : ''; ec.textContent = isAllEng ? '' : cdd.engine.selected.size; }
          }
        }
      }
      /* Search */
      if (p.q) {
        var csi = document.querySelector('.composite-search-input');
        if (csi) { csi.value = p.q; }
        var ccl = document.querySelector('.composite-search-clear');
        if (ccl) ccl.style.display = '';
      }
      /* Resource factors */
      if (p.res) {
        var res = p.res.split(',');
        document.querySelectorAll('.composite-resource-toggle').forEach(function(r) {
          r.classList.toggle('active', res.indexOf(r.dataset.resource) !== -1);
        });
      } else {
        document.querySelectorAll('.composite-resource-toggle').forEach(function(r) {
          r.classList.remove('active');
        });
      }
      if (typeof renderComposite === 'function') renderComposite();
      if (typeof updateCompositeNote === 'function') updateCompositeNote();
      /* View (table vs graph) — apply after filters so the first paint uses them */
      if (typeof window.setCompositeView === 'function') {
        window.setCompositeView(p.view === 'graph' ? 'graph' : 'table');
      }
      return;
    }

    var cfg = dlConfig[v];
    if (!cfg) return;
    var root = document.getElementById(cfg.root);
    if (!root) return;

    /* Test tab */
    var testId = p.t;
    if (testId) {
      root.querySelectorAll('.' + cfg.panel).forEach(function(el) { el.classList.toggle('active', el.dataset.panel === testId); });
      root.querySelectorAll('.' + cfg.tab).forEach(function(el) { el.classList.toggle('active', el.dataset.tab === testId); });
    }

    /* Conn tab — use section-specific conn panel class */
    var connId = p.c || 'best';
    var activePanel = root.querySelector('.' + cfg.panel + '.active');
    if (activePanel) {
      activePanel.querySelectorAll('.' + cfg.connPanel).forEach(function(cp) { cp.classList.toggle('active', cp.dataset.conns === connId); });
      activePanel.querySelectorAll('.lb-conn-tab').forEach(function(ct) { ct.classList.toggle('active', ct.dataset.conns === connId); });
    }

    /* Type filters */
    var types = p.type ? p.type.split(',') : ['production', 'tuned'];
    var hasAll = types.indexOf('all') !== -1;
    root.querySelectorAll('.lb-type-filter').forEach(function(f) {
      var t = f.dataset.type;
      f.classList.toggle('active', hasAll || types.indexOf(t) !== -1);
    });

    /* Language/engine dropdown state */
    var dd = window[cfg.dd];
    if (dd) {
      if (p.lang) dd.lang.selected = new Set(p.lang.split(','));
      if (p.engine) dd.engine.selected = new Set(p.engine.split(','));
      var syncFn = window[cfg.sync];
      if (syncFn) {
        syncFn('lang', null);
        syncFn('engine', window[cfg.eng]);
      }
    }

    /* Search */
    if (p.q) {
      root.querySelectorAll('.lb-search-input').forEach(function(inp) { inp.value = p.q; });
      root.querySelectorAll('.lb-search-clear').forEach(function(btn) { btn.style.display = ''; });
    }

    /* Trigger re-filter after a frame to let DOM settle */
    requestAnimationFrame(function() {
      var filterFn = window[cfg.filter];
      if (filterFn) filterFn();
    });
  }

  /* Hook into all interactive elements — use capture phase to ensure we get events
     even if handlers in shortcodes stop propagation */
  document.addEventListener('click', function(e) {
    var t = e.target;
    if (!t || !t.closest) return;
    if (t.closest('.http-ver') || t.closest('.lb-conn-tab') || t.closest('.lb-type-filter') ||
        t.closest('.lb-dropdown-item') || t.closest('.composite-type-filter') ||
        t.closest('.composite-proto-select') || t.closest('.composite-profile-filter') ||
        t.closest('.composite-dropdown-item') || t.closest('.composite-resource-toggle') ||
        t.closest('.composite-view-tab') ||
        t.closest('[class*="lb-tab"]')) {
      window.dlScheduleUpdate();
    }
  }, true);
  document.addEventListener('input', function(e) {
    if (e.target.matches && (e.target.matches('.lb-search-input') || e.target.matches('.composite-search-input'))) window.dlScheduleUpdate();
  }, true);

  /* Restore on load and back/forward — defer to ensure all shortcode scripts have loaded */
  function deferredRestore() {
    if (location.hash.length > 1) restore();
  }
  if (document.readyState === 'complete') {
    deferredRestore();
  } else {
    window.addEventListener('load', deferredRestore);
  }
  window.addEventListener('hashchange', restore);
})();
</script>

<style>
/* Horizontal scroll for all leaderboard tables (.lb). Wide profiles like
   json-comp (14 fixed-width columns, no flex) overflow the card at typical
   desktop widths. The script below inserts a thin mirror scrollbar above
   each .lb so the user doesn't have to scroll the page down to find the
   horizontal scrollbar on tall tables. The .lb's own native scrollbar is
   hidden (we drive it via the mirror), but native wheel/touch/keyboard
   scroll on .lb still works. */
.lb { overflow-x: auto; overflow-y: hidden; -webkit-overflow-scrolling: touch; scrollbar-width: none; }
.lb::-webkit-scrollbar { display: none; }
.lb-scrollbar-top { overflow-x: auto; overflow-y: hidden; height: 12px; margin-bottom: 0.15rem; }
.lb-scrollbar-top > div { height: 1px; }
</style>
<script>
(function() {
  function attach(lb) {
    if (lb.dataset.lbSyncTop) return;
    var top = document.createElement('div');
    top.className = 'lb-scrollbar-top';
    var track = document.createElement('div');
    top.appendChild(track);
    lb.parentNode.insertBefore(top, lb);
    var ignore = false;
    top.addEventListener('scroll', function() { if (ignore) return; ignore = true; lb.scrollLeft = top.scrollLeft; requestAnimationFrame(function() { ignore = false; }); });
    lb.addEventListener('scroll', function() { if (ignore) return; ignore = true; top.scrollLeft = lb.scrollLeft; requestAnimationFrame(function() { ignore = false; }); });
    function resize() { track.style.width = lb.scrollWidth + 'px'; top.style.display = lb.scrollWidth > lb.clientWidth ? '' : 'none'; }
    if (window.ResizeObserver) new ResizeObserver(resize).observe(lb);
    resize();
    lb.dataset.lbSyncTop = '1';
  }
  function attachAll() { document.querySelectorAll('.lb').forEach(attach); }
  if (document.readyState === 'complete') attachAll();
  else window.addEventListener('load', attachAll);
  /* Tab/filter switches and dynamic re-renders create new .lb elements;
     a low-frequency sweep catches them without hooking every event. */
  setInterval(attachAll, 2000);
})();
</script>
