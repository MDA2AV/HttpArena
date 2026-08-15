#!/usr/bin/env node
//
// The badge ranks are produced by a Python port (write_badges() in
// gen_leaderboard_data.py) of the board's client-side scoring. Two copies of
// one formula drift, and the drift is silent: the badge keeps rendering, it
// just stops agreeing with the page it links to.
//
// So run the real thing. This lifts the scoring functions out of
// site/leaderboard/index.html verbatim — no reimplementation — evaluates them
// against the same data.js the browser gets, and diffs every rank against
// site/generated/badge/index.json.
//
//     node scripts/check_badge_parity.js
//
// Non-zero exit on any disagreement. Run it after gen_leaderboard_data.py.
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const HTML = path.join(ROOT, 'site/leaderboard/index.html');
const DATA = path.join(ROOT, 'site/leaderboard/data.js');
const INDEX = path.join(ROOT, 'site/generated/badge/index.json');

for (const f of [HTML, DATA, INDEX]) {
  if (!fs.existsSync(f)) {
    console.error(`missing ${path.relative(ROOT, f)} — run scripts/gen_leaderboard_data.py first`);
    process.exit(2);
  }
}

// ── lift the scoring out of the page ────────────────────────────────────────
// Anchored on the section comments and the one-line helpers. If a rename breaks
// an anchor this throws rather than silently checking nothing.
const src = fs.readFileSync(HTML, 'utf8');
function grab(re, what) {
  const m = src.match(re);
  if (!m) {
    console.error(`could not lift ${what} out of index.html — the anchor moved.`);
    console.error('Re-point the regex in this script at the renamed code; do not skip the check.');
    process.exit(2);
  }
  return m[0];
}
const composite = grab(/\/\/ ── COMPOSITE scoring[\s\S]*?(?=\/\/ ── render)/, 'the composite block');
const familyOf = grab(/^\s*function familyOf\(p\)\{.*$/m, 'familyOf()');
const memFn = grab(/^\s*function mem\(s\)\{.*$/m, 'mem()');
const bwFn = grab(/^\s*function bw\(s\)\{.*$/m, 'bw()');

// ── the data the browser would have ─────────────────────────────────────────
const window = {};
new Function('window', fs.readFileSync(DATA, 'utf8'))(window);
const D = window.LB_DATA;

// Everything the lifted code reaches for that lives elsewhere in the page.
// state is pinned to the board's defaults — the view a visitor lands on when
// they follow the badge and touch nothing.
// langOf is real here, not a stub returning '': the board's state.lang filter
// goes through it, and the language rank badges are checked against that filter.
const stubs = `
  var PROF = {}; D.profiles.forEach(function(p){ PROF[p.id]=p; });
  var FWLANG = {};
  Object.keys(D.results).forEach(function(k){ D.results[k].forEach(function(r){ if(r.lang) FWLANG[r.fw]=r.lang; }); });
  function typeOf(fw){ return (D.meta[fw] && D.meta[fw].type) || 'emerging'; }
  function modeOf(fw){ return (D.meta[fw] && D.meta[fw].mode) || 'standard'; }
  function langOf(fw){ return FWLANG[fw] || ''; }
  function matchQ(fw){ return true; }              // state.q is '' — no search filter
  var state = { useMem:false, rescale:false, showTuned:true, q:'', lang:'', scope:'h1', types:[] };
`;
const run = new Function('D', `
  ${stubs}
  ${familyOf}
  ${memFn}
  ${bwFn}
  ${composite}
  return function(scope, types, lang){
    state.scope = scope; state.types = types; state.lang = lang || '';   // AGG is state-independent, so its cache is safe
    return computeComposite();
  };
`)(D);

// ── rank the same way write_badges() does ───────────────────────────────────
const FAMILIES = ['h1', 'h2', 'h3', 'gw', 'grpc', 'ws'];
const LEAGUES = [['flagship', 'emerging'], ['engine'], ['experimental']];
const MIN_FIELD = 2;

// NO score filter here. An earlier version dropped rows scoring 0 before
// comparing, which is exactly what the generator was doing wrong — so the check
// compared a filtered board against an identically-filtered port and passed
// while the published field was one short of the board's. Whatever the board
// renders as a row is the field, and that is what gets compared.
function ranked(scope, types, lang) {
  const rows = run(scope, types, lang).rows
    .sort((a, b) => (b.score - a.score) || (a.fw < b.fw ? -1 : a.fw > b.fw ? 1 : 0));
  const out = new Map();
  let prevScore = null, prevRank = 0;
  rows.forEach((r, i) => {
    const rank = (prevScore !== null && Math.abs(prevScore - r.score) < 1e-9) ? prevRank : i + 1;
    prevScore = r.score; prevRank = rank;
    out.set(r.fw, { rank, of: rows.length, score: r.score });
  });
  return out;
}

// Every language present, from the same rows the board reads it from.
const FWLANG = {};
Object.keys(D.results).forEach(k => D.results[k].forEach(r => { if (r.lang) FWLANG[r.fw] = r.lang; }));
const LANGS = [...new Set(Object.values(FWLANG))].sort();

// Same rule as _slug() in gen_leaderboard_data.py / rebuild_site_data.py.
const slug = n => (n.replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'unnamed').toLowerCase();

const emitted = JSON.parse(fs.readFileSync(INDEX, 'utf8'));
const problems = [];
let checked = 0;

for (const scope of FAMILIES) {
  for (const types of LEAGUES) {
    const expect = ranked(scope, types);
    for (const [fw, e] of expect) {
      const got = emitted[slug(fw)] && emitted[slug(fw)].scopes[scope];
      if (e.of < MIN_FIELD) {
        if (got) problems.push(`${fw} ${scope}: badge emitted for a field of ${e.of} (min ${MIN_FIELD})`);
        continue;
      }
      // Counted in the field, but deliberately given no badge of its own —
      // nothing it ran scores in this family, so it has no placing to claim.
      if (e.score <= 0) {
        if (got) problems.push(`${fw} ${scope}: badge emitted for an entry scoring 0`);
        continue;
      }
      checked++;
      if (!got) { problems.push(`${fw} ${scope}: board ranks it #${e.rank} of ${e.of}, no badge emitted`); continue; }
      if (got.rank !== e.rank || got.of !== e.of) {
        problems.push(`${fw} ${scope}: badge says #${got.rank} of ${got.of}, board says #${e.rank} of ${e.of}`);
      }
      if (Math.abs(got.score - e.score) > 0.05) {
        problems.push(`${fw} ${scope}: badge score ${got.score}, board score ${e.score.toFixed(1)}`);
      }
    }

    // The language variant, checked against the board's own lang= filter rather
    // than against a subset this script computes — otherwise "#1 of 6 (Rust)"
    // would only ever be compared with itself.
    for (const lang of LANGS) {
      const expect = ranked(scope, types, lang);
      for (const [fw, e] of expect) {
        const got = emitted[slug(fw)] && emitted[slug(fw)].scopes[scope]
                 && emitted[slug(fw)].scopes[scope].byLanguage;
        if (e.of < MIN_FIELD || e.score <= 0) {
          if (got) problems.push(`${fw} ${scope} (${lang}): badge emitted for a field of ${e.of}, score ${e.score.toFixed(1)}`);
          continue;
        }
        checked++;
        if (!got) { problems.push(`${fw} ${scope} (${lang}): board ranks it #${e.rank} of ${e.of}, no language badge emitted`); continue; }
        if (got.rank !== e.rank || got.of !== e.of) {
          problems.push(`${fw} ${scope} (${lang}): badge says #${got.rank} of ${got.of}, board says #${e.rank} of ${e.of}`);
        }
      }
    }
  }
}

// And the other direction — a badge the board would not produce at all.
for (const [s, entry] of Object.entries(emitted)) {
  for (const scope of Object.keys(entry.scopes)) {
    const seen = LEAGUES.some(types => ranked(scope, types).has(entry.framework));
    if (!seen) problems.push(`${entry.framework} ${scope}: badge emitted but the board ranks no such entry`);
  }
}

if (problems.length) {
  console.error(`badge parity: ${problems.length} disagreement(s) with site/leaderboard/index.html\n`);
  problems.slice(0, 40).forEach(p => console.error('  ' + p));
  if (problems.length > 40) console.error(`  ... and ${problems.length - 40} more`);
  console.error('\nThe Python port in gen_leaderboard_data.py has drifted from the board. Fix the port.');
  process.exit(1);
}

console.log(`badge parity ok — ${checked} ranks match site/leaderboard/index.html`);
