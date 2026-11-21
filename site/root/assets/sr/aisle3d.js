/* HttpArena - the 3D aisle.

   The aisle view as a room to walk through, where every physical thing is a
   measurement. Each framework is a 1U unit, racked by rank (R1 from the top
   down, then R2, ...): an LED equaliser per test, fans that spin with its CPU,
   an activity light that blinks faster the closer it is to the leader, an
   error light, completeness pips and a memory gauge. Slide one out and its lid
   goes back: a CPU that glows with its load, RAM by its memory, a NIC that
   flickers with its throughput, a chip per test as a little bar chart, and its
   strength as a hologram above it. Each rack scrolls its stats on a marquee,
   wears its language mix on a power strip and warms the floor in front of it;
   the wall at the end of the aisle is the operations wall.

   With opts.sections the room is a corridor: a lobby (the overall board, the
   test machine, the comparison bench), then a stretch of racks for each
   section in order, all on the left of a cold aisle with closed cabinets
   facing them, each section with a lit sign, a lane on the floor and a
   kiosk; the podium and the wall at the far end speak for the section you
   are in. A crash cart rolls up to a unit and
   shows its implementation (opts.sourceUrl); up to four units go to the bench
   to be compared. Without sections it is the one aisle, as before.

     open(opts) -> Promise<{ close(), setFav(fw, on), focus(fw) }>

   opts: host, theme, title, subtitle, world, perRack, onFav(fw), onClose(),
     tests, units                      the one aisle (or the fallback)
     sections: [{ id, label, name, metric, tests, units }], start, overall
     detailHtml(fw, sectionId), ledTipHtml(fw, i, sectionId)
     sourceUrl(fw, sectionId) -> URL of an implementation bundle (JSON);
     repoUrl(fw, sectionId) -> where to send people when there is none (optional)

   close() disposes everything and does not call onClose (the page asked for
   it); the module calls onClose only when it closed itself. With Motion off it
   draws only while something moves; with Motion on it runs the room's ambient
   motion at a capped rate while the tab is visible. Far from the camera a
   panel is a slot in one atlas; near it, it gets its own texture, a few a
   frame, from a pool.

   The picture: on a desktop the room is drawn into a multisampled HDR target,
   then ambient occlusion and bloom, tone mapped once on the way to the screen
   (makePost); a slow machine gives up the occlusion, then the bloom, then
   pixels. On a phone it is drawn straight to the screen. The light fittings
   overhead light the room as two long lights in every lit material. */
import * as THREE from '../vendor/three/three.module.min.js';
import { OrbitControls } from '../vendor/three/OrbitControls.js';
import { GTAOShader, generateMagicSquareNoise } from '../vendor/three/GTAOShader.js';

/* ── dimensions, in metres ─────────────────────────────────────────────── */
const U = 0.04445;                 // one rack unit, 1.75"
const UNIT_H = 0.0434;             // a 1U front panel, a hair under 1U
const PANEL_W = 0.4826;            // 19", the ears included
const BODY_W = 0.434, BODY_D = 0.64, PLATE_T = 0.0025;
const PITCH = 0.6, RACK_W = 0.597, RACK_D = 1.07, SIDE_T = 0.014;
const OPEN_HALF = 0.2254;          // half the 450 mm opening between the posts
const POST_W = 0.045, POST_D = 0.022;
const RECESS = 0.034;              // the posts sit behind the cabinet's front frame
const PLINTH_H = 0.07, BASE_Y = 0.1, TOP_H = 0.17, FRAME_D = 0.03;
const FACE_Z = -RECESS + PLATE_T;  // the front of a racked panel
const POP = 0.46, LIFT = 0.017;    // slid out, and lifted under the pointer
const CHART_MAX = 0.44;            // the longest drawer in the drawer chart
const LID_BACK = 0.36;             // how far an open unit's lid slides back
const OPP_Z = 4.2, CEIL = 3.2;     // the facing row across the aisle, the ceiling
const FOV = 40, DEG = Math.PI / 180;
const TW = 1024, TH = 92;          // a panel's texture (1 px ~ 0.47 mm)
const LED_Z = 0.0012, EQ_SEGS = 7;
const MQ_COLS = 132, MQ_ROWS = 16; // the marquee's dot matrix
// the corridor: a lobby, then each section's bay (its sign and kiosk), its racks, and the end bay
const LOBBY = 7.4, SEC_LEAD = 1.8, END_BAY = 3.7;
const BENCH_Y = 0.86;              // the comparison bench's top
const SCR_W = 0.52, SCR_H = 0.325; // the crash cart's screen, 16:10
const MON_W = 1000, MON_H = 625;   // its console, in CSS pixels
const NEAR_R = 4.2;                // within this, a panel gets its own sharp texture (a whole rack, seen from its view)

const FONT_LABEL = '"Saira SC", "Inter", system-ui, sans-serif';
const FONT_SANS = '"Inter", system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
const FONT_SEG = '"DSEG7", "Red Hat Mono", ui-monospace, monospace';
const TYPE_COLORS = { flagship: '#22c55e', emerging: '#4c9bff', experimental: '#f5a524', engine: '#ef5b4c', infrastructure: '#22b8cf' };
const TYPE_NAMES = { flagship: 'Flagship', emerging: 'Emerging', experimental: 'Experimental', engine: 'Engine', infrastructure: 'Infrastructure' };
const RANK_PLATES = {
  1: ['#f9e08a', '#d9a521', '#f3d36b', '#201603'],
  2: ['#f1f4f7', '#aab3bd', '#e3e8ed', '#1a1f24'],
  3: ['#f0bf95', '#b9713a', '#e3a878', '#241003'],
};
const CAT_COLORS = ['#62c4ff', '#3dff8f', '#ffb020', '#ff7ab6', '#b58cff', '#4fd1c5', '#ff8a5b', '#c4e05a', '#8fb3ff', '#f2d16b'];
const PULL = [['off', 'Off'], ['score', 'Score'], ['cpu', 'CPU'], ['mem', 'Memory'], ['p99', 'p99']];

/* ── the two rooms: the hall at night, and the clean room ──────────────── */
const DARK = {
  exposure: 1.0, envK: 1.0, bg: 0x07090c, fogD: 0.06,
  ao: { k: 0.9, radius: 0.85, thickness: 0.6, scale: 1.8 }, bloom: { k: 0.22, threshold: 0.85, knee: 0.5, scatter: 0.85 },
  hemi: [0x9fb6cf, 0x040506, 0.36], dir: [0xdde9f6, 0.6], spot: [0xd8e9ff, 26], spots: 4, lineK: 2.4,
  floor: '#353c45', speck: ['#424a54', '#262b32'], seam: '#08090b', perfHole: '#030405', perfRing: '#4b545e', floorRough: 0.86,
  wall: 0x0b0e11, ceil: 0x090b0e, wallWash: 0x1b2836,
  frame: 0x1e2329, frameRough: 0.4, frameMetal: 0.8, inner: 0x07080a, plinth: 0x0b0c0e,
  post: 0x1b1f24, postFace: '#1d2126', postHole: '#020303', postSilk: '#7f8a96', postTick: '#2e353c',
  face: ['#2e3339', '#24282d', '#1a1d21'], faceHi: '#454c55', faceLo: '#060708', grain: ['#ffffff', '#000000'], grainK: 0.05,
  ear: '#1f2328', earSeam: '#0b0d0f', screw: ['#7a838d', '#2d3238', '#0c0e10'],
  silk: '#aab4bf', name: '#f2f4f6', nameFav: '#9ad8ff',
  bay: '#0f1215', bayLine: '#363d45', langText: '#e8ecf0',
  ledHole: '#040506', ledRim: '#3c434b',
  lcdBezel: '#0a0c0e', lcdBg: '#030605', lcdFg: '#7dfbd8', lcdGlow: 'rgba(125,251,216,0.6)', lcdGhost: 0.075, lcdLit: true,
  ledG: '#3dff8f', ledB: '#3aa0ff', ledA: '#ffb020', ledR: '#ff5247', ledOff: '#1b2025', eqOff: '#151a1f',
  body: 0x30353b, rail: 0x7a838c,
  plate: '#0b0e11', plateLine: '#2b3138', plateText: '#eef1f4', plateMuted: '#8e99a4', plateLit: true,
  faceEm: 0.34, faceEmHot: 0.62, ledBoost: 1.0, glowK: 1.0, eqGlowK: 0.2, decorGlowK: 0.75,
  lamp: 0xe9f3ff, lampK: 2.6, fixture: 0x2a2f36, tray: 0x3b424a, cable: [0x1f5fae, 0xb8901c],
  door: '#111418', doorFrame: '#191c21', doorBack: '#040506', doorKit: ['#262b31', '#2f353c', '#1d2126'], rear: '#0c0e11', rearHole: '#2a3a4c', rearLit: 0.55,
  favAdd: true, favK: 0.42, favPipeK: 3.6,
  sticker: '#e6e9ec', stickerText: '#14181d', lid: ['#3a4047', '#2c3137'],
  sign: '#0b0e12', signText: '#f2f4f6', signMuted: '#9da7b2', signLine: '#62c4ff', signLit: true,
  fan: ['#2c3238', '#59626c', '#06080a'],
  ramp: ['#2f7bff', '#2fd3c8', '#ffd04a', '#ff7a1a'],
  heat: ['#1a0400', '#b42000', '#ff6a00', '#ffd88a'],
  holo: '#7cf4ff', holoAdd: true,
  mq: ['#ffb020', '#2a1b07', '#040506'],
  pdu: ['#121519', '#050607', '#7dfbd8'],
  pcb: ['#0d2a20', '#1b5a41', '#d6ede0', '#b9913f'],
  stripK: 1.8, stripGlow: 0.5,
  secs: ['#4aa8ff', '#3ddc84', '#b58cff', '#ffb020', '#2fd3c8', '#ff6fae', '#ff8a5b', '#c4e05a'],
  cmp: ['#4aa8ff', '#ffb020', '#ff5fa2', '#3ddc84'],
  laneK: 1.25, signK: 1, cart: [0x2b3138, 0x15181c, 0x0b0d10], bench: [0x2a3038, 0x6b5a45],
  haze: 0x111925, hazeD: 0.026, deck: 0x07090c, steel: 0x2c333b, sprink: 0x8f1f18, duct: 0x3e464f, mull: 0x161a1f, glass: [0x9fc3e8, 0.1], crah: [0x262c33, '#1c2228', '#0b0e12'], desk: [0x14171b, 0x2b3036], ground: 0x07090d, night: true,
  noc: { bg: '#090d12', card: '#0e141b', line: '#1f2a36', text: '#eef3f7', muted: '#8c99a7', accent: '#62c4ff', grid: 'rgba(98,196,255,0.06)', bar: '#3dff8f', sel: 'rgba(98,196,255,0.16)' },
};
const LIGHT = {
  exposure: 1.0, envK: 0.42, bg: 0xdde2e7, fogD: 0.035,
  ao: { k: 0.9, radius: 0.85, thickness: 0.5, scale: 1.7 }, bloom: { k: 0.06, threshold: 1.6, knee: 0.6, scatter: 0.7 },
  hemi: [0xffffff, 0xb9c1c9, 0.8], dir: [0xffffff, 1.0], spot: [0xffffff, 5], spots: 2, lineK: 2.4,
  floor: '#dfe3e7', speck: ['#eceff2', '#c9d0d6'], seam: '#8d97a1', perfHole: '#6f7a85', perfRing: '#f2f4f6', floorRough: 0.88,
  wall: 0xe6eaee, ceil: 0xf1f3f5, wallWash: 0x000000,
  frame: 0x353b42, frameRough: 0.52, frameMetal: 0.3, inner: 0x1c2025, plinth: 0x23282d,
  post: 0x444c54, postFace: '#4d555e', postHole: '#16191d', postSilk: '#dfe4e9', postTick: '#646d76',
  face: ['#f4f6f8', '#e4e8ec', '#d2d8de'], faceHi: '#ffffff', faceLo: '#7d8893', grain: ['#ffffff', '#6f7a85'], grainK: 0.035,
  ear: '#d6dbe0', earSeam: '#a3adb7', screw: ['#ffffff', '#bcc4cc', '#7f8a95'],
  silk: '#2b3641', name: '#0b0f14', nameFav: '#0a56b8',
  bay: '#d9dee3', bayLine: '#98a2ac', langText: '#0b1118',
  ledHole: '#3d4650', ledRim: '#aeb7c0',
  lcdBezel: '#8d97a1', lcdBg: '#bccab0', lcdFg: '#17251a', lcdGlow: '', lcdGhost: 0.09, lcdLit: false,
  ledG: '#16b75c', ledB: '#1c7cf0', ledA: '#e08a00', ledR: '#dc3b2f', ledOff: '#a9b1b9', eqOff: '#aab3bc',
  body: 0xbfc6cd, rail: 0x8e979f,
  plate: '#f6f7f8', plateLine: '#c7ced5', plateText: '#0f1318', plateMuted: '#47525e', plateLit: false,
  faceEm: 0.03, faceEmHot: 0.16, ledBoost: 1.1, glowK: 0.55, eqGlowK: 0.35, decorGlowK: 0.6,
  lamp: 0xffffff, lampK: 1.6, fixture: 0xc9cfd5, tray: 0x9aa3ac, cable: [0x2f7fd6, 0xf2c230],
  door: '#363c43', doorFrame: '#30363c', doorBack: '#0d0f12', doorKit: ['#4a525b', '#58616a', '#3f464e'], rear: '#2a3036', rearHole: '#aab4be', rearLit: 0.25,
  favAdd: false, favK: 0.2, favPipeK: 1.6,
  sticker: '#ffffff', stickerText: '#14181d', lid: ['#c9d0d6', '#b7bfc6'],
  sign: '#ffffff', signText: '#0f1318', signMuted: '#47525e', signLine: '#0a5cc0', signLit: false,
  fan: ['#8a949e', '#55606b', '#20252b'],
  ramp: ['#1c6fe0', '#13a497', '#d9a400', '#e0601a'],
  heat: ['#3a0a00', '#c42a00', '#ff6a00', '#ffd27a'],
  holo: '#0b7fb0', holoAdd: false,
  mq: ['#ffb020', '#2a1b07', '#040506'],
  pdu: ['#2a3036', '#111418', '#7dfbd8'],
  pcb: ['#123d2c', '#21704f', '#e6f3eb', '#c49a45'],
  stripK: 1.15, stripGlow: 0.22,
  secs: ['#1c6fe0', '#139a52', '#7a4fd6', '#c27400', '#0f9488', '#d0306f', '#d2561f', '#6f8f12'],
  cmp: ['#1c6fe0', '#c27400', '#d0306f', '#139a52'],
  laneK: 0.85, signK: 1, cart: [0x59626c, 0x2a3036, 0x1a1e23], bench: [0xb9c1c9, 0x8a7258],
  haze: 0xdce3ea, hazeD: 0.013, deck: 0xe9edf0, steel: 0xd0d6dc, sprink: 0xc0302a, duct: 0xa9b2ba, mull: 0xaeb8c2, glass: [0xd6e9f7, 0.1], crah: [0xd9dee2, '#c9d0d6', '#8a949e'], desk: [0xf2f4f6, 0x9b7b5a], ground: 0x93a08f, night: false,
  noc: { bg: '#f5f7f9', card: '#ffffff', line: '#d5dbe1', text: '#0f1318', muted: '#47525e', accent: '#0a5cc0', grid: 'rgba(10,92,192,0.05)', bar: '#16b75c', sel: 'rgba(10,92,192,0.12)' },
};

/* ── the HUD's styles, scoped to the host; the page's tokens when it has them ── */
const CSS = `
.a3d-host{--a3-bg:var(--bg,#090b0e);--a3-panel:var(--panel,#13161a);--a3-panel-2:var(--panel-2,#1a1e23);--a3-text:var(--text,#f2f4f6);--a3-text-2:var(--text-2,#c6cdd5);--a3-muted:var(--muted,#9da7b2);--a3-line:var(--line,#383f47);--a3-accent:var(--accent,#62c4ff);--a3-led-g:var(--led-g,#3dff8f);--a3-led-b:var(--led-b,#3aa0ff);--a3-led-a:var(--led-a,#ffb020);--a3-led-r:var(--led-r,#ff5247);--a3-led-off:var(--led-off,#2c3238);--a3-gold:var(--gold,#e3b54a);--a3-silver:var(--silver,#b6bfca);--a3-bronze:var(--bronze,#d9925c);--a3-sans:var(--sans,"Inter",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif);--a3-label:var(--label,"Saira SC","Inter",system-ui,sans-serif);--a3-shadow:0 14px 34px -12px rgba(0,0,0,.75),0 1px 2px rgba(0,0,0,.5);--a3-glass:82%}
.a3d-host.a3d-light{--a3-bg:var(--bg,#e8ebee);--a3-panel:var(--panel,#ffffff);--a3-panel-2:var(--panel-2,#f1f3f5);--a3-text:var(--text,#0f1318);--a3-text-2:var(--text-2,#313b46);--a3-muted:var(--muted,#47525e);--a3-line:var(--line,#b3bcc5);--a3-accent:var(--accent,#0a5cc0);--a3-led-g:var(--led-g,#16b75c);--a3-led-b:var(--led-b,#1c7cf0);--a3-led-a:var(--led-a,#e08a00);--a3-led-r:var(--led-r,#dc3b2f);--a3-led-off:var(--led-off,#aab2ba);--a3-gold:var(--gold,#9a7412);--a3-silver:var(--silver,#5f6975);--a3-bronze:var(--bronze,#96582a);--a3-shadow:0 14px 32px -14px rgba(20,30,45,.38),0 1px 2px rgba(20,30,45,.14);--a3-glass:86%}
.a3d{position:absolute;inset:0;overflow:hidden;overscroll-behavior:contain;touch-action:none;background:var(--a3-bg);color:var(--a3-text);font:14px/1.45 var(--a3-sans);-webkit-font-smoothing:antialiased;-webkit-tap-highlight-color:transparent;text-align:left}
.a3d *,.a3d *::before,.a3d *::after{box-sizing:border-box}
.a3d-cv{position:absolute;inset:0;width:100%;height:100%;display:block;outline:none;touch-action:none;cursor:grab}
.a3d-cv.hot{cursor:pointer}
.a3d-cv.drag{cursor:grabbing}
.a3d-glass{background:color-mix(in srgb,var(--a3-panel) var(--a3-glass),transparent);border:1px solid var(--a3-line);border-radius:12px;box-shadow:var(--a3-shadow);-webkit-backdrop-filter:blur(12px) saturate(1.15);backdrop-filter:blur(12px) saturate(1.15)}
.a3d-top{position:absolute;left:16px;right:16px;top:14px;display:flex;align-items:flex-start;justify-content:space-between;gap:10px;flex-wrap:wrap;pointer-events:none;z-index:3}
.a3d-top>*{pointer-events:auto}
.a3d-title{padding:9px 15px 10px;min-width:0;max-width:min(560px,100%)}
.a3d-title b{display:block;font-size:16px;font-weight:650;line-height:1.3;color:var(--a3-text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.a3d-title span{display:block;font-size:13px;line-height:1.4;color:var(--a3-muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.a3d-nav{display:flex;align-items:center;gap:6px;padding:6px;flex-wrap:wrap;justify-content:flex-end}
.a3d-btn{appearance:none;-webkit-appearance:none;display:inline-flex;align-items:center;justify-content:center;gap:7px;height:34px;margin:0;padding:0 12px;border-radius:8px;border:1px solid var(--a3-line);background:var(--a3-panel-2);color:var(--a3-text);font:600 13px/1 var(--a3-sans);cursor:pointer;white-space:nowrap;text-decoration:none;transition:border-color .12s ease,background-color .12s ease}
.a3d-btn:hover{border-color:var(--a3-accent)}
.a3d-btn:focus-visible,.a3d-seg button:focus-visible,.a3d-seg select:focus-visible,.a3d-find input:focus-visible{outline:2px solid var(--a3-accent);outline-offset:2px}
.a3d-btn:disabled{opacity:.42;cursor:default;border-color:var(--a3-line)}
.a3d-btn svg{width:16px;height:16px;flex:none;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
.a3d-chips{display:flex;gap:4px}
.a3d-chip{padding:0 10px;gap:6px}
.a3d-chip small{font-size:12px;font-weight:500;color:var(--a3-muted);font-variant-numeric:tabular-nums}
.a3d-chip.on{border-color:var(--a3-accent);background:color-mix(in srgb,var(--a3-accent) 16%,var(--a3-panel-2))}
.a3d-sep{width:1px;height:22px;background:var(--a3-line);margin:0 3px;flex:none}
.a3d-bar{position:absolute;left:16px;bottom:14px;display:flex;align-items:center;gap:8px;padding:6px;z-index:3;max-width:calc(100% - 32px);flex-wrap:wrap}
.a3d-find{position:relative;flex:none}
.a3d-find input{appearance:none;-webkit-appearance:none;height:34px;width:210px;margin:0;padding:0 10px 0 33px;border-radius:8px;border:1px solid var(--a3-line);background:var(--a3-panel-2);color:var(--a3-text);font:500 13px/1 var(--a3-sans);outline:none}
.a3d-find input::placeholder{color:var(--a3-muted);opacity:1}
.a3d-find input:focus{border-color:var(--a3-accent)}
.a3d-find>svg{position:absolute;left:10px;top:50%;transform:translateY(-50%);width:15px;height:15px;stroke:var(--a3-muted);fill:none;stroke-width:2;stroke-linecap:round;pointer-events:none}
.a3d-res{position:absolute;left:0;bottom:calc(100% + 10px);width:300px;max-height:340px;overflow:auto;margin:0;padding:6px;list-style:none;display:none}
.a3d-res.on{display:block}
.a3d-res li{display:flex;align-items:center;gap:8px;padding:7px 9px;border-radius:7px;cursor:pointer;font-size:13px;color:var(--a3-text-2)}
.a3d-res li.sel,.a3d-res li:hover{background:var(--a3-panel-2);color:var(--a3-text)}
.a3d-res li b{font-weight:650;color:var(--a3-text);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.a3d-res li i{width:9px;height:9px;border-radius:2px;flex:none}
.a3d-res li small{margin-left:auto;padding-left:8px;color:var(--a3-muted);font-size:12px;font-variant-numeric:tabular-nums;white-space:nowrap}
.a3d-res li.none{cursor:default;color:var(--a3-muted)}
.a3d-seg{display:inline-flex;align-items:center;gap:2px;height:34px;padding:2px;border-radius:9px;border:1px solid var(--a3-line);background:var(--a3-panel-2);flex:none}
.a3d-seg>span{font-size:12.5px;font-weight:500;color:var(--a3-muted);padding:0 6px 0 8px;white-space:nowrap}
.a3d-seg button,.a3d-seg select{appearance:none;-webkit-appearance:none;border:0;margin:0;background:transparent;color:var(--a3-text-2);font:600 12.5px/1 var(--a3-sans);height:28px;padding:0 10px;border-radius:7px;cursor:pointer;white-space:nowrap}
.a3d-seg select{padding-right:22px;background-image:linear-gradient(45deg,transparent 50%,currentColor 50%),linear-gradient(135deg,currentColor 50%,transparent 50%);background-position:calc(100% - 12px) 12px,calc(100% - 8px) 12px;background-size:4px 4px;background-repeat:no-repeat;max-width:150px}
.a3d-seg select option{color:#0f1318;background:#fff}
.a3d-seg button:hover,.a3d-seg select:hover{color:var(--a3-text)}
.a3d-seg button[aria-pressed="true"],.a3d-seg select.on{background:var(--a3-accent);color:var(--a3-bg)}
.a3d-show-s{display:none}
.a3d-tog i{width:9px;height:9px;border-radius:50%;flex:none;background:var(--a3-led-off);box-shadow:inset 0 0 0 1px rgba(0,0,0,.35)}
.a3d-tog[aria-pressed="true"] i{background:var(--a3-led-g);box-shadow:0 0 0 1px rgba(0,0,0,.2),0 0 8px 1px var(--a3-led-g)}
.a3d-lit{gap:8px}
.a3d-lit i{width:10px;height:10px;border-radius:2px;flex:none}
.a3d-lit[hidden]{display:none}
.a3d-keys{position:absolute;left:16px;bottom:72px;z-index:3;width:min(350px,calc(100% - 32px));padding:11px 13px 11px;font-size:12.5px;line-height:1.5;color:var(--a3-text-2)}
.a3d-keys[hidden]{display:none}
.a3d-keys b{display:block;font-size:13px;font-weight:650;color:var(--a3-text);margin-bottom:4px}
.a3d-keys ul{margin:0;padding:0 0 0 16px}
.a3d-keys li{margin:2px 0}
.a3d-keys kbd{display:inline-block;min-width:20px;text-align:center;font:600 12px/1 var(--a3-sans);padding:3px 5px 2px;margin:0 1px;border:1px solid var(--a3-line);border-bottom-width:2px;border-radius:5px;background:var(--a3-panel-2);color:var(--a3-text)}
.a3d-keys .a3d-btn{height:28px;padding:0 10px;font-size:12px;margin-top:8px}
.a3d-tip{position:absolute;left:0;top:0;z-index:6;pointer-events:none;max-width:330px;padding:9px 12px 10px;font-size:13px;line-height:1.45;color:var(--a3-text-2);opacity:0;visibility:hidden;transition:opacity .1s ease}
.a3d-tip.on{opacity:1;visibility:visible}
.a3d-ledtip{max-width:360px}
.a3d-tt-h{display:flex;align-items:baseline;gap:8px;color:var(--a3-text);min-width:0}
.a3d-tt-r{font-weight:700;font-variant-numeric:tabular-nums;color:var(--a3-muted);flex:none}
.a3d-tt-r.r1{color:var(--a3-gold)}.a3d-tt-r.r2{color:var(--a3-silver)}.a3d-tt-r.r3{color:var(--a3-bronze)}
.a3d-tt-n{font:600 16px/1.25 var(--a3-label);letter-spacing:.01em;overflow-wrap:anywhere}
.a3d-tt-m{display:flex;align-items:center;flex-wrap:wrap;gap:4px 6px;margin-top:3px}
.a3d-tt-m i{width:9px;height:9px;border-radius:2px;flex:none;display:inline-block}
.a3d-tt-s{margin-top:4px;font-variant-numeric:tabular-nums}
.a3d-tt-s b{color:var(--a3-text);font-weight:650}
.a3d-tt-g{display:grid;grid-template-columns:auto auto;gap:1px 14px;margin-top:6px;font-variant-numeric:tabular-nums}
.a3d-tt-g span{color:var(--a3-muted)}
.a3d-tt-g b{color:var(--a3-text);font-weight:600;text-align:right}
.a3d-tt-k{margin-top:6px;font-size:12px;color:var(--a3-muted)}
.a3d-tt-fav{color:var(--a3-led-b);font-weight:600}
.a3d-tt-ok{color:var(--a3-led-g);font-weight:600}.a3d-tt-no{color:var(--a3-led-r);font-weight:600}
.a3d-panel{position:absolute;top:76px;right:16px;bottom:16px;width:min(420px,calc(100% - 32px));display:flex;flex-direction:column;z-index:4;transform:translateX(calc(100% + 28px));visibility:hidden;transition:transform .34s cubic-bezier(.2,.8,.2,1),visibility 0s linear .34s}
.a3d-panel.on{transform:none;visibility:visible;transition:transform .34s cubic-bezier(.2,.8,.2,1),visibility 0s}
.a3d-pbar{display:flex;align-items:center;gap:8px;padding:10px 10px 10px 12px;border-bottom:1px solid var(--a3-line);flex:none}
.a3d-pbar .a3d-sp{flex:1}
.a3d-loc i{width:10px;height:10px;border-radius:50%;flex:none;background:var(--a3-led-off);box-shadow:inset 0 0 0 1px rgba(0,0,0,.35)}
.a3d-loc[aria-pressed="true"]{border-color:var(--a3-led-b)}
.a3d-loc[aria-pressed="true"] i{background:var(--a3-led-b);box-shadow:0 0 0 1px rgba(0,0,0,.2),0 0 10px 2px var(--a3-led-b)}
.a3d-pbody{flex:1;min-height:0;overflow:auto;overscroll-behavior:contain;touch-action:pan-y;padding:14px;user-select:text;-webkit-user-select:text}
.a3d-cap{position:absolute;left:16px;top:84px;z-index:5;width:min(420px,calc(100% - 32px));padding:13px 16px 12px;font-size:14px;line-height:1.5;color:var(--a3-text-2)}
.a3d-cap[hidden]{display:none}
.a3d-cap b{display:block;font-size:15px;font-weight:650;color:var(--a3-text);margin-bottom:2px}
.a3d-cap .a3d-row{display:flex;align-items:center;gap:8px;margin-top:10px}
.a3d-cap .a3d-row span{flex:1;font-size:12px;color:var(--a3-muted);font-variant-numeric:tabular-nums}
.a3d-cap .a3d-btn{height:30px;font-size:12.5px}
.a3d-bubble{position:absolute;left:0;top:0;z-index:4;max-width:280px;padding:9px 13px 10px;font-size:14px;line-height:1.45;color:var(--a3-text);pointer-events:none;opacity:0;visibility:hidden;transition:opacity .15s ease}
.a3d-bubble.on{opacity:1;visibility:visible}
.a3d-bubble b{display:block;font-size:12.5px;font-weight:650;color:var(--a3-muted);margin-bottom:2px}
.a3d-msg{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;padding:24px;text-align:center;font-size:14px;color:var(--a3-muted);z-index:7;pointer-events:none;transition:opacity .3s ease}
.a3d-msg.off{opacity:0}
.a3d-msg.err{pointer-events:auto;background:var(--a3-bg)}
.a3d-live{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);clip-path:inset(50%);white-space:nowrap}
.a3d-sec i{width:9px;height:9px;border-radius:2px;flex:none;background:var(--sc)}
.a3d-sec.on{border-color:var(--sc);background:color-mix(in srgb,var(--sc) 18%,var(--a3-panel-2))}
.a3d-chips.a3d-scroll{overflow-x:auto;scrollbar-width:none;max-width:calc(100vw - 560px)}
.a3d-chips.a3d-scroll::-webkit-scrollbar{display:none}
.a3d-chips .a3d-btn{flex:none}
.a3d-dots{display:inline-flex;gap:3px}
.a3d-dots:empty{display:none}
.a3d-dots i{width:9px;height:9px;border-radius:50%;flex:none;background:var(--cc)}
@media (max-width:1720px){.a3d-sec small{display:none}}
.a3d-where{font-size:12.5px;color:var(--a3-muted);padding:0 4px;white-space:nowrap;font-variant-numeric:tabular-nums}
.a3d-pact{display:flex;gap:8px;padding:10px 12px;border-bottom:1px solid var(--a3-line);flex:none}
.a3d-pact[hidden],.a3d-pbar [hidden]{display:none}
.a3d-pact .a3d-btn{flex:1;min-width:0}
.a3d-pact .a3d-btn[aria-pressed="true"]{border-color:var(--cc,var(--a3-accent));background:color-mix(in srgb,var(--cc,var(--a3-accent)) 18%,var(--a3-panel-2))}
.a3d-ptitle{font-size:15px;font-weight:650;color:var(--a3-text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
.a3d-panel.wide{width:min(580px,calc(100% - 32px))}
.a3d-let{display:inline-flex;align-items:center;justify-content:center;width:22px;height:22px;border-radius:6px;flex:none;font:700 13px/1 var(--a3-sans);color:#0b0f14;background:var(--cc)}
.a3d-tray{position:absolute;left:16px;bottom:72px;z-index:3;display:flex;align-items:center;gap:8px;padding:6px 6px 6px 12px;max-width:calc(100% - 32px);flex-wrap:wrap}
.a3d-tray[hidden]{display:none}
.a3d-tray>span{font-size:12.5px;color:var(--a3-muted)}
.a3d-tray ul{display:flex;flex-wrap:wrap;gap:6px;margin:0;padding:0;list-style:none}
.a3d-tray li{display:flex;align-items:center;gap:7px;height:30px;padding:0 9px 0 4px;border-radius:7px;background:var(--a3-panel-2);border:1px solid var(--a3-line);font-size:12.5px;font-weight:600;color:var(--a3-text);white-space:nowrap}
.a3d-tray .a3d-btn{height:30px;font-size:12.5px}
.a3d-toast{position:absolute;left:50%;top:86px;transform:translateX(-50%);z-index:6;padding:9px 14px;font-size:13.5px;color:var(--a3-text);pointer-events:none;opacity:0;transition:opacity .2s;max-width:calc(100% - 32px);text-align:center}
.a3d-toast.on{opacity:1}
.a3d-mon{position:absolute;left:0;top:0;width:1000px;height:625px;transform-origin:0 0;z-index:2;display:flex;flex-direction:column;background:#05080b;color:#d6dde4;font:14px/1.5 ui-monospace,"JetBrains Mono","Red Hat Mono",Menlo,Consolas,monospace;overflow:hidden;opacity:0;transition:opacity .22s ease;pointer-events:none;text-align:left}
.a3d-mon.on{opacity:1;pointer-events:auto}
.a3d-mon[hidden]{display:none}
.a3d-mon-h{display:flex;align-items:center;gap:10px;height:46px;padding:0 10px 0 16px;border-bottom:1px solid #1d2731;background:#0a1016;font:14px/1.3 var(--a3-sans);flex:none}
.a3d-mon-h b{font-size:15px;font-weight:650;color:#f2f6f9;white-space:nowrap}
.a3d-mon-h span{color:#93a1af;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1;min-width:0}
.a3d-mon-h a,.a3d-mon-h button{display:inline-flex;align-items:center;gap:6px;height:30px;padding:0 11px;border-radius:7px;border:1px solid #2a3642;background:#111a22;color:#e6edf3;font:600 13px/1 var(--a3-sans);text-decoration:none;cursor:pointer;white-space:nowrap}
.a3d-mon-h a:hover,.a3d-mon-h button:hover{border-color:#62c4ff}
.a3d-mon-h svg{width:15px;height:15px;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
.a3d-mon-b{flex:1;min-height:0;display:flex}
.a3d-mon-f{width:220px;flex:none;overflow:auto;border-right:1px solid #1d2731;padding:8px 6px;background:#070b0f;scrollbar-width:thin}
.a3d-mon-f button{display:flex;width:100%;align-items:baseline;gap:8px;text-align:left;border:0;background:transparent;color:#b3bfca;padding:5px 8px;border-radius:6px;cursor:pointer;font:500 13px/1.35 var(--a3-sans)}
.a3d-mon-f button span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.a3d-mon-f button:hover{color:#fff}
.a3d-mon-f button[aria-selected="true"]{background:#15222e;color:#fff}
.a3d-mon-f small{margin-left:auto;color:#6f7f8e;font-size:12px;font-variant-numeric:tabular-nums;flex:none}
.a3d-mon-f .om{color:#76869a;font:12px/1.45 var(--a3-sans);padding:12px 8px 2px}
.a3d-mon-f .om b{display:block;color:#93a1af;font-weight:600;margin-bottom:2px}
.a3d-mon-c{flex:1;min-width:0;overflow:auto;display:flex;align-items:flex-start;outline:none;scrollbar-width:thin;overscroll-behavior:contain}
.a3d-mon-c:focus-visible{box-shadow:inset 0 0 0 2px #62c4ff}
.a3d-gut{margin:0;padding:10px 10px 10px 12px;text-align:right;color:#475463;user-select:none;-webkit-user-select:none;flex:none;font:inherit;position:sticky;left:0;background:#05080b;min-height:100%}
.a3d-code{margin:0;padding:10px 18px 10px 6px;font:inherit;white-space:pre;tab-size:4;-moz-tab-size:4;color:#d6dde4;user-select:text;-webkit-user-select:text;flex:none}
.a3d-code .k{color:#ff7ab6}.a3d-code .s{color:#a8e07a}.a3d-code .c{color:#6f8091;font-style:italic}.a3d-code .n{color:#f5b860}.a3d-code .t{color:#62c4ff}.a3d-code .f{color:#9db8ff}.a3d-code .m{color:#4fd1c5}.a3d-code .a{color:#ffd04a}.a3d-code .g{color:#ff9466}
.a3d-mon-k{height:32px;flex:none;display:flex;align-items:center;gap:16px;padding:0 16px;border-top:1px solid #1d2731;color:#8c99a7;font:12.5px/1 var(--a3-sans);background:#0a1016;white-space:nowrap;overflow:hidden}
.a3d-mon-k kbd{font:600 12px/1 var(--a3-sans);padding:2px 5px;border:1px solid #2a3642;border-bottom-width:2px;border-radius:4px;color:#d6dde4;margin-right:2px}
.a3d-mon.sheet{left:10px;right:10px;top:auto;bottom:10px;width:auto;height:min(64%,560px);transform:none !important;border-radius:12px;border:1px solid #1d2731;z-index:5}
.a3d-mon.sheet .a3d-mon-b{flex-direction:column}
.a3d-mon.sheet .a3d-mon-f{width:auto;display:flex;gap:4px;overflow-x:auto;overflow-y:hidden;border-right:0;border-bottom:1px solid #1d2731;padding:6px;flex:none}
.a3d-mon.sheet .a3d-mon-f button{width:auto;flex:none}
.a3d-mon.sheet .a3d-mon-f .om,.a3d-mon.sheet .a3d-mon-k{display:none}
.a3d-mon.sheet .a3d-mon-h span{display:none}
.a3d-mon.msg .a3d-mon-f,.a3d-mon.msg .a3d-mon-k{display:none}
.a3d-mon-msg{padding:34px 36px;font:15px/1.6 var(--a3-sans);color:#c6d0da}
.a3d-mon-msg b{display:block;font-size:20px;color:#fff;margin-bottom:8px}
.a3d-mon-msg a{color:#62c4ff}
.a3d-cg{display:grid;grid-template-columns:minmax(104px,1.15fr) repeat(var(--n),minmax(0,1fr));font-size:13px;line-height:1.35;font-variant-numeric:tabular-nums;margin:-2px -4px 0}
.a3d-cg>div{padding:6px 5px;border-bottom:1px solid color-mix(in srgb,var(--a3-line) 55%,transparent);min-width:0;overflow-wrap:anywhere}
.a3d-cg .hd{position:sticky;top:-14px;z-index:1;background:var(--a3-panel);padding:8px 5px 8px;border-bottom:1px solid var(--a3-line);display:flex;flex-direction:column;align-items:flex-start;gap:4px}
.a3d-cg .hd b{font:650 14px/1.25 var(--a3-label);color:var(--a3-text);overflow-wrap:anywhere}
.a3d-cg .hd small{font-size:12px;color:var(--a3-muted)}
.a3d-cg .hd button{appearance:none;border:1px solid var(--a3-line);background:var(--a3-panel-2);color:var(--a3-text-2);border-radius:6px;font:600 12px/1 var(--a3-sans);height:24px;padding:0 8px;cursor:pointer}
.a3d-cg .hd button:hover{border-color:var(--a3-accent);color:var(--a3-text)}
.a3d-cg .lb{color:var(--a3-muted)}
.a3d-cg .lb small{display:block;font-size:12px}
.a3d-cg .v{text-align:right;color:var(--a3-text-2)}
.a3d-cg .v.best{color:var(--a3-text);font-weight:700;background:color-mix(in srgb,var(--a3-led-g) 13%,transparent);border-radius:4px}
.a3d-cg .v.best::after{content:"best";display:block;font-size:12px;font-weight:600;color:var(--a3-led-g)}
.a3d-cg .v.na{color:var(--a3-muted)}
.a3d-cg .gp{grid-column:1/-1;padding:16px 5px 6px;font-size:13.5px;font-weight:650;color:var(--a3-text);border-bottom:1px solid var(--a3-line)}
.a3d-cg .gp small{font-weight:500;color:var(--a3-muted);margin-left:6px;font-size:12px}
.a3d-cmp-top{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin:0 0 12px;font-size:13px;color:var(--a3-text-2)}
.a3d-cmp-top a{color:var(--a3-accent);font-weight:600}
.a3d-cmp-note{font-size:12.5px;color:var(--a3-muted);margin:14px 0 0}
@media (min-width:761px){.a3d-panel{bottom:72px}}
@media (max-width:1180px){.a3d-seg>span{display:none}}
@media (max-width:760px){
  .a3d-top{left:10px;right:10px;top:10px;gap:6px}
  .a3d-title{padding:7px 12px 8px}
  .a3d-title b{font-size:15px}
  .a3d-title span{display:none}
  .a3d-nav{padding:4px;gap:4px}
  .a3d-panel{top:auto;left:10px;right:10px;bottom:10px;width:auto;max-height:56%;transform:translateY(calc(100% + 24px))}
  .a3d-nav .a3d-bt,.a3d-bar .a3d-bt{display:none}
  .a3d-nav .a3d-btn{padding:0 10px}
  .a3d-chip small{display:none}
  .a3d-bar{left:10px;right:10px;bottom:10px;max-width:none;padding:4px;gap:6px}
  .a3d-find{flex:1;min-width:0}
  .a3d-find input{width:100%}
  .a3d-seg button[data-pull]{display:none}
  .a3d-show-s{display:inline-block !important}
  .a3d-res{width:min(300px,calc(100vw - 40px))}
  .a3d-hide-s{display:none !important}
  .a3d-keys{display:none}
  .a3d-cap{top:auto;bottom:64px;left:10px}
  .a3d-chips.a3d-scroll{max-width:calc(100vw - 150px)}
  .a3d-tray{left:10px;right:10px;bottom:60px;max-width:none}
  .a3d-tray>span{display:none}
  .a3d-panel.wide{width:auto}
  .a3d-pact{padding:8px 10px}
  .a3d-where{display:none}
}
@media (prefers-reduced-motion:reduce){.a3d-panel,.a3d-panel.on,.a3d-tip,.a3d-btn,.a3d-msg{transition:none}}
`;

const ICON = {
  prev: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 18l-6-6 6-6"/></svg>',
  next: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 18l6-6-6-6"/></svg>',
  reset: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 12a9 9 0 1 0 2.6-6.4"/><path d="M3 4v5h5"/></svg>',
  close: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M18 6L6 18M6 6l12 12"/></svg>',
  back: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 19V5"/><path d="M5 12l7-7 7 7"/></svg>',
  find: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>',
  wall: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="4" width="18" height="12" rx="1.5"/><path d="M8 20h8M12 16v4"/></svg>',
  tour: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5v14l11-7z"/></svg>',
  keys: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="2.5" y="6" width="19" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"/></svg>',
  door: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 21h16"/><path d="M6 21V4h12v17"/><path d="M14.5 12.5h.01"/></svg>',
  cmp: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="5" width="7" height="14" rx="1.5"/><rect x="14" y="5" width="7" height="14" rx="1.5"/></svg>',
  mon: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="4" width="18" height="12" rx="1.5"/><path d="M7 20h10M12 16v4M7 9l2 1.5L7 12M11 12h3"/></svg>',
  bench: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 10h18"/><path d="M5 10v9M19 10v9"/><rect x="6" y="6" width="5" height="4" rx="1"/><rect x="13" y="6" width="5" height="4" rx="1"/></svg>',
  ext: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14 4h6v6"/><path d="M20 4l-9 9"/><path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/></svg>',
};

/* ── shaders. One time uniform drives everything that moves ─────────────── */
// the round lights: the locator, activity and error lights, the completeness pips
const LED_VS = `
uniform float uTime;
attribute vec3 aColor;
attribute float aLevel;
attribute float aHot;
attribute vec2 aBlink;
attribute float aDim;
varying vec2 vUv;
varying vec3 vColor;
varying float vLevel;
varying float vHot;
varying float vOn;
varying float vDim;
#include <fog_pars_vertex>
void main() {
  vUv = uv; vColor = aColor; vLevel = aLevel; vHot = aHot; vDim = aDim;
  vOn = aBlink.x > 0.0 ? mix(0.16, 1.0, step(fract(uTime / aBlink.x + aBlink.y), 0.55)) : 1.0;
  vec4 mvPosition = modelViewMatrix * instanceMatrix * vec4(position, 1.0);
  gl_Position = projectionMatrix * mvPosition;
  #include <fog_vertex>
}`;
const LENS_FS = `
uniform vec3 uOff;
uniform float uBoost;
varying vec2 vUv;
varying vec3 vColor;
varying float vLevel;
varying float vHot;
varying float vOn;
varying float vDim;
#include <fog_pars_fragment>
void main() {
  vec2 c = vUv * 2.0 - 1.0;
  float d = length(c);
  float aa = max(fwidth(d), 0.02);
  float a = 1.0 - smoothstep(1.0 - aa, 1.0, d);
  if (a <= 0.0) discard;
  float on = step(0.0, vLevel);
  float L = (0.18 + 0.82 * clamp(vLevel, 0.0, 1.0)) * vOn;
  vec3 lit = vColor * uBoost * (0.26 + 1.12 * L);
  vec3 col = mix(uOff, lit, on);
  float core = on * vHot * (1.0 - smoothstep(0.0, 0.66, d));
  col = mix(col, vec3(1.0, 1.0, 0.95) * uBoost * 2.2, core);
  col *= mix(0.62, 1.0, 1.0 - smoothstep(0.5, 1.0, d));
  float spec = 1.0 - smoothstep(0.0, 0.34, length(c - vec2(-0.34, 0.4)));
  col += vec3(spec * mix(0.22, 0.12, on));
  col *= mix(1.0, 0.16, vDim);
  gl_FragColor = vec4(col, a);
  #include <tonemapping_fragment>
  #include <colorspace_fragment>
  #include <fog_fragment>
}`;
const GLOW_FS = `
uniform float uGlow;
uniform float uTint;
varying vec2 vUv;
varying vec3 vColor;
varying float vLevel;
varying float vHot;
varying float vOn;
varying float vDim;
#include <fog_pars_fragment>
void main() {
  if (vLevel < 0.0) discard;
  vec2 c = vUv * 2.0 - 1.0;
  float d2 = dot(c, c);
  if (d2 > 1.0) discard;
  float L = (0.18 + 0.82 * clamp(vLevel, 0.0, 1.0)) * vOn * (1.0 - 0.8 * vDim);
  float g = (exp(-d2 * 7.0) - exp(-7.0)) * 0.85 + (exp(-d2 * 2.6) - exp(-2.6)) * 0.12;
  vec3 col = mix(vColor, vec3(1.0), vHot * 0.3) * g * uGlow * L * L * (1.0 + vHot * 0.9);
  #ifdef USE_FOG
    #ifdef FOG_EXP2
      float fogF = 1.0 - exp(-fogDensity * fogDensity * vFogDepth * vFogDepth);
    #else
      float fogF = smoothstep(fogNear, fogFar, vFogDepth);
    #endif
    col *= 1.0 - fogF;
  #endif
  if (uTint > 0.5) {
    float a = clamp((exp(-d2 * 5.0) - exp(-5.0)) * uGlow * L * (1.0 + vHot * 0.5), 0.0, 1.0);
    gl_FragColor = vec4(mix(vColor * 1.15, vec3(1.0), vHot * 0.25), a);
  } else gl_FragColor = vec4(col, 1.0);
  #include <tonemapping_fragment>
  #include <colorspace_fragment>
}`;
// the equaliser: a column of segments per test, lit to its share of the best
const EQ_VS = `
attribute vec3 aColor;
attribute float aLevel;
attribute float aHot;
attribute float aDim;
varying vec2 vUv;
varying vec3 vColor;
varying float vLevel;
varying float vHot;
varying float vDim;
#include <fog_pars_vertex>
void main() {
  vUv = uv; vColor = aColor; vLevel = aLevel; vHot = aHot; vDim = aDim;
  vec4 mvPosition = modelViewMatrix * instanceMatrix * vec4(position, 1.0);
  gl_Position = projectionMatrix * mvPosition;
  #include <fog_vertex>
}`;
const EQ_FS = `
uniform vec3 uOff;
uniform float uBoost;
varying vec2 vUv;
varying vec3 vColor;
varying float vLevel;
varying float vHot;
varying float vDim;
#include <fog_pars_fragment>
void main() {
  float y = vUv.y * ${EQ_SEGS}.0;
  float id = floor(y), fy = fract(y);
  float qx = abs(vUv.x - 0.5) * 2.0, qy = abs(fy - 0.5) * 2.0;
  float m = (1.0 - smoothstep(0.78, 0.78 + max(fwidth(qx), 0.001) * 1.5, qx)) * (1.0 - smoothstep(0.6, 0.6 + max(fwidth(qy), 0.001) * 1.5, qy));
  if (m < 0.02) discard;
  float on = step(0.0, vLevel);
  float lv = clamp(vLevel, 0.0, 1.0) * ${EQ_SEGS}.0;
  float lit = on * clamp(lv - id, 0.0, 1.0);
  lit = max(lit, on * (1.0 - step(0.5, id)) * 0.4);
  float t = (id + 1.0) / ${EQ_SEGS}.0;
  vec3 col = mix(uOff, vColor * uBoost * (0.34 + 0.56 * t), lit);
  float cap = on * vHot * step(${EQ_SEGS}.0 - 1.5, id);
  col = mix(col, vec3(1.0, 1.0, 0.94) * uBoost * 2.0, cap);
  col *= mix(1.0, 0.12, vDim);
  gl_FragColor = vec4(col, m);
  #include <tonemapping_fragment>
  #include <colorspace_fragment>
  #include <fog_fragment>
}`;
const EQG_FS = `
uniform float uGlow;
uniform float uTint;
varying vec2 vUv;
varying vec3 vColor;
varying float vLevel;
varying float vHot;
varying float vDim;
#include <fog_pars_fragment>
void main() {
  if (vLevel < 0.0) discard;
  float cx = (vUv.x - 0.5) * 1.7;
  float cy = (vUv.y - 0.07) / 0.86;
  float h = clamp(vLevel, 0.0, 1.0);
  float over = max(cy - h, 0.0) * 7.0;
  float under = max(-cy, 0.0) * 9.0;
  float g = exp(-cx * cx * 2.2) * exp(-over * over) * exp(-under * under);
  float k = uGlow * (0.35 + 0.65 * h) * (1.0 + vHot * 0.6) * (1.0 - 0.85 * vDim);
  vec3 col = mix(vColor, vec3(1.0), vHot * 0.2) * g * k;
  #ifdef USE_FOG
    #ifdef FOG_EXP2
      float fogF = 1.0 - exp(-fogDensity * fogDensity * vFogDepth * vFogDepth);
    #else
      float fogF = smoothstep(fogNear, fogFar, vFogDepth);
    #endif
    col *= 1.0 - fogF;
  #endif
  if (uTint > 0.5) gl_FragColor = vec4(vColor * 1.1, clamp(g * k * 0.8, 0.0, 1.0));
  else gl_FragColor = vec4(col, 1.0);
  #include <tonemapping_fragment>
  #include <colorspace_fragment>
}`;
// the fans: blades that turn with the CPU, blurred into a disc when they are fast
const FAN_VS = `
uniform float uTime;
attribute float aSpeed;
attribute float aPhase;
attribute float aDim;
varying vec2 vUv;
varying float vRot;
varying float vBlur;
varying float vDim;
#include <fog_pars_vertex>
void main() {
  vUv = uv; vDim = aDim;
  vRot = aPhase + uTime * aSpeed * 6.2831853;
  vBlur = clamp(aSpeed / 2.4, 0.0, 1.0);
  vec4 mvPosition = modelViewMatrix * instanceMatrix * vec4(position, 1.0);
  gl_Position = projectionMatrix * mvPosition;
  #include <fog_vertex>
}`;
const FAN_FS = `
uniform vec3 uHousing;
uniform vec3 uBlade;
uniform vec3 uCavity;
varying vec2 vUv;
varying float vRot;
varying float vBlur;
varying float vDim;
#include <fog_pars_fragment>
void main() {
  vec2 c = vUv * 2.0 - 1.0;
  float r = length(c);
  float aa = max(fwidth(r), 0.004);
  if (r > 1.0) discard;
  vec3 col;
  if (aa > 0.2) {
    col = mix(uCavity, uBlade, 0.35);          // far away: just a dark disc
  } else {
    float ang = atan(c.y, c.x);
    float b = sin(7.0 * (ang - vRot) + r * 2.4);
    float w = mix(0.1, 1.4, vBlur);
    float blade = smoothstep(-w, w, b);
    blade = mix(blade, 0.45, vBlur * 0.6) * step(0.25, r);
    col = mix(uCavity, uBlade * (0.65 + 0.35 * r), blade);
    col = mix(col, uBlade * 1.2, 1.0 - smoothstep(0.23 - aa, 0.23, r));
    float ring = smoothstep(0.85, 0.85 + aa, r);
    col = mix(col, uHousing, ring);
    float g1 = 1.0 - smoothstep(0.0, aa * 1.6, abs(r - 0.45) - 0.02);
    float g2 = 1.0 - smoothstep(0.0, aa * 1.6, abs(r - 0.68) - 0.02);
    float sp = (1.0 - smoothstep(0.0, aa * 2.0, abs(sin(2.0 * ang)) * r - 0.025)) * step(0.23, r);
    col = mix(col, uHousing * 1.45, max(max(g1, g2), sp) * (1.0 - ring) * 0.9);
  }
  col *= mix(1.0, 0.25, vDim);
  gl_FragColor = vec4(col, 1.0 - smoothstep(1.0 - aa, 1.0, r));
  #include <tonemapping_fragment>
  #include <colorspace_fragment>
  #include <fog_fragment>
}`;
// the racks' dot-matrix marquees
const MQ_VS = `
varying vec2 vUv;
#include <fog_pars_vertex>
void main() {
  vUv = uv;
  vec4 mvPosition = modelViewMatrix * vec4(position, 1.0);
  gl_Position = projectionMatrix * mvPosition;
  #include <fog_vertex>
}`;
const MQ_FS = `
uniform sampler2D tMsg;
uniform float uShift;
uniform float uMsgW;
uniform vec3 uOnC;
uniform vec3 uOffC;
uniform vec3 uBg;
varying vec2 vUv;
#include <fog_pars_fragment>
void main() {
  vec2 cell = vec2(vUv.x * ${MQ_COLS}.0, (1.0 - vUv.y) * ${MQ_ROWS}.0);
  vec2 id = floor(cell);
  vec2 f = fract(cell) - 0.5;
  float j = id.x + uShift - ${MQ_COLS}.0;
  float on = 0.0;
  if (j >= 0.0 && j < uMsgW) on = step(0.5, texture2D(tMsg, vec2((j + 0.5) / uMsgW, 1.0 - (id.y + 0.5) / ${MQ_ROWS}.0)).a);
  float d = length(f);
  float dotm = 1.0 - smoothstep(0.3, 0.42, d);
  vec3 col = uBg + mix(uOffC, uOnC, on) * dotm + uOnC * on * 0.22 * (1.0 - smoothstep(0.3, 0.75, d));
  gl_FragColor = vec4(col, 1.0);
  #include <tonemapping_fragment>
  #include <colorspace_fragment>
  #include <fog_fragment>
}`;
// the strength hologram over an open unit
const HOLO_VS = `
varying vec2 vUv;
void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`;
const HOLO_FS = `
uniform sampler2D tHolo;
uniform float uTime;
uniform float uAlpha;
varying vec2 vUv;
void main() {
  vec4 t = texture2D(tHolo, vUv);
  float scan = 0.88 + 0.12 * sin(vUv.y * 320.0 - uTime * 5.0);
  float flick = 0.95 + 0.05 * sin(uTime * 31.0) * sin(uTime * 7.3);
  float sweep = smoothstep(0.03, 0.0, abs(vUv.y - fract(uTime * 0.23))) * 0.35;
  gl_FragColor = vec4(t.rgb * scan * flick + t.rgb * sweep, t.a * uAlpha);
  #include <colorspace_fragment>
}`;
// the beam from the CPU up to the hologram
const BEAM_FS = `
uniform vec3 uColor;
uniform float uAlpha;
uniform float uTime;
varying vec2 vUv;
void main() {
  float edge = sin(vUv.x * 3.14159265);
  float up = smoothstep(0.0, 0.25, vUv.y) * (1.0 - smoothstep(0.7, 1.0, vUv.y));
  float rays = 0.75 + 0.25 * sin(vUv.x * 60.0 + uTime * 2.0);
  gl_FragColor = vec4(uColor * uAlpha * edge * up * rays * 0.5, 1.0);
  #include <colorspace_fragment>
}`;
// light pulses running along the cable trays, at each rack's throughput
const PULSE_FS = `
uniform float uTime;
uniform float uRate;
uniform vec3 uColor;
varying vec2 vUv;
#include <fog_pars_fragment>
void main() {
  float x = vUv.x * 6.0 - uTime * uRate;
  float p = pow(max(0.0, 1.0 - fract(x) * 3.0), 3.0);
  float core = 1.0 - smoothstep(0.15, 0.5, abs(vUv.y - 0.5));
  vec3 col = uColor * (0.12 + 1.4 * p) * core;
  #ifdef USE_FOG
    #ifdef FOG_EXP2
      float fogF = 1.0 - exp(-fogDensity * fogDensity * vFogDepth * vFogDepth);
    #else
      float fogF = smoothstep(fogNear, fogFar, vFogDepth);
    #endif
    col *= 1.0 - fogF;
  #endif
  gl_FragColor = vec4(col, 1.0);
  #include <tonemapping_fragment>
  #include <colorspace_fragment>
}`;
/* ── helpers ───────────────────────────────────────────────────────────── */
const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
const clamp01 = v => clamp(+v || 0, 0, 1);
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const easeInOut = k => (k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2);
const easeOut = k => 1 - Math.pow(1 - k, 3);
const easeBack = k => { const c1 = 1.25, c3 = c1 + 1; return 1 + c3 * Math.pow(k - 1, 3) + c1 * Math.pow(k - 1, 2); };
function hash(s) { let h = 2166136261; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; }
function rng(seed) {
  let a = seed >>> 0;
  return () => { a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}
function canvas(w, h) { const c = document.createElement('canvas'); c.width = Math.max(1, Math.round(w)); c.height = Math.max(1, Math.round(h)); return c; }
function rrect(ctx, x, y, w, h, r) {
  r = Math.min(r, w / 2, h / 2);
  ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath();
}
function circle(ctx, x, y, r) { ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); }
function spacing(ctx, v) { if ('letterSpacing' in ctx) ctx.letterSpacing = v; }
// the largest size from max down to min that fits, then an ellipsis if even min is too wide
function fit(ctx, text, weight, family, max, min, width) {
  let px = max;
  ctx.font = weight + ' ' + px + 'px ' + family;
  let w = ctx.measureText(text).width;
  if (w > width) { px = Math.max(min, Math.floor((px * width / w) * 4) / 4); ctx.font = weight + ' ' + px + 'px ' + family; w = ctx.measureText(text).width; }
  let t = text;
  if (w > width) { while (t.length > 1 && ctx.measureText(t + '…').width > width) t = t.slice(0, -1); t = t.replace(/[\s\-·.]+$/, '') + '…'; }
  return { text: t, px };
}
function centreY(ctx, text, cy) { const m = ctx.measureText(text); return cy + (m.actualBoundingBoxAscent - m.actualBoundingBoxDescent) / 2; }
function hazard(ctx, x, y, w, h) {
  ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip();
  ctx.fillStyle = '#20242a'; ctx.fillRect(x, y, w, h);
  ctx.fillStyle = '#f2bd00';
  for (let k = -h; k < w + h; k += 12) { ctx.beginPath(); ctx.moveTo(x + k, y); ctx.lineTo(x + k + 6, y); ctx.lineTo(x + k + 6 + h, y + h); ctx.lineTo(x + k + h, y + h); ctx.closePath(); ctx.fill(); }
  ctx.restore();
}
function screwHead(ctx, x, y, r, P) {
  const g = ctx.createRadialGradient(x - r * 0.35, y - r * 0.4, r * 0.1, x, y, r);
  g.addColorStop(0, P.screw[0]); g.addColorStop(0.55, P.screw[1]); g.addColorStop(1, P.screw[2]);
  ctx.fillStyle = 'rgba(0,0,0,.35)'; circle(ctx, x, y + 0.8, r + 0.8); ctx.fill();
  ctx.fillStyle = g; circle(ctx, x, y, r); ctx.fill();
  ctx.strokeStyle = 'rgba(0,0,0,.55)'; ctx.lineWidth = 1.4;
  ctx.beginPath(); ctx.moveTo(x - r * 0.55, y); ctx.lineTo(x + r * 0.55, y); ctx.moveTo(x, y - r * 0.55); ctx.lineTo(x, y + r * 0.55); ctx.stroke();
}

// Where everything sits on a panel, in texture px (1024 x 92).

function drawLcd(cv, u, P) {
  const ctx = cv.getContext('2d');
  const W = cv.width, H = cv.height;
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.fillStyle = P.lcdBg; ctx.fillRect(0, 0, W, H);
  let g = ctx.createLinearGradient(0, 0, 0, H * 0.4);
  g.addColorStop(0, 'rgba(0,0,0,.5)'); g.addColorStop(1, 'rgba(0,0,0,0)');
  ctx.fillStyle = g; ctx.fillRect(0, 0, W, H * 0.4);
  const txt = String(u.score || '');
  const ghost = txt.replace(/[0-9A-Za-z]/g, '8');
  const pad = W * 0.06;
  const f = fit(ctx, ghost || '8', '700', FONT_SEG, Math.round(H * 0.56), Math.round(H * 0.3), W - pad * 2);
  ctx.font = '700 ' + f.px + 'px ' + FONT_SEG; ctx.textAlign = 'right';
  const y = centreY(ctx, '8', H * 0.47);
  ctx.fillStyle = P.lcdFg;
  ctx.globalAlpha = P.lcdGhost; ctx.fillText(ghost, W - pad, y);
  ctx.globalAlpha = 1;
  if (P.lcdGlow) { ctx.shadowColor = P.lcdGlow; ctx.shadowBlur = H * 0.14; }
  ctx.fillText(txt, W - pad, y);
  ctx.shadowBlur = 0; ctx.shadowColor = 'transparent';
  // the bar along the bottom: the share of the leader
  ctx.globalAlpha = 0.75; ctx.fillRect(0, H - Math.max(2, H * 0.05), W * clamp01(u.share), Math.max(2, H * 0.05)); ctx.globalAlpha = 1;
}


function tileTexture(P, perf) {
  const S = 512, cv = canvas(S, S), ctx = cv.getContext('2d');
  ctx.fillStyle = P.floor; ctx.fillRect(0, 0, S, S);
  const r = rng(perf ? 7 : 3);
  for (let i = 0; i < 2600; i++) {
    ctx.globalAlpha = 0.25 + r() * 0.45; ctx.fillStyle = P.speck[r() < 0.5 ? 0 : 1];
    const sz = 1 + r() * 1.6; ctx.fillRect(r() * S, r() * S, sz, sz);
  }
  ctx.globalAlpha = 1;
  if (perf) {
    const n = 22, m = 40, st = (S - 2 * m) / (n - 1);
    for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) {
      const x = m + i * st, y = m + j * st;
      ctx.fillStyle = P.perfRing; circle(ctx, x, y + 0.8, 5.2); ctx.fill();
      ctx.fillStyle = P.perfHole; circle(ctx, x, y, 4.6); ctx.fill();
    }
  }
  // the seams are cut by the floor's shader, sharp at any distance
  return cv;
}

function postTexture(P, n, inner) {
  // a post's front, 45 mm wide: under the ears the square holes, outside them the U numbers
  const pxU = 48, W = 64, H = n * pxU, cv = canvas(W, H), ctx = cv.getContext('2d');
  ctx.fillStyle = P.postFace; ctx.fillRect(0, 0, W, H);
  const ix = x => (inner === 'right' ? W - x : x);   // x measured from the opening's edge
  for (let k = 0; k < n; k++) {
    const yTop = H - (k + 1) * pxU;                  // U numbers count up from the bottom
    for (const off of [6.9, 24, 41.1]) {
      const y = yTop + pxU - off;
      ctx.fillStyle = P.postHole; const hx = ix(11.5); ctx.fillRect(hx - 5.5, y - 5.5, 11, 11);
    }
    ctx.fillStyle = P.postTick; ctx.fillRect(ix(23) - (inner === 'right' ? 41 : 0), yTop, 41, 1);
    ctx.font = '600 13px ' + FONT_SANS; ctx.textAlign = 'center'; ctx.fillStyle = P.postSilk;
    const t = String(k + 1);
    ctx.fillText(t, ix(44), centreY(ctx, t, yTop + pxU / 2));
  }
  return cv;
}

function doorTexture(P, seed, dark, glass) {
  // A closed cabinet's door, in two layers: the equipment behind it with its lights (drawn at
  // half size, seen through the door with a little parallax), and the door itself, perforated
  // steel or smoked glass in a solid frame, its openings transparent.
  const W = 512, H = 1700, r = rng(seed);
  const inner = canvas(W / 2, H / 2), ctx = inner.getContext('2d');
  ctx.setTransform(0.5, 0, 0, 0.5, 0, 0);
  const glows = [], dots = [];
  const pxU = 37.6, x0 = 45, x1 = W - 45;
  ctx.fillStyle = P.doorBack; ctx.fillRect(0, 0, W, H);
  const kinds = ['srv1', 'srv1', 'srv1', 'srv2', 'srv2', 'switch', 'patch', 'stor', 'blank'];
  const led = (x, y, c, lv, glow) => { dots.push({ x, y, c, lv }); if (glow) glows.push({ x, y, color: c, level: lv }); };
  const pick = () => { const c = r(); return c < 0.7 ? P.ledG : c < 0.88 ? P.ledB : P.ledA; };
  let y = 76;
  while (y < H - 90) {
    const k = kinds[Math.floor(r() * kinds.length)];
    const u = k === 'srv2' ? 2 : k === 'stor' ? 3 : 1, h = u * pxU;
    if (y + h > H - 84) break;
    ctx.fillStyle = P.doorKit[Math.floor(r() * 3)]; ctx.fillRect(x0, y + 1, x1 - x0, h - 2);
    ctx.fillStyle = 'rgba(255,255,255,.08)'; ctx.fillRect(x0, y + 1, x1 - x0, 1.5);
    ctx.fillStyle = 'rgba(0,0,0,.35)'; ctx.fillRect(x0, y + h - 2.5, x1 - x0, 1.5);
    const cy = y + h / 2;
    if (k === 'srv1' || k === 'srv2') {
      const nb = k === 'srv1' ? 8 : 12, rows = k === 'srv1' ? 1 : 2, bw = 26, bx = x0 + 96;
      ctx.fillStyle = 'rgba(0,0,0,.4)';
      for (let q = 0; q < rows; q++) for (let i = 0; i < nb / rows; i++) {
        ctx.fillRect(bx + i * (bw + 4), y + 6 + q * (h - 8) / rows, bw, (h - 8) / rows - 4);
        if (r() < 0.8) led(bx + i * (bw + 4) + bw - 5, y + 10 + q * (h - 8) / rows, P.ledG, 0.5 + r() * 0.5, false);
      }
      led(x0 + 16, cy, P.ledG, 0.9, true);
      if (r() < 0.75) led(x0 + 30, cy, pick(), 0.5 + r() * 0.5, true);
    } else if (k === 'switch') {
      for (let i = 0; i < 24; i++) {
        const px = x0 + 70 + i * 13 + Math.floor(i / 6) * 6;
        ctx.fillStyle = 'rgba(0,0,0,.6)'; ctx.fillRect(px, cy - 9, 10, 8); ctx.fillRect(px, cy + 2, 10, 8);
        if (r() < 0.7) led(px + 5, cy - 12, r() < 0.85 ? P.ledG : P.ledA, 0.4 + r() * 0.6, false);
      }
      led(x0 + 18, cy, P.ledG, 0.9, true);
    } else if (k === 'patch') {
      for (let i = 0; i < 24; i++) { const px = x0 + 60 + i * 13.5 + Math.floor(i / 6) * 8; ctx.fillStyle = 'rgba(0,0,0,.6)'; ctx.fillRect(px, cy - 5, 10, 9); }
    } else if (k === 'stor') {
      for (let q = 0; q < 3; q++) for (let i = 0; i < 4; i++) {
        const bx = x0 + 34 + i * 92, by = y + 4 + q * (h - 6) / 3;
        ctx.fillStyle = 'rgba(0,0,0,.42)'; ctx.fillRect(bx, by, 86, (h - 6) / 3 - 4);
        led(bx + 78, by + 6, r() < 0.9 ? P.ledG : P.ledA, 0.5 + r() * 0.5, false);
      }
      led(x0 + 14, y + 10, P.ledB, 0.9, true);
    } else {
      ctx.fillStyle = 'rgba(0,0,0,.35)';
      for (let i = 0; i < 40; i++) { circle(ctx, x0 + 20 + i * 10, cy, 2); ctx.fill(); }
    }
    y += h;
  }
  for (const d of dots) { ctx.globalAlpha = 0.45 + 0.55 * d.lv; ctx.fillStyle = d.c; circle(ctx, d.x, d.y, 3); ctx.fill(); }
  ctx.globalAlpha = 1;
  // the door: its openings cut out of the sheet, then the frame, the handle and a small label
  const sheet = canvas(W, H), sc = sheet.getContext('2d');
  sc.fillStyle = P.door; sc.fillRect(0, 0, W, H);
  sc.globalCompositeOperation = 'destination-out';
  if (glass) { sc.fillStyle = '#000'; sc.fillRect(32, 32, W - 64, H - 64); }
  else {
    const pitch = 7.2, hr = 2.7;
    for (let j = 0, yy = 60; yy < H - 60; j++, yy += pitch * 0.866) {
      for (let xx = 34 + (j % 2) * pitch / 2; xx < W - 34; xx += pitch) { circle(sc, xx, yy, hr); sc.fill(); }
    }
  }
  sc.globalCompositeOperation = 'source-over';
  sc.strokeStyle = P.doorFrame; sc.lineWidth = 56; sc.strokeRect(0, 0, W, H);
  sc.strokeStyle = dark ? 'rgba(255,255,255,.07)' : 'rgba(255,255,255,.16)'; sc.lineWidth = 2; sc.strokeRect(29, 29, W - 58, H - 58);
  sc.fillStyle = dark ? '#2a3036' : '#59626b'; rrect(sc, W - 22, H * 0.44, 12, 190, 5); sc.fill();
  sc.fillStyle = dark ? '#0a0c0e' : '#1d2126'; circle(sc, W - 16, H * 0.44 + 210, 6); sc.fill();
  sc.fillStyle = dark ? '#1c2025' : '#e9edf0'; rrect(sc, W / 2 - 70, 8, 140, 18, 3); sc.fill();
  return { inner, sheet, leds: glows.map(l => ({ x: (l.x / W - 0.5), y: (0.5 - l.y / H), color: l.color, level: l.level })) };
}

function rearTexture(P) {
  // the rear door, seen through an empty bay: perforated, a little light from the hot aisle behind it
  const W = 256, H = 1024, cv = canvas(W, H), ctx = cv.getContext('2d');
  ctx.fillStyle = P.rear; ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = P.rearHole;
  for (let j = 0, y = 20; y < H - 20; j++, y += 6.2) for (let x = 16 + (j % 2) * 3.6; x < W - 16; x += 7.2) { circle(ctx, x, y, 1.7); ctx.fill(); }
  return cv;
}

function rearPduTexture(P, dark) {
  // a vertical PDU: a column of outlets under a little display
  const W = 32, H = 1024, cv = canvas(W, H), ctx = cv.getContext('2d');
  ctx.fillStyle = dark ? '#16191d' : '#2c333a'; ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = dark ? '#06171f' : '#0c2430'; ctx.fillRect(6, 30, 20, 34);
  ctx.fillStyle = P.lcdLit ? P.lcdFg : '#7dfbd8'; ctx.globalAlpha = 0.8; ctx.fillRect(9, 38, 14, 3); ctx.fillRect(9, 46, 10, 3); ctx.globalAlpha = 1;
  for (let y = 96; y < H - 30; y += 38) {
    ctx.fillStyle = '#050607'; rrect(ctx, 7, y, 18, 26, 3); ctx.fill();
    ctx.fillStyle = dark ? '#2c3238' : '#525b64'; ctx.fillRect(11, y + 8, 3, 7); ctx.fillRect(18, y + 8, 3, 7);
  }
  return cv;
}

/* the outside, painted: a sky down to a far horizon, and a nearer layer that slides against it
   as you move. Both wrap twice round, so their patterns repeat with whole cycles. */
function skyTexture(P, W, H) {
  const cv = canvas(W, H), x = cv.getContext('2d'), r = rng(21), hz = Math.round(H * 0.73), k = W / 2048;
  const g = x.createLinearGradient(0, 0, 0, H), h = hz / H;
  for (const [t, c] of P.night ? [[0, '#02050b'], [0.45, '#08101d'], [h, '#1c2534'], [h + 0.02, '#0a0e15'], [1, '#06080c']] : [[0, '#4f8fd0'], [0.5, '#9cc2e6'], [h, '#e2ebf3'], [h + 0.02, '#b7c2b6'], [1, '#a3ae9f']]) g.addColorStop(t, c);
  x.fillStyle = g; x.fillRect(0, 0, W, H);
  const ridge = (col, amp, base, ns) => {
    x.fillStyle = col; x.beginPath(); x.moveTo(0, hz + 2);
    for (let i = 0; i <= W; i += 4) { const t = i / W * Math.PI * 2; x.lineTo(i, hz - k * (base + amp * (0.55 + ns.reduce((s, [n, a, ph]) => s + a * Math.sin(t * n + ph), 0)))); }
    x.lineTo(W, hz + 2); x.closePath(); x.fill();
  };
  if (P.night) {
    for (let i = 0; i < 700 * k; i++) { const s = (0.7 + r() * 1.1) * Math.max(1, k * 1.4); x.globalAlpha = 0.25 + r() * 0.75; x.fillStyle = r() < 0.2 ? '#ffe9c4' : r() < 0.4 ? '#cfe0ff' : '#ffffff'; x.fillRect(r() * W, Math.pow(r(), 1.6) * hz * 0.85, s, s); }
    x.globalAlpha = 1;
    const mx = W * 0.31, my = hz * 0.3, mg = x.createRadialGradient(mx, my, 0, mx, my, 120 * k);
    mg.addColorStop(0, 'rgba(215,228,255,.6)'); mg.addColorStop(0.14, 'rgba(170,195,240,.2)'); mg.addColorStop(1, 'rgba(120,150,210,0)');
    x.fillStyle = mg; x.fillRect(mx - 120 * k, my - 120 * k, 240 * k, 240 * k);
    x.fillStyle = '#f4f6ff'; circle(x, mx, my, 9 * k); x.fill();
    const cg = x.createLinearGradient(0, hz - 90 * k, 0, hz);
    cg.addColorStop(0, 'rgba(255,170,100,0)'); cg.addColorStop(1, 'rgba(255,170,100,.18)');
    x.fillStyle = cg; x.fillRect(0, hz - 90 * k, W, 90 * k);
    // a distant city, its windows lit
    for (let bx = 0; bx < W;) {
      const bw = (10 + r() * 34) * k, bh = (6 + Math.pow(r(), 2.2) * 72) * k;
      x.fillStyle = '#0d131d'; x.fillRect(bx, hz - bh, bw, bh + 2);
      for (let wy = hz - bh + 3 * k; wy < hz - 2 * k; wy += 3 * k) for (let wx = bx + 2 * k; wx < bx + bw - 2 * k; wx += 3 * k) if (r() < 0.22) { x.globalAlpha = 0.5 + r() * 0.5; x.fillStyle = r() < 0.6 ? '#ffd9a0' : '#fff3d6'; x.fillRect(wx, wy, 1.5 * k, 1.5 * k); }
      x.globalAlpha = 1;
      if (bh > 52 * k && r() < 0.7) { x.fillStyle = '#ff3b30'; x.fillRect(bx + bw / 2 - k, hz - bh - 2 * k, 2.4 * k, 2.4 * k); }
      bx += bw + r() * 6 * k;
    }
  } else {
    x.filter = 'blur(' + Math.max(2, Math.round(6 * k)) + 'px)';
    for (let i = 0; i < 26; i++) {
      const cx = r() * W, cy = (0.1 + r() * 0.42) * hz, w = (60 + r() * 170) * k;
      x.fillStyle = 'rgba(255,255,255,' + (0.35 + r() * 0.4).toFixed(2) + ')';
      for (let j = 0; j < 5; j++) { x.beginPath(); x.ellipse(cx + (r() - 0.5) * w, cy + (r() - 0.5) * w * 0.14, w * (0.24 + r() * 0.26), w * (0.09 + r() * 0.08), 0, 0, Math.PI * 2); x.fill(); }
    }
    x.filter = 'none';
    ridge('#a8bccb', 44, 10, [[3, 0.3, 0.4], [7, 0.15, 2.1], [11, 0.08, 1]]);
    ridge('#92a89d', 26, 2, [[5, 0.3, 1.3], [13, 0.12, 0.2], [2, 0.2, 2.6]]);
  }
  return cv;
}
function nearTexture(P, W, H) {
  const cv = canvas(W, H), x = cv.getContext('2d'), r = rng(33), hz = Math.round(H * 0.9), k = W / 2048;
  x.fillStyle = P.night ? '#080b11' : '#9caa98'; x.fillRect(0, hz, W, H - hz);
  for (let bx = 0; bx < W;) {
    const bw = (34 + r() * 100) * k, kind = r();
    if (P.night) {
      const bh = (20 + r() * 110) * k;
      if (kind < 0.75) {
        x.fillStyle = '#0a0f17'; x.fillRect(bx, hz - bh, bw, bh + 1);
        for (let wy = hz - bh + 6 * k; wy < hz - 4 * k; wy += 7 * k) for (let wx = bx + 4 * k; wx < bx + bw - 4 * k; wx += 7 * k) if (r() < 0.16) { x.globalAlpha = 0.6 + r() * 0.4; x.fillStyle = r() < 0.7 ? '#ffd28a' : '#cfe6ff'; x.fillRect(wx, wy, 3 * k, 3 * k); }
        x.globalAlpha = 1;
      }
    } else if (kind < 0.45) {   // a low building, its chillers on the roof
      const bh = (14 + r() * 40) * k;
      x.fillStyle = '#c6ccd0'; x.fillRect(bx, hz - bh, bw, bh); x.fillStyle = '#a9b1b7'; x.fillRect(bx, hz - bh, bw, 3 * k);
      x.fillStyle = '#8b959c'; for (let c = bx + 6 * k; c < bx + bw - 14 * k; c += 18 * k) x.fillRect(c, hz - bh - 8 * k, 14 * k, 8 * k);
    } else if (kind < 0.7) {   // generator sets in their containers
      for (let gi = 0; gi < 3; gi++) { x.fillStyle = gi % 2 ? '#5d6b63' : '#6a786f'; x.fillRect(bx + gi * 26 * k, hz - 12 * k, 24 * k, 12 * k); }
    } else for (let t = 0; t < 5; t++) { const th = (6 + r() * 5) * k; x.fillStyle = r() < 0.5 ? '#587256' : '#64805f'; x.beginPath(); x.ellipse(bx + t * 9 * k, hz - th, th * 0.55, th, 0, 0, Math.PI * 2); x.fill(); }
    bx += bw + (14 + r() * 70) * k;
  }
  if (P.night) for (let i = 0; i < 46; i++) {   // the street lights
    const sx = r() * W, sg = x.createRadialGradient(sx, hz - 5 * k, 0, sx, hz - 5 * k, 3.5 * k);
    sg.addColorStop(0, 'rgba(255,196,120,.85)'); sg.addColorStop(1, 'rgba(255,196,120,0)');
    x.fillStyle = sg; x.fillRect(sx - 4 * k, hz - 9 * k, 8 * k, 8 * k);
  }
  return cv;
}
// an emergency exit: a figure running out of a door, white on green
function exitTexture() {
  const cv = canvas(128, 64), x = cv.getContext('2d');
  x.fillStyle = '#0a8f45'; x.fillRect(0, 0, 128, 64);
  x.strokeStyle = '#fff'; x.fillStyle = '#fff'; x.lineWidth = 5; x.lineCap = 'round'; x.lineJoin = 'round';
  x.strokeRect(84, 10, 30, 44);
  circle(x, 50, 15, 6); x.fill();
  x.beginPath(); x.moveTo(46, 24); x.lineTo(40, 40); x.lineTo(30, 52); x.moveTo(40, 40); x.lineTo(54, 46); x.lineTo(58, 56); x.moveTo(45, 27); x.lineTo(34, 31); x.moveTo(45, 27); x.lineTo(58, 34); x.stroke();
  x.beginPath(); x.moveTo(10, 32); x.lineTo(24, 32); x.moveTo(17, 25); x.lineTo(10, 32); x.lineTo(17, 39); x.stroke();
  return cv;
}
function hazardTexture() {
  const cv = canvas(64, 16), x = cv.getContext('2d');
  x.fillStyle = '#f2c200'; x.fillRect(0, 0, 64, 16); x.fillStyle = '#1a1a1a';
  for (let i = -16; i < 64; i += 16) { x.beginPath(); x.moveTo(i, 16); x.lineTo(i + 8, 16); x.lineTo(i + 24, 0); x.lineTo(i + 16, 0); x.closePath(); x.fill(); }
  return cv;
}
// a cooling unit's front: louvres, a panel, a small display
function crahTexture(P) {
  const cv = canvas(256, 256), x = cv.getContext('2d');
  x.fillStyle = P.crah[1]; x.fillRect(0, 0, 256, 256);
  x.fillStyle = P.crah[2];
  for (let y = 18; y < 150; y += 9) x.fillRect(14, y, 228, 4);
  x.fillRect(14, 170, 110, 72); x.fillRect(132, 170, 110, 72);
  x.fillStyle = P.night ? '#0d2e4a' : '#163c5c'; x.fillRect(150, 182, 74, 26);
  x.fillStyle = '#7dd3ff'; x.fillRect(156, 188, 40, 4); x.fillRect(156, 197, 26, 4);
  x.fillStyle = '#3dff8f'; x.fillRect(212, 189, 6, 6);
  return cv;
}

function labelTexture(P, k, from, to) {
  const W = 512, H = 96, cv = canvas(W, H), ctx = cv.getContext('2d');
  ctx.fillStyle = P.plate; rrect(ctx, 0, 0, W, H, 8); ctx.fill();
  ctx.strokeStyle = P.plateLine; ctx.lineWidth = 3; rrect(ctx, 1.5, 1.5, W - 3, H - 3, 7); ctx.stroke();
  ctx.textAlign = 'left'; ctx.fillStyle = P.plateText;
  ctx.font = '700 54px ' + FONT_LABEL;
  const rt = 'R' + (k + 1);
  ctx.fillText(rt, 28, centreY(ctx, rt, H / 2));
  const w = ctx.measureText(rt).width;
  ctx.font = '600 36px ' + FONT_SANS; ctx.fillStyle = P.plateMuted;
  const range = from > to ? 'empty' : '#' + from + (to > from ? '–' + to : '');
  ctx.fillText('·  ' + range, 28 + w + 16, centreY(ctx, '0', H / 2));
  ctx.fillStyle = P.ledG; circle(ctx, W - 34, H / 2, 7); ctx.fill();
  return cv;
}

function signTexture(P, title, sub) {
  const W = 1280, H = 200, cv = canvas(W, H), ctx = cv.getContext('2d');
  ctx.fillStyle = P.sign; ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = P.signLine; ctx.fillRect(0, H - 8, W, 8);
  ctx.textAlign = 'center';
  let f = fit(ctx, title || 'The aisle', '650', FONT_SANS, 66, 36, W - 80);
  ctx.font = '650 ' + f.px + 'px ' + FONT_SANS; ctx.fillStyle = P.signText; ctx.fillText(f.text, W / 2, sub ? 92 : 118);
  if (sub) { f = fit(ctx, sub, '500', FONT_SANS, 38, 24, W - 80); ctx.font = '500 ' + f.px + 'px ' + FONT_SANS; ctx.fillStyle = P.signMuted; ctx.fillText(f.text, W / 2, 152); }
  return cv;
}

function favTexture() {
  // the locator's glow over a whole panel: brighter towards the edges, like edge-lit acrylic
  const W = 256, H = 32, cv = canvas(W, H), ctx = cv.getContext('2d');
  ctx.fillStyle = '#000'; ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = 'rgb(110,110,110)'; ctx.fillRect(2, 2, W - 4, H - 4);
  ctx.filter = 'blur(2px)';
  ctx.strokeStyle = '#fff'; ctx.lineWidth = 3; ctx.strokeRect(3, 3, W - 6, H - 6);
  ctx.filter = 'none';
  return cv;
}

function shadowTexture() {
  const cv = canvas(4, 64), ctx = cv.getContext('2d');
  const g = ctx.createLinearGradient(0, 0, 0, 64);
  g.addColorStop(0, 'rgba(255,255,255,1)'); g.addColorStop(0.35, 'rgba(255,255,255,.45)'); g.addColorStop(1, 'rgba(255,255,255,0)');
  ctx.fillStyle = g; ctx.fillRect(0, 0, 4, 64);
  return cv;
}

/* ── geometry: static boxes merged into one mesh per material ──────────── */
function mergeParts(list) {
  let nv = 0, ni = 0;
  for (const p of list) { nv += p.g.attributes.position.count; ni += p.g.index.count; }
  const pos = new Float32Array(nv * 3), nor = new Float32Array(nv * 3), uv = new Float32Array(nv * 2);
  const idx = nv > 65535 ? new Uint32Array(ni) : new Uint16Array(ni);
  const v = new THREE.Vector3(), nm = new THREE.Matrix3();
  let vo = 0, io = 0;
  for (const p of list) {
    const P = p.g.attributes.position, N = p.g.attributes.normal, T = p.g.attributes.uv, I = p.g.index;
    nm.getNormalMatrix(p.m);
    for (let i = 0; i < P.count; i++) {
      v.fromBufferAttribute(P, i).applyMatrix4(p.m); pos[(vo + i) * 3] = v.x; pos[(vo + i) * 3 + 1] = v.y; pos[(vo + i) * 3 + 2] = v.z;
      v.fromBufferAttribute(N, i).applyMatrix3(nm).normalize(); nor[(vo + i) * 3] = v.x; nor[(vo + i) * 3 + 1] = v.y; nor[(vo + i) * 3 + 2] = v.z;
      uv[(vo + i) * 2] = T.getX(i); uv[(vo + i) * 2 + 1] = T.getY(i);
    }
    for (let i = 0; i < I.count; i++) idx[io + i] = I.getX(i) + vo;
    vo += P.count; io += I.count;
    p.g.dispose();
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  g.setAttribute('normal', new THREE.BufferAttribute(nor, 3));
  g.setAttribute('uv', new THREE.BufferAttribute(uv, 2));
  g.setIndex(new THREE.BufferAttribute(idx, 1));
  g.computeBoundingSphere();
  return g;
}

/* ── the picture: the room drawn into a multisampled HDR target, then ambient
   occlusion from its depth (half size), a bloom pyramid for whatever is
   brighter than white, and one last pass to the screen that applies them,
   tone maps once and dithers. A display (a screen, a lit sign) marks itself
   with alpha 0: it is already in screen values, so it is neither darkened
   nor tone mapped. ─────────────────────────────────────────────────────── */
const POST_VS = `
varying vec2 vUv;
void main() { vUv = position.xy * 0.5 + 0.5; gl_Position = vec4(position.xy, 0.0, 1.0); }`;
// bloom: the bright part, at half size; four taps weighted so a lone bright pixel does not flicker
const BLOOM_PRE_FS = `
uniform sampler2D tSrc;
uniform vec2 uTexel;
uniform vec4 uCurve;   // threshold - knee, 2 knee, 0.25 / knee, threshold
varying vec2 vUv;
vec3 tap(vec2 o) { return texture2D(tSrc, vUv + o * uTexel).rgb; }
float kw(vec3 c) { return 1.0 / (1.0 + max(c.r, max(c.g, c.b))); }
void main() {
  vec3 a = tap(vec2(-1.0, -1.0)), b = tap(vec2(1.0, -1.0)), c = tap(vec2(-1.0, 1.0)), d = tap(vec2(1.0, 1.0));
  float wa = kw(a), wb = kw(b), wc = kw(c), wd = kw(d);
  vec3 col = (a * wa + b * wb + c * wc + d * wd) / (wa + wb + wc + wd);
  float br = max(col.r, max(col.g, col.b));
  float rq = clamp(br - uCurve.x, 0.0, uCurve.y);
  rq = uCurve.z * rq * rq;
  col *= max(rq, br - uCurve.w) / max(br, 1e-4);
  gl_FragColor = vec4(col, 1.0);
}`;
const BLOOM_DOWN_FS = `
uniform sampler2D tSrc;
uniform vec2 uTexel;
varying vec2 vUv;
void main() {
  vec3 s = texture2D(tSrc, vUv).rgb * 4.0;
  s += texture2D(tSrc, vUv - uTexel).rgb + texture2D(tSrc, vUv + uTexel).rgb;
  s += texture2D(tSrc, vUv + vec2(uTexel.x, -uTexel.y)).rgb + texture2D(tSrc, vUv - vec2(uTexel.x, -uTexel.y)).rgb;
  gl_FragColor = vec4(s * 0.125, 1.0);
}`;
// added onto the level above: each level carries the wider glow of all those under it
const BLOOM_UP_FS = `
uniform sampler2D tSrc;
uniform vec2 uTexel;
uniform float uK;
varying vec2 vUv;
void main() {
  vec2 h = uTexel * 0.5;
  vec3 s = texture2D(tSrc, vUv + vec2(-2.0 * h.x, 0.0)).rgb + texture2D(tSrc, vUv + vec2(2.0 * h.x, 0.0)).rgb;
  s += texture2D(tSrc, vUv + vec2(0.0, 2.0 * h.y)).rgb + texture2D(tSrc, vUv + vec2(0.0, -2.0 * h.y)).rgb;
  s += 2.0 * (texture2D(tSrc, vUv + h).rgb + texture2D(tSrc, vUv - h).rgb + texture2D(tSrc, vUv + vec2(h.x, -h.y)).rgb + texture2D(tSrc, vUv + vec2(-h.x, h.y)).rgb);
  gl_FragColor = vec4(s * (uK / 12.0), 1.0);
}`;
// the depth at half size, the nearest of each 2 x 2: a slit a pixel wide (the gap between two
// units, as the multisampled depth catches it here and there) is not a crevice to darken
const DEPTH_DOWN_FS = `
uniform highp sampler2D tDepth;
void main() {
  ivec2 p = ivec2(gl_FragCoord.xy) * 2, mx = textureSize(tDepth, 0) - 1;
  float a = texelFetch(tDepth, min(p, mx), 0).x, b = texelFetch(tDepth, min(p + ivec2(1, 0), mx), 0).x;
  float c = texelFetch(tDepth, min(p + ivec2(0, 1), mx), 0).x, d = texelFetch(tDepth, min(p + ivec2(1, 1), mx), 0).x;
  gl_FragColor = vec4(min(min(a, b), min(c, d)), 0.0, 0.0, 1.0);
}`;
// the occlusion, smoothed over its 5 x 5 noise, only across surfaces at about the same depth
const AO_BLUR_FS = `
#include <packing>
uniform sampler2D tAO;
uniform highp sampler2D tDepth;
uniform vec2 uTexel;
uniform float cameraNear;
uniform float cameraFar;
varying vec2 vUv;
float vz(vec2 uv) { return perspectiveDepthToViewZ(texture2D(tDepth, uv).x, cameraNear, cameraFar); }
void main() {
  float z0 = vz(vUv), tol = 0.03 * abs(z0) + 0.015;
  float s = 0.0, w = 0.0;
  for (int j = -2; j <= 2; j++) for (int i = -2; i <= 2; i++) {
    vec2 uv = vUv + vec2(float(i), float(j)) * uTexel;
    float k = max(0.0, 1.0 - abs(vz(uv) - z0) / tol);
    s += texture2D(tAO, uv).r * k; w += k;
  }
  gl_FragColor = vec4(w > 0.001 ? s / w : 1.0, 0.0, 0.0, 1.0);
}`;
const OUT_FS = `
#include <packing>
uniform sampler2D tScene;
uniform sampler2D tAO;
uniform sampler2D tBloom;
uniform highp sampler2D tDepth;
uniform float uAO;
uniform float uBloom;
uniform float uExposure;
uniform float uFog;
uniform float cameraNear;
uniform float cameraFar;
varying vec2 vUv;
// Khronos PBR Neutral, as three's NeutralToneMapping
vec3 neutral(vec3 color) {
  color *= uExposure;
  float x = min(color.r, min(color.g, color.b));
  color -= x < 0.08 ? x - 6.25 * x * x : 0.04;
  float peak = max(color.r, max(color.g, color.b));
  if (peak < 0.76) return color;
  float np = 1.0 - 0.0576 / (peak - 0.52);
  color *= np / peak;
  return mix(color, vec3(np), 1.0 - 1.0 / (0.15 * (peak - np) + 1.0));
}
vec3 srgb(vec3 c) { return mix(c * 12.92, 1.055 * pow(c, vec3(0.4166667)) - 0.055, step(0.0031308, c)); }
void main() {
  vec4 s = texture2D(tScene, vUv);
  float m = clamp(s.a, 0.0, 1.0);
  vec3 c = s.rgb;
  #ifdef USE_AO
    float z = -perspectiveDepthToViewZ(texture2D(tDepth, vUv).x, cameraNear, cameraFar);
    c *= mix(1.0, texture2D(tAO, vUv).r, uAO * m * exp(-uFog * uFog * z * z));
  #endif
  #ifdef USE_BLOOM
    c += texture2D(tBloom, vUv).rgb * uBloom;
  #endif
  c = srgb(clamp(mix(c, neutral(c), m), 0.0, 1.0));
  // a triangular wobble of about one step, so slow gradients do not band
  vec2 p = gl_FragCoord.xy;
  float n = fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))) + fract(52.9829189 * fract(dot(p.yx + 31.7, vec2(0.06711056, 0.00583715))));
  gl_FragColor = vec4(c + (n - 1.0) / 255.0, 1.0);
}`;

// cfg: samples, ao: { k, radius, thickness, scale } | null, bloom: { k, threshold, knee, scatter } | null, exposure, fog
// -> { render(scene, camera), setSize(), setAO(on), setBloom(on), warm(scene, camera), bytes(), dispose() }
function makePost(renderer, cfg) {
  const ext = renderer.extensions, fullFloat = ext.has('EXT_color_buffer_float');
  if (!(fullFloat || ext.has('EXT_color_buffer_half_float'))) return null;
  const canAO = fullFloat;   // the occlusion reads a float depth
  const HF = THREE.HalfFloatType, LIN = THREE.LinearFilter;
  const target = (w, h, o) => new THREE.WebGLRenderTarget(w, h, Object.assign({ type: HF, minFilter: LIN, magFilter: LIN, generateMipmaps: false, depthBuffer: false }, o));
  const depthTex = new THREE.DepthTexture(2, 2, THREE.UnsignedIntType);
  const sceneRT = target(2, 2, { samples: cfg.samples, depthBuffer: true, depthTexture: depthTex });
  const aoA = target(2, 2, { format: THREE.RedFormat, type: THREE.UnsignedByteType });
  const aoB = aoA.clone();
  const zHalf = target(2, 2, { format: THREE.RedFormat, type: THREE.FloatType, minFilter: THREE.NearestFilter, magFilter: THREE.NearestFilter });
  const mips = [];
  for (let i = 0; i < 6; i++) mips.push(target(2, 2));
  const mat = (fs, uniforms, extra) => new THREE.ShaderMaterial(Object.assign({ vertexShader: POST_VS, fragmentShader: fs, uniforms, depthTest: false, depthWrite: false, blending: THREE.NoBlending, toneMapped: false }, extra || {}));
  const noise = generateMagicSquareNoise();
  // a sliver a pixel or two across (a wire, a light) has no surface to read its normal from: it faces the camera
  const gtaoFS = GTAOShader.fragmentShader.replace('return normalize(cross(dpdx, dpdy));', [
    'float zc = getViewZ(c0), tl = 0.02 * abs(zc) + 0.004;',
    'if ((abs(getViewZ(l1) - zc) > tl && abs(getViewZ(r1) - zc) > tl) || (abs(getViewZ(b1) - zc) > tl && abs(getViewZ(t1) - zc) > tl)) return vec3(0.0, 0.0, 1.0);',
    'return normalize(cross(dpdx, dpdy));'].join('\n'));
  const aoMat = mat(gtaoFS, THREE.UniformsUtils.clone(GTAOShader.uniforms), { defines: Object.assign({}, GTAOShader.defines, { NORMAL_VECTOR_TYPE: 0, DEPTH_SWIZZLING: 'x', SAMPLES: 16, PERSPECTIVE_CAMERA: 1 }) });
  const AU = aoMat.uniforms;
  AU.tNoise.value = noise; AU.tDepth.value = zHalf.texture;
  const zMat = mat(DEPTH_DOWN_FS, { tDepth: { value: depthTex } });
  const ao = cfg.ao || { k: 0, radius: 0.3, thickness: 0.6 };
  AU.radius.value = ao.radius; AU.thickness.value = ao.thickness; AU.distanceExponent.value = 1.5; AU.distanceFallOff.value = 1; AU.scale.value = ao.scale || 1;
  const blurMat = mat(AO_BLUR_FS, { tAO: { value: aoA.texture }, tDepth: { value: zHalf.texture }, uTexel: { value: new THREE.Vector2() }, cameraNear: { value: 0.1 }, cameraFar: { value: 100 } });
  const bl = cfg.bloom || { k: 0, threshold: 1, knee: 0.5, scatter: 0.8 };
  const knee = Math.max(1e-3, bl.knee);
  const preMat = mat(BLOOM_PRE_FS, { tSrc: { value: sceneRT.texture }, uTexel: { value: new THREE.Vector2() }, uCurve: { value: new THREE.Vector4(bl.threshold - knee, 2 * knee, 0.25 / knee, bl.threshold) } });
  const downMat = mat(BLOOM_DOWN_FS, { tSrc: { value: null }, uTexel: { value: new THREE.Vector2() } });
  const upMat = mat(BLOOM_UP_FS, { tSrc: { value: null }, uTexel: { value: new THREE.Vector2() }, uK: { value: bl.scatter } },
    { blending: THREE.CustomBlending, blendEquation: THREE.AddEquation, blendSrc: THREE.OneFactor, blendDst: THREE.OneFactor, blendSrcAlpha: THREE.ZeroFactor, blendDstAlpha: THREE.OneFactor });
  const outMat = mat(OUT_FS, { tScene: { value: sceneRT.texture }, tAO: { value: aoB.texture }, tBloom: { value: mips[0].texture }, tDepth: { value: depthTex },
    uAO: { value: ao.k }, uBloom: { value: bl.k }, uExposure: { value: cfg.exposure || 1 }, uFog: { value: cfg.fog || 0 }, cameraNear: { value: 0.1 }, cameraFar: { value: 100 } });
  const tri = new THREE.BufferGeometry();
  tri.setAttribute('position', new THREE.BufferAttribute(new Float32Array([-1, -1, 0, 3, -1, 0, -1, 3, 0]), 3));
  const quad = new THREE.Mesh(tri, outMat); quad.frustumCulled = false;
  const qCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
  const pass = (m, rt) => { quad.material = m; renderer.setRenderTarget(rt); renderer.render(quad, qCam); };
  const _cc = new THREE.Color();
  const self = {
    ao: !!cfg.ao && ao.k > 0, bloom: !!cfg.bloom && bl.k > 0, samples: cfg.samples, w: 2, h: 2, calls: 0, triangles: 0,
    setAO(on) { self.ao = !!on && canAO; sceneRT.resolveDepthBuffer = self.ao; if (self.ao) outMat.defines.USE_AO = 1; else delete outMat.defines.USE_AO; outMat.needsUpdate = true; },
    setBloom(on) { self.bloom = !!on; if (self.bloom) outMat.defines.USE_BLOOM = 1; else delete outMat.defines.USE_BLOOM; outMat.needsUpdate = true; },
    setSize() {
      const v = renderer.getDrawingBufferSize(new THREE.Vector2()), w = Math.max(2, v.x), h = Math.max(2, v.y);
      self.w = w; self.h = h;
      sceneRT.setSize(w, h);
      const w2 = Math.max(2, Math.ceil(w / 2)), h2 = Math.max(2, Math.ceil(h / 2));
      aoA.setSize(w2, h2); aoB.setSize(w2, h2); zHalf.setSize(w2, h2);
      AU.resolution.value.set(w2, h2);
      blurMat.uniforms.uTexel.value.set(1 / w2, 1 / h2);
      preMat.uniforms.uTexel.value.set(1 / w, 1 / h);
      mips.forEach((m, i) => m.setSize(Math.max(2, Math.ceil(w / (2 << i))), Math.max(2, Math.ceil(h / (2 << i)))));
    },
    render(scene, camera) {
      const ac = renderer.autoClear;
      renderer.autoClear = true;
      renderer.setRenderTarget(sceneRT);
      renderer.render(scene, camera);
      self.calls = renderer.info.render.calls; self.triangles = renderer.info.render.triangles;
      renderer.autoClear = false;
      for (const m of [AU, blurMat.uniforms, outMat.uniforms]) { m.cameraNear.value = camera.near; m.cameraFar.value = camera.far; }
      if (self.ao) {
        AU.cameraProjectionMatrix.value.copy(camera.projectionMatrix);
        AU.cameraProjectionMatrixInverse.value.copy(camera.projectionMatrixInverse);
        AU.cameraWorldMatrix.value.copy(camera.matrixWorld);
        pass(zMat, zHalf);
        renderer.getClearColor(_cc); const ca = renderer.getClearAlpha();
        renderer.setRenderTarget(aoA); renderer.setClearColor(0xffffff, 1); renderer.clear(true, false, false); renderer.setClearColor(_cc, ca);
        pass(aoMat, aoA);
        pass(blurMat, aoB);
      }
      if (self.bloom) {
        pass(preMat, mips[0]);
        for (let i = 1; i < mips.length; i++) {
          downMat.uniforms.tSrc.value = mips[i - 1].texture; downMat.uniforms.uTexel.value.set(1 / mips[i - 1].width, 1 / mips[i - 1].height);
          pass(downMat, mips[i]);
        }
        for (let i = mips.length - 2; i >= 0; i--) {
          upMat.uniforms.tSrc.value = mips[i + 1].texture; upMat.uniforms.uTexel.value.set(1 / mips[i + 1].width, 1 / mips[i + 1].height);
          pass(upMat, mips[i]);
        }
      }
      pass(outMat, null);
      renderer.autoClear = ac;
    },
    // the programs the first real frame would otherwise build in the middle of a move
    warm(scene, camera) {
      renderer.setRenderTarget(sceneRT); renderer.compile(scene, camera);
      for (const m of [zMat, aoMat, blurMat, preMat, downMat, upMat]) { quad.material = m; renderer.compile(quad, qCam); }
      renderer.setRenderTarget(null);
      quad.material = outMat; renderer.compile(quad, qCam);
    },
    bytes() {
      const px = self.w * self.h, s = Math.max(0, Math.min(self.samples, renderer.capabilities.maxSamples));
      let b = px * 8 + px * 4 + (s ? px * s * (8 + 4) : 0);
      b += 6 * aoA.width * aoA.height;
      for (const m of mips) b += m.width * m.height * 8;
      return b;
    },
    dispose() {
      for (const t of [sceneRT, aoA, aoB, zHalf, ...mips]) t.dispose();
      depthTex.dispose(); noise.dispose(); tri.dispose();
      for (const m of [zMat, aoMat, blurMat, preMat, downMat, upMat, outMat]) m.dispose();
    },
  };
  self.setAO(self.ao); self.setBloom(self.bloom);
  self.setSize();
  return self;
}


/* ── numbers ───────────────────────────────────────────────────────────── */
const num = v => (v == null || v === '' || typeof v === 'boolean' || !isFinite(+v) ? null : +v);
const sum = a => a.reduce((s, v) => s + v, 0);
const mean = a => sum(a) / a.length;
const median = a => { const s = a.slice().sort((x, y) => x - y), m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
const fmtN = (v, d) => (+v).toLocaleString('en-US', { maximumFractionDigits: d || 0, minimumFractionDigits: d || 0 });
const fmtRps = v => (v >= 1e6 ? fmtN(v / 1e6, v >= 1e7 ? 1 : 2) + 'M' : v >= 1e4 ? fmtN(v / 1e3) + 'k' : fmtN(v));
const fmtMem = m => (m >= 1024 ? fmtN(m / 1024, m >= 10240 ? 0 : 1) + ' GiB' : fmtN(m) + ' MiB');
const fmtMs = ms => fmtN(ms, ms >= 100 ? 0 : ms >= 10 ? 1 : 2) + ' ms';
const fmtBw = b => (b >= 1000 ? fmtN(b / 1000, 2) + ' GB/s' : fmtN(b, 1) + ' MB/s');
const scoreNum = s => { const v = parseFloat(String(s == null ? '' : s).replace(/,/g, '')); return isFinite(v) ? v : null; };
const COMP = [['routing', 'Routing'], ['middleware', 'Middleware'], ['request', 'Request'], ['response', 'Response']];
const STRENGTH = [['thr', 'Throughput'], ['lat', 'Latency'], ['mem', 'Memory'], ['cov', 'Coverage'], ['sr', 'Spec and resilience']];
function hexRgb(h) { const x = parseInt(String(h).slice(1), 16); return [(x >> 16) & 255, (x >> 8) & 255, x & 255]; }
function rampCss(stops, t) {
  t = clamp01(t) * (stops.length - 1);
  const i = Math.min(stops.length - 2, Math.floor(t)), f = t - i;
  const a = hexRgb(stops[i]), b = hexRgb(stops[i + 1]);
  return 'rgb(' + a.map((v, k) => Math.round(v + (b[k] - v) * f)).join(',') + ')';
}
const rampColor = (stops, t) => new THREE.Color(rampCss(stops, t));
function ledHole(ctx, x, y, ro, ri, P) {
  ctx.fillStyle = 'rgba(0,0,0,.35)'; circle(ctx, x, y + 0.8, ro + 0.6); ctx.fill();
  ctx.fillStyle = P.ledRim; circle(ctx, x, y, ro); ctx.fill();
  ctx.fillStyle = P.ledHole; circle(ctx, x, y, ri); ctx.fill();
}

// Where everything sits on a panel, in texture px (1024 x 92): the left ear holds
// the locator and the activity and error lights, the right ear the memory gauge.
function layout(n) {
  const L = { n, cy: 46, locX: 17, locY: 30, actX: 10.5, errX: 23.5, stY: 69, rankX: 74, lang: [102, 194], nameX: 202,
    gaugeX: [1000, 1010], gaugeY: [14, 78], lcdY: [16, 76], pipY: [37, 55], fanR: 29, eqY: [14, 78] };
  if (n > 0) {
    L.lcd = [836, 974];
    L.sp = Math.min(16.5, 270 / n);
    L.eqX0 = L.lcd[0] - 16 - n * L.sp;
    L.fanX = L.eqX0 - 13 - L.fanR;
  } else {
    L.lcd = [790, 974];
    L.fanX = L.lcd[0] - 16 - L.fanR;
  }
  L.pipX = L.fanX - L.fanR - 26;
  L.nameEnd = L.pipX - 12;
  return L;
}
const pxX = px => (px / TW - 0.5) * PANEL_W;
const pxY = py => (0.5 - py / TH) * UNIT_H;

/* ── the unit's panel ──────────────────────────────────────────────────── */
function drawFace(cv, u, L, P) {
  const ctx = cv.getContext('2d');
  const s = cv.width / TW;
  ctx.setTransform(s, 0, 0, s, 0, 0);
  ctx.clearRect(0, 0, TW, TH);
  const W = TW, H = TH, cy = L.cy;
  let g = ctx.createLinearGradient(0, 0, 0, H);
  g.addColorStop(0, P.face[0]); g.addColorStop(0.5, P.face[1]); g.addColorStop(1, P.face[2]);
  ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
  // a fine brushed grain, the same for a unit every time it is drawn
  const r = rng(hash(u.fw));
  for (let y = 2; y < H - 2; y += 1.5) {
    ctx.globalAlpha = P.grainK * (0.3 + r());
    ctx.fillStyle = r() < 0.5 ? P.grain[0] : P.grain[1];
    ctx.fillRect(0, y, W, 0.75);
  }
  ctx.globalAlpha = 1;
  ctx.fillStyle = P.ear; ctx.fillRect(0, 0, 34, H); ctx.fillRect(990, 0, 34, H);
  ctx.fillStyle = P.earSeam; ctx.fillRect(34, 0, 1.5, H); ctx.fillRect(988.5, 0, 1.5, H);
  ctx.fillStyle = P.faceHi; ctx.fillRect(0, 0, W, 1.6);
  ctx.fillStyle = P.faceLo; ctx.fillRect(0, H - 2, W, 2);
  // the left ear: the locator button, and under it the activity and error lights
  ledHole(ctx, L.locX, L.locY, 11.5, 9, P);
  ledHole(ctx, L.actX, L.stY, 5.2, 3.9, P);
  ledHole(ctx, L.errX, L.stY, 5.2, 3.9, P);
  // the right ear: the memory gauge, filled from the bottom (log scale over the hall)
  const [gx0, gx1] = L.gaugeX, [gy0, gy1] = L.gaugeY;
  ctx.fillStyle = P.ledRim; rrect(ctx, gx0 - 2, gy0 - 2, gx1 - gx0 + 4, gy1 - gy0 + 4, 3); ctx.fill();
  ctx.fillStyle = P.ledHole; rrect(ctx, gx0, gy0, gx1 - gx0, gy1 - gy0, 2); ctx.fill();
  if (u.memN != null) {
    const h = Math.max(4, (gy1 - gy0 - 2) * clamp01(u.memN));
    const gg = ctx.createLinearGradient(0, gy1, 0, gy0);
    gg.addColorStop(0, rampCss(P.ramp, 0.05)); gg.addColorStop(0.55, rampCss(P.ramp, 0.55)); gg.addColorStop(1, rampCss(P.ramp, 1));
    ctx.save(); rrect(ctx, gx0 + 1.5, gy1 - 1 - h, gx1 - gx0 - 3, h, 1.5); ctx.clip(); ctx.fillStyle = gg; ctx.fillRect(gx0, gy0, gx1 - gx0, gy1 - gy0); ctx.restore();
  }
  ctx.fillStyle = P.silk; ctx.globalAlpha = 0.6;
  for (const f of [0.25, 0.5, 0.75]) ctx.fillRect(gx1 + 3, gy1 - (gy1 - gy0) * f - 0.6, 4, 1.2);
  ctx.globalAlpha = 1;
  // a tuned entry wears hazard stripes at both ends of its panel
  if (u.tuned) { hazard(ctx, 37.5, 2, 9, H - 4); hazard(ctx, 977.5, 2, 9, H - 4); }
  // the service label: the rank, gold, silver and bronze for the first three
  const rk = String(u.rank);
  const pl = RANK_PLATES[u.rank];
  if (pl) {
    const x = L.rankX - 23, y = 19, w = 46, h = 54;
    ctx.save(); ctx.shadowColor = 'rgba(0,0,0,.45)'; ctx.shadowBlur = 4; ctx.shadowOffsetY = 1.5;
    g = ctx.createLinearGradient(x, y, x + w, y + h);
    g.addColorStop(0, pl[0]); g.addColorStop(0.55, pl[1]); g.addColorStop(1, pl[2]);
    ctx.fillStyle = g; rrect(ctx, x, y, w, h, 3); ctx.fill(); ctx.restore();
    ctx.fillStyle = 'rgba(255,255,255,.6)'; ctx.fillRect(x + 2, y + 1, w - 4, 1.2);
    ctx.font = '700 30px ' + FONT_SANS; ctx.textAlign = 'center'; ctx.fillStyle = pl[3];
    ctx.fillText(rk, L.rankX, centreY(ctx, rk, cy));
  } else {
    const f = fit(ctx, rk, '600', FONT_SANS, 27, 17, 50);
    ctx.font = '600 ' + f.px + 'px ' + FONT_SANS; ctx.textAlign = 'center'; ctx.fillStyle = P.silk;
    ctx.fillText(f.text, L.rankX, centreY(ctx, '0', cy));
  }
  // the vendor strip: the language, on its colour
  if (u.lang) {
    const [x0, x1] = L.lang, y = 25, h = 42;
    ctx.fillStyle = P.bay; rrect(ctx, x0, y, x1 - x0, h, 2); ctx.fill();
    ctx.strokeStyle = P.bayLine; ctx.lineWidth = 1; rrect(ctx, x0 + 0.5, y + 0.5, x1 - x0 - 1, h - 1, 2); ctx.stroke();
    ctx.fillStyle = u.langColor; ctx.fillRect(x0, y, 6, h);
    spacing(ctx, '1px');
    const f = fit(ctx, u.lang.toUpperCase(), '600', FONT_LABEL, 22, 13, x1 - x0 - 20);
    ctx.font = '600 ' + f.px + 'px ' + FONT_LABEL; ctx.textAlign = 'left'; ctx.fillStyle = P.langText;
    ctx.fillText(f.text, x0 + 13, centreY(ctx, 'H', cy));
    spacing(ctx, '0px');
  }
  // the name plate, and the engine it runs on under it
  const eng = u.engine && u.engine.toLowerCase() !== u.fw.toLowerCase() ? 'on ' + u.engine : '';
  const nameW = L.nameEnd - L.nameX - 18, ny = eng ? cy - 9 : cy;
  const f = fit(ctx, u.fw, '600', FONT_LABEL, eng ? 31 : 34, 19, nameW);
  ctx.font = '600 ' + f.px + 'px ' + FONT_LABEL; ctx.textAlign = 'left';
  ctx.fillStyle = u.fav ? P.nameFav : P.name;
  ctx.fillText(f.text, L.nameX, centreY(ctx, 'H', ny));
  if (eng) {
    const e = fit(ctx, eng, '500', FONT_SANS, 16, 12, nameW);
    ctx.font = '500 ' + e.px + 'px ' + FONT_SANS; ctx.fillStyle = P.silk;
    ctx.fillText(e.text, L.nameX + 1, centreY(ctx, 'n', cy + 22));
  }
  if (TYPE_COLORS[u.type]) { ctx.fillStyle = TYPE_COLORS[u.type]; rrect(ctx, L.nameEnd - 10, ny - 4.5, 9, 9, 1.5); ctx.fill(); }
  // the completeness pips: routing, middleware / request, response
  for (const yy of L.pipY) for (const dx of [0, 11]) ledHole(ctx, L.pipX + dx, yy, 4.6, 3.4, P);
  // the fan's bezel (the fan turns in front of it)
  ctx.fillStyle = 'rgba(0,0,0,.35)'; circle(ctx, L.fanX, cy + 1, L.fanR + 4.6); ctx.fill();
  ctx.fillStyle = P.ledRim; circle(ctx, L.fanX, cy, L.fanR + 3.7); ctx.fill();
  ctx.fillStyle = P.ledHole; circle(ctx, L.fanX, cy, L.fanR + 1.2); ctx.fill();
  for (const [dx, dy] of [[-1, -1], [1, -1], [-1, 1], [1, 1]]) { ctx.fillStyle = P.ledRim; circle(ctx, L.fanX + dx * (L.fanR + 1), cy + dy * (L.fanR + 1) * 0.95, 1.6); ctx.fill(); }
  // the equaliser's window
  if (L.n) {
    const x0 = L.eqX0 - 4, w = L.n * L.sp + 8, y0 = L.eqY[0] - 4, h = L.eqY[1] - L.eqY[0] + 8;
    ctx.fillStyle = P.ledRim; rrect(ctx, x0 - 1.2, y0 - 1.2, w + 2.4, h + 2.4, 3); ctx.fill();
    ctx.fillStyle = P.ledHole; rrect(ctx, x0, y0, w, h, 2.5); ctx.fill();
  }
  // the display's bezel (the display is a part of its own, lit)
  const [l0, l1] = L.lcd, [y0, y1] = L.lcdY;
  ctx.fillStyle = P.lcdBezel; rrect(ctx, l0 - 4, y0 - 4, l1 - l0 + 8, y1 - y0 + 8, 3); ctx.fill();
  ctx.fillStyle = P.faceHi; ctx.globalAlpha = 0.5; ctx.fillRect(l0 - 3, y1 + 3.4, l1 - l0 + 6, 1); ctx.globalAlpha = 1;
  // the console port the crash cart plugs into
  ctx.fillStyle = P.ledRim; rrect(ctx, 979.4, 36.5, 7.6, 19, 2); ctx.fill();
  ctx.fillStyle = P.ledHole; rrect(ctx, 980.6, 38, 5.2, 16, 1.5); ctx.fill();
  ctx.fillStyle = P.silk; ctx.globalAlpha = 0.7; ctx.fillRect(982.4, 41, 1.6, 10); ctx.globalAlpha = 1;
}

/* ── an open unit: the lid with its service tag, the board, the hologram ─ */
function drawLid(cv, u, P) {
  const ctx = cv.getContext('2d'), W = cv.width, H = cv.height;  // the canvas' top is the back of the chassis
  let g = ctx.createLinearGradient(0, 0, W, 0);
  g.addColorStop(0, P.lid[1]); g.addColorStop(0.5, P.lid[0]); g.addColorStop(1, P.lid[1]);
  ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
  const r = rng(hash(u.fw) ^ 0x9e37);
  for (let y = 0; y < H; y += 3) { ctx.globalAlpha = 0.04 * r(); ctx.fillStyle = r() < 0.5 ? '#fff' : '#000'; ctx.fillRect(0, y, W, 1.5); }
  ctx.globalAlpha = 1;
  // only the lid's front stays out of the rack once it slides back: the tag lives there
  const tagH = Math.round(H * 0.095 / BODY_D);
  ctx.fillStyle = 'rgba(0,0,0,.4)'; ctx.fillRect(0, H - tagH - 18, W, 4);
  ctx.fillStyle = 'rgba(0,0,0,.5)';
  for (let row = 0; row < 4; row++) for (let i = 0; i < 18; i++) { rrect(ctx, 60 + i * 52, H * 0.38 + row * 32, 34, 12, 6); ctx.fill(); }
  for (const [x, y] of [[30, 30], [W - 30, 30], [30, H - tagH - 50], [W - 30, H - tagH - 50]]) screwHead(ctx, x, y, 11, P);
  const sx = 34, sy = H - tagH + 2, sw = W - 68, sh = tagH - 16;
  ctx.save(); ctx.shadowColor = 'rgba(0,0,0,.4)'; ctx.shadowBlur = 8; ctx.shadowOffsetY = 3;
  ctx.fillStyle = P.sticker; rrect(ctx, sx, sy, sw, sh, 10); ctx.fill(); ctx.restore();
  ctx.fillStyle = u.langColor; ctx.fillRect(sx, sy + 14, 12, sh - 28);
  const bw = 150, tx = sx + 34, tw = sw - 34 - bw - 40;
  ctx.textAlign = 'left'; ctx.fillStyle = P.stickerText;
  let f = fit(ctx, u.fw, '700', FONT_LABEL, 58, 30, tw - 150);
  ctx.font = '700 ' + f.px + 'px ' + FONT_LABEL; ctx.fillText(f.text, tx, sy + 62);
  ctx.font = '600 34px ' + FONT_SANS; ctx.textAlign = 'right'; ctx.fillText('Rank ' + u.rank, tx + tw, sy + 60); ctx.textAlign = 'left';
  const meta = [u.lang, TYPE_NAMES[u.type], u.tuned ? 'tuned' : '', u.engine && u.engine.toLowerCase() !== u.fw.toLowerCase() ? 'on ' + u.engine : ''].filter(Boolean).join('  ·  ');
  f = fit(ctx, meta, '500', FONT_SANS, 32, 20, tw);
  ctx.font = '500 ' + f.px + 'px ' + FONT_SANS; ctx.fillStyle = 'rgba(20,24,29,.78)'; ctx.fillText(f.text, tx, sy + 118);
  const comp = u.completeness ? COMP.filter(([k]) => u.completeness[k]).length : null;
  const facts = [u.spec != null ? 'Spec ' + fmtN(u.spec, u.spec % 1 ? 1 : 0) + '%' : '', u.resil != null ? 'Resilience ' + fmtN(u.resil, u.resil % 1 ? 1 : 0) + '%' : '', comp != null ? 'Complete ' + comp + ' of 4' : ''].filter(Boolean).join('  ·  ') || 'Not graded';
  f = fit(ctx, facts, '600', FONT_SANS, 32, 20, tw);
  ctx.font = '600 ' + f.px + 'px ' + FONT_SANS; ctx.fillStyle = P.stickerText; ctx.fillText(f.text, tx, sy + 168);
  const rb = rng(hash(u.fw));
  let x = sx + sw - bw - 24;
  while (x < sx + sw - 30) { const w = 2 + Math.floor(rb() * 3) * 2; ctx.fillRect(x, sy + 26, w, sh - 52); x += w + 2 + Math.floor(rb() * 3) * 2; }
}

// the interior's plan, in the unit's own metres (z from its face backwards)
function interiorPlan(n) {
  const K = { zChip: -0.2, chipMax: 0.046, zCpu: -0.31, cpu: 0.078, zRam: -0.3, ramLen: 0.12, nic: 0.168, psu: -0.168 };
  K.pitch = n ? Math.min(0.026, 0.37 / n) : 0;
  K.chipW = Math.max(0.008, K.pitch * 0.58);
  K.chipX = Array.from({ length: n }, (_, t) => (t - (n - 1) / 2) * K.pitch);
  K.ramX = [-0.112, -0.1, -0.088, -0.076, 0.076, 0.088, 0.1, 0.112];
  return K;
}
function drawPcb(cv, u, tests, K, P) {
  const ctx = cv.getContext('2d'), W = cv.width, H = cv.height;
  const X = x => (x / BODY_W + 0.5) * W, Y = z => (z + PLATE_T + BODY_D) / BODY_D * H;
  ctx.fillStyle = P.pcb[0]; ctx.fillRect(0, 0, W, H);
  const r = rng(hash(u.fw) ^ 0x51);
  ctx.strokeStyle = P.pcb[1]; ctx.lineWidth = 3; ctx.globalAlpha = 0.55;
  for (let i = 0; i < 90; i++) {
    let x = r() * W, y = r() * H; ctx.beginPath(); ctx.moveTo(x, y);
    for (let k = 0; k < 4; k++) { if (r() < 0.5) x += (r() - 0.5) * 260; else y += (r() - 0.5) * 260; ctx.lineTo(x, y); }
    ctx.stroke();
  }
  ctx.globalAlpha = 1;
  ctx.fillStyle = P.pcb[3];
  for (let i = 0; i < 260; i++) ctx.fillRect(r() * W, r() * H, 4, 4);
  ctx.fillStyle = P.pcb[2]; ctx.strokeStyle = P.pcb[2]; ctx.lineWidth = 2.5;
  // under each chip a pad, in front of it its test, slanted like a chart's axis
  for (let t = 0; t < tests.length; t++) {
    const cx = X(K.chipX[t]), cz = Y(K.zChip), hw = K.chipW / BODY_W * W * 0.5 + 6;
    ctx.globalAlpha = 0.9; ctx.strokeRect(cx - hw, cz - hw, hw * 2, hw * 2); ctx.globalAlpha = 1;
    const lab = fit(ctx, String(tests[t].label || ''), '600', FONT_SANS, 26, 15, 250);
    ctx.save(); ctx.translate(cx + 4, Y(K.zChip + 0.016)); ctx.rotate(-Math.PI / 4);
    ctx.font = '600 ' + lab.px + 'px ' + FONT_SANS; ctx.textAlign = 'right'; ctx.fillText(lab.text, 0, 0); ctx.restore();
  }
  // the CPU's socket, the memory slots, the NIC and the power supply
  const cs = K.cpu / BODY_W * W * 0.5 + 14;
  ctx.strokeRect(X(0) - cs, Y(K.zCpu) - cs, cs * 2, cs * 2);
  ctx.font = '600 26px ' + FONT_SANS; ctx.textAlign = 'left';
  ctx.fillText('CPU0', X(0) - cs, Y(K.zCpu) + cs + 30);
  for (let i = 0; i < 8; i++) {
    const x = X(K.ramX[i]), y0 = Y(K.zRam + K.ramLen / 2), y1 = Y(K.zRam - K.ramLen / 2);
    ctx.globalAlpha = 0.85; ctx.strokeRect(x - 7, y1, 14, y0 - y1); ctx.globalAlpha = 1;
  }
  ctx.textAlign = 'center';
  ctx.fillText('DIMM A', X(-0.094), Y(K.zRam - K.ramLen / 2) - 14);
  ctx.fillText('DIMM B', X(0.094), Y(K.zRam - K.ramLen / 2) - 14);
  ctx.fillText('NIC0', X(K.nic), Y(K.zRam - 0.07) - 12);
  ctx.fillText('PSU', X(K.psu), Y(K.zRam - 0.07) - 12);
  ctx.textAlign = 'left';
  ctx.font = '700 24px ' + FONT_SANS; ctx.globalAlpha = 0.85;
  ctx.fillText('HTTPARENA MB-' + String(u.rank).padStart(3, '0') + '  REV ' + (hash(u.fw) % 9 + 1), X(-0.2), Y(-0.07));
  ctx.globalAlpha = 1;
}

// the strength card as a hologram: a pentagon, its five axes, the rest under it
function drawHolo(cv, u, P) {
  const ctx = cv.getContext('2d'), W = cv.width, H = cv.height;
  ctx.clearRect(0, 0, W, H);
  const col = P.holo, st = u.strength || {};
  // a pane of dark glass (light glass in the clean room) so it reads over a busy rack
  ctx.fillStyle = P.holoAdd ? 'rgba(2,10,16,0.78)' : 'rgba(255,255,255,0.86)'; rrect(ctx, 6, 6, W - 12, H - 12, 28); ctx.fill();
  ctx.strokeStyle = col; ctx.globalAlpha = 0.7; ctx.lineWidth = 3; rrect(ctx, 6, 6, W - 12, H - 12, 28); ctx.stroke(); ctx.globalAlpha = 1;
  if (P.holoAdd) { ctx.shadowColor = col; ctx.shadowBlur = 10; }
  ctx.textAlign = 'center'; ctx.fillStyle = col; ctx.strokeStyle = col;
  let f = fit(ctx, u.fw, '700', FONT_LABEL, 46, 26, W - 80);
  ctx.font = '700 ' + f.px + 'px ' + FONT_LABEL; ctx.fillText(f.text, W / 2, 62);
  ctx.font = '500 26px ' + FONT_SANS; ctx.globalAlpha = 0.8; ctx.fillText('Strength, of 100', W / 2, 98); ctx.globalAlpha = 1;
  const cx = W / 2, cy = H * 0.55, R = W * 0.27;
  const pt = (i, k) => { const a = -Math.PI / 2 + i * 2 * Math.PI / 5; return [cx + Math.cos(a) * R * k, cy + Math.sin(a) * R * k]; };
  ctx.lineWidth = 2;
  for (const k of [0.25, 0.5, 0.75, 1]) {
    ctx.globalAlpha = k === 1 ? 0.6 : 0.22; ctx.beginPath();
    for (let i = 0; i < 5; i++) { const [x, y] = pt(i, k); i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }
    ctx.closePath(); ctx.stroke();
  }
  for (let i = 0; i < 5; i++) { const [x, y] = pt(i, 1); ctx.globalAlpha = 0.3; ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(x, y); ctx.stroke(); }
  const vals = STRENGTH.map(([k]) => num(st[k]));
  if (vals.some(v => v != null)) {
    ctx.beginPath();
    vals.forEach((v, i) => { const [x, y] = pt(i, clamp01((v || 0) / 100)); i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); });
    ctx.closePath(); ctx.globalAlpha = 0.28; ctx.fill(); ctx.globalAlpha = 1; ctx.lineWidth = 4; ctx.stroke();
    vals.forEach((v, i) => { if (v == null) return; const [x, y] = pt(i, clamp01(v / 100)); circle(ctx, x, y, 7); ctx.fill(); });
  }
  ctx.globalAlpha = 1;
  STRENGTH.forEach(([k, name], i) => {
    const [x, y] = pt(i, 1.24), v = vals[i];
    ctx.font = '600 25px ' + FONT_SANS; ctx.fillText(name === 'Spec and resilience' ? 'Spec, resilience' : name, x, y - 4);
    ctx.font = '700 30px ' + FONT_SANS; ctx.globalAlpha = v == null ? 0.55 : 1; ctx.fillText(v == null ? 'n/a' : fmtN(v), x, y + 28); ctx.globalAlpha = 1;
  });
  const comp = u.completeness ? COMP.filter(([c]) => u.completeness[c]).length : null;
  const foot = [u.spec != null ? 'Spec ' + fmtN(u.spec, u.spec % 1 ? 1 : 0) + '%' : '', u.resil != null ? 'Resilience ' + fmtN(u.resil, u.resil % 1 ? 1 : 0) + '%' : '', comp != null ? 'Complete ' + comp + '/4' : ''].filter(Boolean).join('  ·  ');
  if (foot) { f = fit(ctx, foot, '600', FONT_SANS, 26, 16, W - 60); ctx.font = '600 ' + f.px + 'px ' + FONT_SANS; ctx.fillText(f.text, W / 2, H - 26); }
}

// the marquee's message, one canvas pixel per dot
function marqueeCanvas(text) {
  const probe = canvas(8, MQ_ROWS).getContext('2d');
  const font = '700 13px ' + FONT_SANS;
  probe.font = font; spacing(probe, '1px');
  const w = Math.ceil(probe.measureText(text).width) + 6;
  const cv = canvas(w, MQ_ROWS), ctx = cv.getContext('2d');
  ctx.font = font; spacing(ctx, '1px'); ctx.fillStyle = '#fff'; ctx.textBaseline = 'alphabetic';
  ctx.fillText(text, 3, 12.5);
  return cv;
}

// a rack's power strip: its load on a little meter, its language mix down the strip
function rackPduTexture(P, st) {
  const W = 32, H = 2048, cv = canvas(W, H), ctx = cv.getContext('2d');
  ctx.fillStyle = P.pdu[0]; ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = '#020303'; rrect(ctx, 3, 8, W - 6, 78, 4); ctx.fill();
  const load = String(Math.round(st.load * 100));
  ctx.textAlign = 'center';
  ctx.font = '700 17px ' + FONT_SEG; ctx.fillStyle = P.pdu[2];
  ctx.globalAlpha = 0.08; ctx.fillText('88', W / 2, 40); ctx.globalAlpha = 1;
  ctx.fillText(load.length > 2 ? '99' : load, W / 2, 40);
  ctx.font = '700 13px ' + FONT_SANS; ctx.fillText('%', W / 2, 62);
  ctx.fillStyle = 'rgba(255,255,255,.18)'; ctx.fillRect(6, 72, W - 12, 6);
  ctx.fillStyle = P.pdu[2]; ctx.fillRect(6, 72, (W - 12) * clamp01(st.load), 6);
  const top = 100, bot = H - 18, total = st.langs.reduce((s, l) => s + l.n, 0) || 1;
  let y = top;
  for (const l of st.langs) {
    const h = (bot - top) * l.n / total;
    ctx.fillStyle = l.color; rrect(ctx, 5, y + 2, 9, Math.max(2, h - 4), 2); ctx.fill();
    y += h;
  }
  for (let yy = top + 6; yy < bot - 30; yy += 64) {
    ctx.fillStyle = P.pdu[1]; rrect(ctx, 17, yy, 12, 20, 3); ctx.fill();
    ctx.fillStyle = '#2b3036'; ctx.fillRect(19.5, yy + 7, 2.4, 6); ctx.fillRect(24, yy + 7, 2.4, 6);
    ctx.fillStyle = P.ledG; circle(ctx, 23, yy + 27, 1.8); ctx.fill();
  }
  return cv;
}

// a soft blob of light for the floor in front of a rack
function glowTexture() {
  const cv = canvas(128, 128), ctx = cv.getContext('2d');
  const g = ctx.createRadialGradient(64, 64, 2, 64, 64, 64);
  g.addColorStop(0, 'rgba(255,255,255,1)'); g.addColorStop(0.35, 'rgba(255,255,255,.45)'); g.addColorStop(1, 'rgba(255,255,255,0)');
  ctx.fillStyle = g; ctx.fillRect(0, 0, 128, 128);
  return cv;
}

// the podium's faces: a rank on the block, a name plate over the turning unit
function podiumRank(k, col) {
  const cv = canvas(256, 256), ctx = cv.getContext('2d');
  ctx.textAlign = 'center'; ctx.fillStyle = col;
  ctx.shadowColor = col; ctx.shadowBlur = 18;
  ctx.font = '800 170px ' + FONT_SANS; ctx.fillText(String(k + 1), 128, 176);
  ctx.shadowBlur = 0; ctx.font = '600 34px ' + FONT_SANS; ctx.fillText(['First', 'Second', 'Third'][k], 128, 236);
  return cv;
}
function podiumPlate(u, k, col, P) {
  const cv = canvas(640, 200), ctx = cv.getContext('2d');
  ctx.fillStyle = P.holoAdd ? 'rgba(4,10,16,0.82)' : 'rgba(255,255,255,0.92)'; rrect(ctx, 6, 6, 628, 188, 22); ctx.fill();
  ctx.strokeStyle = col; ctx.lineWidth = 4; rrect(ctx, 6, 6, 628, 188, 22); ctx.stroke();
  ctx.textAlign = 'center'; ctx.fillStyle = P.holoAdd ? '#f2f4f6' : '#0f1318';
  const f = fit(ctx, u.fw, '700', FONT_LABEL, 70, 34, 580);
  ctx.font = '700 ' + f.px + 'px ' + FONT_LABEL; ctx.fillText(f.text, 320, 96);
  ctx.font = '600 38px ' + FONT_SANS; ctx.fillStyle = col;
  ctx.fillText(['#1', '#2', '#3'][k] + (u.score ? '  ·  ' + u.score : '') + (u.lang ? '  ·  ' + u.lang : ''), 320, 160);
  return cv;
}

/* ── the operations wall: six screens ──────────────────────────────────── */
function nocBase(ctx, W, H, N, title, sub) {
  ctx.fillStyle = N.bg; ctx.fillRect(0, 0, W, H);
  ctx.strokeStyle = N.grid; ctx.lineWidth = 1;
  for (let x = 40; x < W; x += 40) { ctx.beginPath(); ctx.moveTo(x + 0.5, 0); ctx.lineTo(x + 0.5, H); ctx.stroke(); }
  for (let y = 40; y < H; y += 40) { ctx.beginPath(); ctx.moveTo(0, y + 0.5); ctx.lineTo(W, y + 0.5); ctx.stroke(); }
  ctx.fillStyle = N.accent; ctx.fillRect(0, 0, W, 6);
  ctx.textAlign = 'left'; ctx.fillStyle = N.text;
  const f = fit(ctx, title, '650', FONT_SANS, 54, 32, W - 96);
  ctx.font = '650 ' + f.px + 'px ' + FONT_SANS; ctx.fillText(f.text, 48, 84);
  if (sub) { const g = fit(ctx, sub, '500', FONT_SANS, 30, 22, W - 96); ctx.fillStyle = N.muted; ctx.font = '500 ' + g.px + 'px ' + FONT_SANS; ctx.fillText(g.text, 48, 126); }
}
function nocHist(cv, N, P, d) {
  const ctx = cv.getContext('2d'), W = cv.width, H = cv.height, hits = [];
  nocBase(ctx, W, H, N, 'Score distribution', d.units.length + ' entries by ' + d.metric.toLowerCase() + '. Click a bar to light its entries.');
  const bins = 20, counts = new Array(bins).fill(0);
  for (const u of d.units) counts[Math.min(bins - 1, Math.floor(clamp01(u.share) * bins))]++;
  const mx = Math.max(1, ...counts);
  const x0 = 70, x1 = W - 56, y0 = 186, y1 = H - 96, bw = (x1 - x0) / bins;
  ctx.strokeStyle = N.line; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(x0, y1 + 1); ctx.lineTo(x1, y1 + 1); ctx.stroke();
  for (let i = 0; i < bins; i++) {
    const h = (y1 - y0) * counts[i] / mx, x = x0 + i * bw;
    const lit = d.bin === i;
    ctx.fillStyle = rampCss(P.ramp, (i + 0.5) / bins);
    ctx.globalAlpha = d.bin != null && !lit ? 0.35 : 1;
    rrect(ctx, x + 4, y1 - h, bw - 8, Math.max(h, counts[i] ? 4 : 0), 4); ctx.fill();
    ctx.globalAlpha = 1;
    if (counts[i]) { ctx.fillStyle = N.text; ctx.font = '600 26px ' + FONT_SANS; ctx.textAlign = 'center'; ctx.fillText(String(counts[i]), x + bw / 2, y1 - h - 10); }
    hits.push({ x, y: y0 - 30, w: bw, h: y1 - y0 + 60, act: { kind: 'bin', i }, tip: counts[i] + ' entr' + (counts[i] === 1 ? 'y' : 'ies') + ' at ' + Math.round(i * 100 / bins) + '-' + Math.round((i + 1) * 100 / bins) + '% of the leader' });
  }
  ctx.font = '500 26px ' + FONT_SANS; ctx.fillStyle = N.muted; ctx.textAlign = 'center';
  for (const t of [0, 0.25, 0.5, 0.75, 1]) {
    const x = x0 + t * (x1 - x0);
    ctx.fillText(Math.round(t * 100) + '%', x, y1 + 40);
    if (d.leader != null) ctx.fillText(fmtN(d.leader * t), x, y1 + 74);
  }
  if (d.sel) {
    const x = x0 + clamp01(d.sel.share) * (x1 - x0);
    ctx.strokeStyle = N.accent; ctx.lineWidth = 4; ctx.setLineDash([10, 8]); ctx.beginPath(); ctx.moveTo(x, y0 - 18); ctx.lineTo(x, y1); ctx.stroke(); ctx.setLineDash([]);
    const lab = d.sel.fw + '  ' + d.sel.score;
    ctx.font = '700 30px ' + FONT_SANS; const tw = ctx.measureText(lab).width + 28;
    const bx = clamp(x - tw / 2, 16, W - tw - 16);
    ctx.fillStyle = N.accent; rrect(ctx, bx, y0 - 66, tw, 46, 8); ctx.fill();
    ctx.fillStyle = N.bg; ctx.textAlign = 'left'; ctx.fillText(lab, bx + 14, y0 - 32);
  }
  return hits;
}
function nocView(cv, N, d) {
  const ctx = cv.getContext('2d'), W = cv.width, H = cv.height;
  nocBase(ctx, W, H, N, d.view, [d.metric, d.round].filter(Boolean).join('  ·  '));
  const cells = [[fmtN(d.units.length), 'entries'], [fmtN(d.racks), d.racks === 1 ? 'rack' : 'racks'], [fmtN(d.tests), d.family ? (d.tests === 1 ? 'family' : 'families') : d.tests === 1 ? 'test' : 'tests'], [fmtN(d.langs.length), d.langs.length === 1 ? 'language' : 'languages']];
  const cw = (W - 96) / 4;
  cells.forEach(([v, l], i) => {
    const x = 48 + i * cw;
    ctx.fillStyle = N.text; ctx.textAlign = 'left'; ctx.font = '700 92px ' + FONT_SANS; ctx.fillText(v, x, 300);
    ctx.fillStyle = N.muted; ctx.font = '500 30px ' + FONT_SANS; ctx.fillText(l, x + 4, 344);
  });
  ctx.strokeStyle = N.line; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(48, 400); ctx.lineTo(W - 48, 400); ctx.stroke();
  if (d.leaderU) {
    ctx.fillStyle = N.muted; ctx.font = '500 30px ' + FONT_SANS; ctx.fillText('Leader', 48, 460);
    const f = fit(ctx, d.leaderU.fw, '700', FONT_LABEL, 72, 40, W - 420);
    ctx.fillStyle = N.text; ctx.font = '700 ' + f.px + 'px ' + FONT_LABEL; ctx.fillText(f.text, 48, 540);
    ctx.textAlign = 'right'; ctx.font = '700 72px ' + FONT_SEG; ctx.fillStyle = N.bar; ctx.fillText(String(d.leaderU.score), W - 48, 540);
    ctx.textAlign = 'left';
  }
  ctx.fillStyle = N.muted; ctx.font = '500 30px ' + FONT_SANS;
  ctx.fillText(d.pull ? 'Drawers pulled out by ' + d.pull : 'Drawers in. Pull them out by a measure from the bar below.', 48, H - 60);
}
function nocLangs(cv, N, d) {
  const ctx = cv.getContext('2d'), W = cv.width, H = cv.height, hits = [];
  nocBase(ctx, W, H, N, 'Languages', 'Click a language to light up its entries in every rack.');
  const rows = d.langs.slice(0, 9), y0 = 210, rh = 54;
  ctx.font = '500 24px ' + FONT_SANS; ctx.fillStyle = N.muted; ctx.textAlign = 'left';
  ctx.fillText('Language', 96, y0 - 36); ctx.textAlign = 'right'; ctx.fillText('Entries', 520, y0 - 36); ctx.textAlign = 'left'; ctx.fillText('Best', 560, y0 - 36); ctx.fillText('Average share', 930, y0 - 36);
  rows.forEach((l, i) => {
    const y = y0 + i * rh;
    if (d.lit === l.name) { ctx.fillStyle = N.sel; rrect(ctx, 36, y - 38, W - 72, rh - 6, 8); ctx.fill(); ctx.strokeStyle = N.accent; ctx.lineWidth = 2; ctx.stroke(); }
    ctx.fillStyle = l.color; rrect(ctx, 56, y - 26, 24, 24, 5); ctx.fill();
    ctx.fillStyle = N.text; ctx.textAlign = 'left'; ctx.font = '600 32px ' + FONT_SANS;
    ctx.fillText(fit(ctx, l.name, '600', FONT_SANS, 32, 22, 300).text, 96, y);
    ctx.font = '600 32px ' + FONT_SANS; ctx.textAlign = 'right'; ctx.fillText(String(l.n), 520, y);
    ctx.textAlign = 'left'; const b = fit(ctx, l.best.fw + '  #' + l.best.rank, '500', FONT_SANS, 28, 18, 340);
    ctx.font = '500 ' + b.px + 'px ' + FONT_SANS; ctx.fillStyle = N.muted; ctx.fillText(b.text, 560, y);
    ctx.fillStyle = N.line; rrect(ctx, 930, y - 22, 190, 16, 8); ctx.fill();
    ctx.fillStyle = l.color; rrect(ctx, 930, y - 22, Math.max(8, 190 * l.avg), 16, 8); ctx.fill();
    ctx.fillStyle = N.text; ctx.font = '600 28px ' + FONT_SANS; ctx.textAlign = 'right'; ctx.fillText(Math.round(l.avg * 100) + '%', W - 48, y);
    hits.push({ x: 36, y: y - 40, w: W - 72, h: rh - 2, act: { kind: 'lang', name: l.name }, tip: (d.lit === l.name ? 'Click to clear the light' : 'Click to light up the ' + l.n + ' ' + l.name + ' entr' + (l.n === 1 ? 'y' : 'ies')) });
  });
  if (d.langs.length > rows.length) { ctx.fillStyle = N.muted; ctx.font = '500 26px ' + FONT_SANS; ctx.textAlign = 'left'; ctx.fillText('+ ' + (d.langs.length - rows.length) + ' more languages', 96, y0 + rows.length * rh + 6); }
  return hits;
}
function nocTests(cv, N, d) {
  const ctx = cv.getContext('2d'), W = cv.width, H = cv.height, hits = [];
  nocBase(ctx, W, H, N, d.family ? 'Families' : 'Tests', d.tests.length ? 'Click a test to pull every drawer out by it' + (d.tests.some(t => t.conns) ? '. Figures are connections.' : '.') : 'This view ranks on one figure, so its units have no test lights.');
  if (!d.tests.length) return hits;
  const groups = [];
  for (const t of d.tests) { const c = t.category || ''; let g = groups.find(x => x.c === c); if (!g) groups.push(g = { c, list: [] }); g.list.push(t); }
  const rows = [];
  groups.forEach((g, gi) => { if (g.c) rows.push({ head: g.c, color: CAT_COLORS[gi % CAT_COLORS.length] }); for (const t of g.list) rows.push({ t, color: CAT_COLORS[gi % CAT_COLORS.length] }); });
  const cols = rows.length > 12 ? 2 : 1, per = Math.ceil(rows.length / cols), rh = Math.min(56, (H - 190) / per), cw = (W - 96) / cols;
  rows.forEach((row, i) => {
    const c = Math.floor(i / per), x = 48 + c * cw, y = 196 + (i % per) * rh;
    if (row.head) {
      ctx.fillStyle = row.color; circle(ctx, x + 10, y - 10, 8); ctx.fill();
      ctx.fillStyle = N.muted; ctx.font = '600 26px ' + FONT_SANS; ctx.textAlign = 'left'; ctx.fillText(row.head, x + 28, y);
      return;
    }
    const t = row.t, on = d.chart === t.i;
    if (on) { ctx.fillStyle = N.sel; rrect(ctx, x - 8, y - 36, cw - 16, rh - 4, 7); ctx.fill(); ctx.strokeStyle = N.accent; ctx.lineWidth = 2; ctx.stroke(); }
    ctx.fillStyle = row.color; ctx.fillRect(x + 4, y - 26, 4, 28);
    ctx.fillStyle = N.text; ctx.textAlign = 'left';
    const lab = fit(ctx, t.label, '600', FONT_SANS, 32, 22, cw * 0.6);
    ctx.font = '600 ' + lab.px + 'px ' + FONT_SANS; ctx.fillText(lab.text, x + 22, y);
    if (t.conns) {
      ctx.textAlign = 'right'; ctx.fillStyle = N.muted;
      const m = fit(ctx, fmtN(t.conns) + (cols > 1 ? '' : ' connections'), '500', FONT_SANS, 28, 18, cw * 0.36);
      ctx.font = '500 ' + m.px + 'px ' + FONT_SANS; ctx.fillText(m.text, x + cw - 24, y);
    }
    hits.push({ x: x - 8, y: y - 38, w: cw - 16, h: rh, act: { kind: 'test', i: t.i }, tip: on ? 'Click to push the drawers back in' : 'Click to pull every drawer out by ' + t.label });
  });
  return hits;
}
function nocMachine(cv, N, d) {
  const ctx = cv.getContext('2d'), W = cv.width, H = cv.height;
  const m = d.machine;
  nocBase(ctx, W, H, N, 'Test machine', m ? 'Every entry ran on this one box.' : '');
  if (!m) { ctx.fillStyle = N.muted; ctx.font = '500 32px ' + FONT_SANS; ctx.textAlign = 'left'; ctx.fillText('No machine details for this view.', 48, 260); return; }
  ctx.textAlign = 'left'; ctx.fillStyle = N.text;
  const f = fit(ctx, String(m.cpu || 'CPU'), '650', FONT_SANS, 46, 26, W - 96);
  ctx.font = '650 ' + f.px + 'px ' + FONT_SANS; ctx.fillText(f.text, 48, 220);
  const cells = [[m.cores != null ? fmtN(m.cores) : '-', 'cores'], [m.threads != null ? fmtN(m.threads) : '-', 'threads'], [String(m.ram || '-').replace(/Gi$/, ' GiB'), 'memory']];
  const cw = (W - 96) / 3;
  cells.forEach(([v, l], i) => {
    const x = 48 + i * cw;
    ctx.fillStyle = N.text; ctx.font = '700 80px ' + FONT_SANS; ctx.fillText(v, x, 350);
    ctx.fillStyle = N.muted; ctx.font = '500 30px ' + FONT_SANS; ctx.fillText(l, x + 4, 392);
  });
  ctx.strokeStyle = N.line; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(48, 440); ctx.lineTo(W - 48, 440); ctx.stroke();
  const rows = [['Operating system', m.os], ['Kernel', m.kernel]].filter(r => r[1]);
  rows.forEach(([k, v], i) => {
    const y = 510 + i * 64;
    ctx.fillStyle = N.muted; ctx.font = '500 30px ' + FONT_SANS; ctx.fillText(k, 48, y);
    ctx.fillStyle = N.text; ctx.font = '600 32px ' + FONT_SANS; ctx.textAlign = 'right'; ctx.fillText(fit(ctx, String(v), '600', FONT_SANS, 32, 20, W - 520).text, W - 48, y); ctx.textAlign = 'left';
  });
}
function nocSel(cv, N, P, d) {
  const ctx = cv.getContext('2d'), W = cv.width, H = cv.height, u = d.sel;
  nocBase(ctx, W, H, N, u ? u.fw : 'Selected entry', u ? '#' + u.rank + '  ·  ' + [u.lang, TYPE_NAMES[u.type], u.engine && u.engine.toLowerCase() !== u.fw.toLowerCase() ? 'on ' + u.engine : ''].filter(Boolean).join('  ·  ') : 'Point at a unit, or open one, to see it here.');
  if (!u) return;
  ctx.textAlign = 'left';
  ctx.fillStyle = N.muted; ctx.font = '500 28px ' + FONT_SANS; ctx.fillText(d.metric, 48, 196);
  ctx.fillStyle = N.bar; ctx.font = '700 74px ' + FONT_SEG; ctx.fillText(String(u.score || '-'), 48, 286);
  ctx.fillStyle = N.text; ctx.font = '600 30px ' + FONT_SANS; ctx.fillText(Math.round(u.share * 100) + '% of the leader', 48, 334);
  const facts = [['CPU', u.cpu != null ? fmtN(u.cpu) + '%' : '-'], ['Memory', u.mem != null ? fmtMem(u.mem) : '-'], ['p99', u.p99 != null ? fmtMs(u.p99) : '-'], ['Throughput', u.rps != null ? fmtRps(u.rps) + ' req/s' : '-'], ['Errors', u.errors != null ? fmtN(u.errors) : '-']];
  facts.forEach(([k, v], i) => {
    const y = 404 + i * 52;
    ctx.fillStyle = N.muted; ctx.font = '500 28px ' + FONT_SANS; ctx.textAlign = 'left'; ctx.fillText(k, 48, y);
    ctx.fillStyle = N.text; ctx.font = '600 30px ' + FONT_SANS; ctx.textAlign = 'right'; ctx.fillText(v, 560, y);
  });
  const st = u.strength || {};
  STRENGTH.forEach(([k, name], i) => {
    const y = 214 + i * 92, x = 640, v = num(st[k]);
    ctx.textAlign = 'left'; ctx.fillStyle = N.muted; ctx.font = '500 28px ' + FONT_SANS; ctx.fillText(name, x, y);
    ctx.textAlign = 'right'; ctx.fillStyle = N.text; ctx.font = '700 30px ' + FONT_SANS; ctx.fillText(v == null ? 'n/a' : fmtN(v), W - 48, y);
    ctx.fillStyle = N.line; rrect(ctx, x, y + 16, W - 48 - x, 16, 8); ctx.fill();
    if (v != null) { ctx.fillStyle = rampCss(P.ramp, v / 100); rrect(ctx, x, y + 16, Math.max(16, (W - 48 - x) * clamp01(v / 100)), 16, 8); ctx.fill(); }
  });
}

const easeIn = t => t * t * t;
/* ── the corridor's signs, kiosks and boards ───────────────────────────── */
// wrap a text into at most n lines of a width, the last one cut short
function wrapLines(ctx, text, width, n) {
  const words = String(text || '').split(/\s+/).filter(Boolean), out = [];
  let line = '';
  for (let i = 0; i < words.length; i++) {
    const w = line ? line + ' ' + words[i] : words[i];
    if (ctx.measureText(w).width <= width || !line) { line = w; continue; }
    out.push(line); line = words[i];
    if (out.length === n - 1) { line = words.slice(i).join(' '); break; }
  }
  if (line) out.push(line);
  if (out.length > n) out.length = n;
  const last = out.length - 1;
  if (last >= 0 && ctx.measureText(out[last]).width > width) {
    let t = out[last];
    while (t.length > 1 && ctx.measureText(t + '…').width > width) t = t.slice(0, -1);
    out[last] = t.replace(/\s+$/, '') + '…';
  }
  return out;
}
const plural = (n, one, many) => n + ' ' + (n === 1 ? one : many || one + 's');
function secSignTexture(P, S, k = 1) {
  const W = 1280, H = 288, c = canvas(W * k, H * k), x = c.getContext('2d'); x.scale(k, k);
  x.fillStyle = P.sign; x.fillRect(0, 0, W, H);
  x.fillStyle = S.color; rrect(x, 18, 18, 372, H - 36, 16); x.fill();
  let f = fit(x, S.label, '700', FONT_LABEL, 150, 54, 330);
  x.font = '700 ' + f.px + 'px ' + FONT_LABEL; x.textAlign = 'center'; x.fillStyle = '#0b0f14';
  x.fillText(f.text, 204, centreY(x, f.text, H / 2));
  x.textAlign = 'left';
  f = fit(x, S.name || S.label, '650', FONT_SANS, 62, 32, W - 460);
  x.font = '650 ' + f.px + 'px ' + FONT_SANS; x.fillStyle = P.signText; x.fillText(f.text, 424, 124);
  const lead = S.units[0];
  const sub = [plural(S.units.length, 'entry', 'entries'), plural(S.nT, 'test'), plural(S.nR, 'rack'), lead ? 'leader ' + lead.fw : ''].filter(Boolean).join('  ·  ');
  f = fit(x, sub, '500', FONT_SANS, 40, 24, W - 460);
  x.font = '500 ' + f.px + 'px ' + FONT_SANS; x.fillStyle = P.signMuted; x.fillText(f.text, 424, 190);
  x.fillStyle = S.color; x.fillRect(424, 228, W - 462, 6);
  return c;
}
function laneTexture(P, S, k = 1) {
  const W = 1024, H = 256, c = canvas(W * k, H * k), x = c.getContext('2d'); x.scale(k, k);
  x.clearRect(0, 0, W, H);
  x.fillStyle = S.color;
  const f = fit(x, S.label, '700', FONT_LABEL, 132, 60, 470);
  x.font = '700 ' + f.px + 'px ' + FONT_LABEL; x.textAlign = 'left';
  x.fillText(f.text, 24, 168);
  const w = x.measureText(f.text).width;
  if (S.name) {
    const g = fit(x, S.name, '600', FONT_SANS, 46, 26, W - w - 90);
    x.font = '600 ' + g.px + 'px ' + FONT_SANS; x.globalAlpha = 0.85; x.fillText(g.text, w + 60, 160); x.globalAlpha = 1;
  }
  return c;
}
function rankBadge(x, k, cx, cy, s, N) {
  const pl = RANK_PLATES[k];
  if (pl) {
    const g = x.createLinearGradient(cx - s / 2, cy - s / 2, cx + s / 2, cy + s / 2);
    g.addColorStop(0, pl[0]); g.addColorStop(0.55, pl[1]); g.addColorStop(1, pl[2]);
    x.fillStyle = g; rrect(x, cx - s / 2, cy - s / 2, s, s, s * 0.16); x.fill();
    x.fillStyle = pl[3];
  } else {
    x.fillStyle = N.card; rrect(x, cx - s / 2, cy - s / 2, s, s, s * 0.16); x.fill();
    x.strokeStyle = N.line; x.lineWidth = 2; x.stroke();
    x.fillStyle = N.muted;
  }
  x.font = '700 ' + Math.round(s * 0.5) + 'px ' + FONT_SANS; x.textAlign = 'center';
  x.fillText(String(k), cx, centreY(x, '0', cy));
}
function kioskTexture(P, S, world, k = 1) {
  const N = P.noc, W = 640, H = 1080, c = canvas(W * k, H * k), x = c.getContext('2d'); x.scale(k, k);
  x.fillStyle = N.bg; x.fillRect(0, 0, W, H);
  x.fillStyle = S.color; x.fillRect(0, 0, W, 12);
  x.textAlign = 'left'; x.fillStyle = N.text;
  let f = fit(x, S.label, '700', FONT_LABEL, 92, 40, W - 80);
  x.font = '700 ' + f.px + 'px ' + FONT_LABEL; x.fillText(f.text, 38, 112);
  x.font = '600 32px ' + FONT_SANS; x.fillStyle = N.text;
  wrapLines(x, S.name || '', W - 76, 2).forEach((l, i) => x.fillText(l, 38, 166 + i * 40));
  // three numbers
  const stats = [['Entries', S.units.length], ['Tests', S.nT], ['Racks', S.nR]];
  const cw = (W - 76 - 24) / 3;
  stats.forEach(([k, v], i) => {
    const cx = 38 + i * (cw + 12);
    x.fillStyle = N.card; rrect(x, cx, 244, cw, 112, 12); x.fill();
    x.strokeStyle = N.line; x.lineWidth = 2; x.stroke();
    x.fillStyle = N.text; x.font = '700 50px ' + FONT_SANS; x.fillText(String(v), cx + 18, 306);
    x.fillStyle = N.muted; x.font = '500 24px ' + FONT_SANS; x.fillText(k, cx + 18, 340);
  });
  x.fillStyle = N.muted; x.font = '500 25px ' + FONT_SANS;
  x.fillText(fit(x, 'Ranked by ' + S.metric.toLowerCase() + ', best first', '500', FONT_SANS, 25, 18, W - 76).text, 38, 398);
  // the top three
  x.fillStyle = N.text; x.font = '650 30px ' + FONT_SANS; x.fillText('Top three', 38, 458);
  S.units.slice(0, 3).forEach((u, k) => {
    const y = 482 + k * 104;
    x.fillStyle = N.card; rrect(x, 38, y, W - 76, 92, 12); x.fill();
    rankBadge(x, k + 1, 84, y + 46, 54, N);
    x.textAlign = 'left';
    const nf = fit(x, u.fw, '650', FONT_LABEL, 34, 20, W - 330);
    x.font = '650 ' + nf.px + 'px ' + FONT_LABEL; x.fillStyle = N.text; x.fillText(nf.text, 128, y + 42);
    x.fillStyle = u.langColor; rrect(x, 128, y + 58, 14, 14, 3); x.fill();
    x.fillStyle = N.muted; x.font = '500 22px ' + FONT_SANS; x.fillText(u.lang || '', 150, y + 72);
    x.textAlign = 'right'; x.fillStyle = N.text; x.font = '700 32px ' + FONT_SANS;
    x.fillText(u.score || '', W - 58, y + 44);
    x.fillStyle = N.line; x.fillRect(W - 228, y + 62, 170, 8);
    x.fillStyle = S.color; x.fillRect(W - 228, y + 62, 170 * clamp01(u.share), 8);
    x.textAlign = 'left';
  });
  // its languages
  let y = 818;
  x.fillStyle = N.text; x.font = '650 30px ' + FONT_SANS; x.fillText('Languages', 38, y);
  const langs = S.langs.slice(0, 4), lmax = Math.max(1, ...langs.map(l => l.n));
  langs.forEach((l, i) => {
    const ly = y + 22 + i * 40;
    x.fillStyle = l.color; rrect(x, 38, ly + 6, 14, 14, 3); x.fill();
    x.fillStyle = N.text; x.font = '500 24px ' + FONT_SANS; x.fillText(fit(x, l.name, '500', FONT_SANS, 24, 16, 150).text, 62, ly + 21);
    x.fillStyle = N.line; x.fillRect(222, ly + 8, W - 330, 12);
    x.fillStyle = l.color; x.fillRect(222, ly + 8, (W - 330) * l.n / lmax, 12);
    x.fillStyle = N.muted; x.textAlign = 'right'; x.fillText(String(l.n), W - 38, ly + 21); x.textAlign = 'left';
  });
  x.fillStyle = N.muted; x.font = '500 22px ' + FONT_SANS;
  x.fillText(fit(x, (S.nR > 1 ? 'Racks R1–R' + S.nR + ' in a row on the left' : 'Rack R1 on the left') + ', rank 1 at the top of R1', '500', FONT_SANS, 22, 16, W - 76).text, 38, H - 34);
  return c;
}
function boardHead(x, N, W, title, sub, right) {
  x.fillStyle = N.bg; x.fillRect(0, 0, W, 2000);
  x.fillStyle = N.accent; x.fillRect(0, 0, W, 10);
  x.textAlign = 'left'; x.fillStyle = N.text; x.font = '700 76px ' + FONT_LABEL; x.fillText(title, 64, 120);
  if (sub) { x.fillStyle = N.muted; x.font = '500 34px ' + FONT_SANS; x.fillText(fit(x, sub, '500', FONT_SANS, 34, 22, W - 640).text, 64, 176); }
  if (right) { x.textAlign = 'right'; x.fillStyle = N.muted; x.font = '500 34px ' + FONT_SANS; x.fillText(right, W - 64, 112); x.textAlign = 'left'; }
}
function overallTexture(P, list, world, SECS, k = 1) {
  const N = P.noc, W = 2048, H = 1152, c = canvas(W * k, H * k), x = c.getContext('2d'); x.scale(k, k);
  list = (Array.isArray(list) ? list : []).filter(e => e && e.fw != null).slice(0, 10);
  boardHead(x, N, W, 'Overall', 'The top ten across ' + plural(SECS.length, 'section') + ': ' + SECS.map(S => S.label).join(', '), world.round ? String(world.round) : '');
  if (!list.length) {
    x.fillStyle = N.muted; x.font = '500 40px ' + FONT_SANS; x.fillText('No overall ranking for this view. Walk on for each section\'s own.', 64, 320);
    return c;
  }
  const smax = Math.max(1e-9, ...list.map(e => clamp01(+e.share || 0)));
  list.forEach((e, i) => {
    const y = 214 + i * 92, rk = e.rank != null ? +e.rank : i + 1;
    if (i % 2 === 0) { x.fillStyle = N.card; x.fillRect(40, y, W - 80, 88); }
    rankBadge(x, rk, 108, y + 44, 62, N);
    x.textAlign = 'left';
    const nf = fit(x, String(e.fw), '650', FONT_LABEL, 50, 28, 760);
    x.font = '650 ' + nf.px + 'px ' + FONT_LABEL; x.fillStyle = N.text; x.fillText(nf.text, 170, y + 60);
    x.fillStyle = e.langColor || '#8b96a3'; rrect(x, 960, y + 30, 22, 22, 4); x.fill();
    x.fillStyle = N.muted; x.font = '500 34px ' + FONT_SANS; x.fillText(fit(x, e.lang || '', '500', FONT_SANS, 34, 20, 210).text, 996, y + 54);
    const bx = 1236, bw = 480, sh = clamp01(+e.share || 0) / smax;
    x.fillStyle = N.line; x.fillRect(bx, y + 36, bw, 16);
    x.fillStyle = N.bar; x.fillRect(bx, y + 36, bw * sh, 16);
    x.textAlign = 'right'; x.fillStyle = N.text; x.font = '700 46px ' + FONT_SANS;
    x.fillText(e.score != null ? String(e.score) : '', W - 64, y + 60);
  });
  x.textAlign = 'left';
  return c;
}
function machineTexture(P, m, SECS, world, k = 1) {
  const N = P.noc, W = 2048, H = 1152, c = canvas(W * k, H * k), x = c.getContext('2d'); x.scale(k, k);
  boardHead(x, N, W, 'The test machine', m ? 'Every entry ran on the same box' : 'No machine details for this view', '');
  const rows = m ? [['CPU', m.cpu], ['Cores', m.cores != null ? m.cores + (m.threads != null ? ' cores, ' + m.threads + ' threads' : ' cores') : null], ['Memory', m.ram], ['System', m.os], ['Kernel', m.kernel]].filter(r => r[1] != null && r[1] !== '') : [];
  rows.forEach(([k, v], i) => {
    const y = 270 + i * 120;
    x.fillStyle = N.muted; x.font = '500 34px ' + FONT_SANS; x.fillText(k, 64, y);
    const f = fit(x, String(v), '650', FONT_SANS, 50, 28, 860);
    x.fillStyle = N.text; x.font = '650 ' + f.px + 'px ' + FONT_SANS; x.fillText(f.text, 64, y + 58);
  });
  // the corridor, in order
  const X = 1060;
  x.fillStyle = N.line; x.fillRect(X - 50, 230, 3, H - 300);
  x.fillStyle = N.text; x.font = '650 44px ' + FONT_SANS; x.fillText('Down the corridor', X, 262);
  const step = Math.min(118, (H - 420) / Math.max(1, SECS.length));
  SECS.forEach((S, i) => {
    const y = 300 + i * step;
    x.fillStyle = S.color; rrect(x, X, y + 6, 120, step - 28, 10); x.fill();
    x.fillStyle = '#0b0f14'; x.textAlign = 'center';
    const lf = fit(x, S.label, '700', FONT_LABEL, 40, 20, 108); x.font = '700 ' + lf.px + 'px ' + FONT_LABEL;
    x.fillText(lf.text, X + 60, centreY(x, lf.text, y + 6 + (step - 28) / 2));
    x.textAlign = 'left';
    const nf = fit(x, S.name || S.label, '600', FONT_SANS, 38, 22, W - X - 220);
    x.fillStyle = N.text; x.font = '600 ' + nf.px + 'px ' + FONT_SANS; x.fillText(nf.text, X + 148, y + 44);
    x.fillStyle = N.muted; x.font = '500 30px ' + FONT_SANS;
    x.fillText(plural(S.units.length, 'entry', 'entries') + ' · ' + plural(S.nT, 'test') + (S.units[0] ? ' · leader ' + S.units[0].fw : ''), X + 148, y + 82);
  });
  x.fillStyle = N.muted; x.font = '500 30px ' + FONT_SANS;
  x.fillText('Then the podium and the operations wall at the far end.', X, 300 + SECS.length * step + 30);
  return c;
}
function benchSignTexture(P) {
  const W = 768, H = 256, c = canvas(W, H), x = c.getContext('2d');
  x.fillStyle = P.sign; rrect(x, 0, 0, W, H, 18); x.fill();
  x.fillStyle = P.signLine; x.fillRect(0, 0, W, 8);
  x.fillStyle = P.signText; x.textAlign = 'left'; x.font = '700 64px ' + FONT_LABEL; x.fillText('Comparison bench', 36, 102);
  x.fillStyle = P.signMuted; x.font = '500 30px ' + FONT_SANS;
  wrapLines(x, 'Shift+click a unit, or press Compare on its card, to bring up to four here side by side.', W - 72, 2).forEach((l, i) => x.fillText(l, 36, 158 + i * 40));
  return c;
}
// the letter a compared unit wears on its front and its tag
function tagTexture(color, letter) {
  const c = canvas(128, 128), x = c.getContext('2d');
  x.fillStyle = color; rrect(x, 4, 4, 120, 120, 22); x.fill();
  x.fillStyle = 'rgba(255,255,255,.35)'; x.fillRect(14, 10, 100, 4);
  x.fillStyle = '#0b0f14'; x.font = '800 92px ' + FONT_SANS; x.textAlign = 'center';
  x.fillText(letter, 64, centreY(x, letter, 66));
  return c;
}
// the bench's hologram: every unit's strength on one pentagon, an outline in its colour
function drawHoloCompare(cv, list, P) {
  const ctx = cv.getContext('2d'), W = cv.width, H = cv.height;
  ctx.clearRect(0, 0, W, H);
  const col = P.holo;
  ctx.fillStyle = P.holoAdd ? 'rgba(2,10,16,0.8)' : 'rgba(255,255,255,0.9)'; rrect(ctx, 6, 6, W - 12, H - 12, 30); ctx.fill();
  ctx.strokeStyle = col; ctx.globalAlpha = 0.7; ctx.lineWidth = 3; rrect(ctx, 6, 6, W - 12, H - 12, 30); ctx.stroke(); ctx.globalAlpha = 1;
  ctx.textAlign = 'center'; ctx.fillStyle = col; ctx.strokeStyle = col;
  ctx.font = '700 44px ' + FONT_LABEL; ctx.fillText('Strength, of 100', W / 2, 64);
  const cx = W / 2, cy = H * 0.52, R = W * 0.26;
  const pt = (i, k) => { const a = -Math.PI / 2 + i * 2 * Math.PI / 5; return [cx + Math.cos(a) * R * k, cy + Math.sin(a) * R * k]; };
  ctx.lineWidth = 2;
  for (const k of [0.25, 0.5, 0.75, 1]) {
    ctx.globalAlpha = k === 1 ? 0.55 : 0.2; ctx.beginPath();
    for (let i = 0; i < 5; i++) { const [x, y] = pt(i, k); i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }
    ctx.closePath(); ctx.stroke();
  }
  for (let i = 0; i < 5; i++) { const [x, y] = pt(i, 1); ctx.globalAlpha = 0.28; ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(x, y); ctx.stroke(); }
  ctx.globalAlpha = 1;
  for (const e of list) {
    const st = e.u.strength || {}, vals = STRENGTH.map(([k]) => num(st[k]));
    if (!vals.some(v => v != null)) continue;
    ctx.strokeStyle = e.color; ctx.fillStyle = e.color;
    ctx.beginPath();
    vals.forEach((v, i) => { const [x, y] = pt(i, clamp01((v || 0) / 100)); i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); });
    ctx.closePath(); ctx.globalAlpha = 0.12; ctx.fill(); ctx.globalAlpha = 1; ctx.lineWidth = 5; ctx.stroke();
    vals.forEach((v, i) => { if (v == null) return; const [x, y] = pt(i, clamp01(v / 100)); circle(ctx, x, y, 7); ctx.fill(); });
  }
  ctx.fillStyle = col;
  STRENGTH.forEach(([k, name], i) => {
    const [x, y] = pt(i, 1.2);
    ctx.font = '600 26px ' + FONT_SANS; ctx.fillText(name === 'Spec and resilience' ? 'Spec, resilience' : name, x, y + 8);
  });
  // the legend: each letter, its name
  const n = list.length, lw = (W - 80) / Math.max(1, n);
  list.forEach((e, i) => {
    const x = 40 + i * lw, y = H - 74;
    ctx.fillStyle = e.color; rrect(ctx, x, y - 30, 40, 40, 8); ctx.fill();
    ctx.fillStyle = '#0b0f14'; ctx.font = '800 28px ' + FONT_SANS; ctx.textAlign = 'center'; ctx.fillText(e.letter, x + 20, y - 1);
    ctx.textAlign = 'left'; ctx.fillStyle = col;
    const f = fit(ctx, e.u.fw, '600', FONT_SANS, 28, 16, lw - 62); ctx.font = '600 ' + f.px + 'px ' + FONT_SANS; ctx.fillText(f.text, x + 50, y - 1);
  });
}
function keyboardTexture(P) {
  const c = canvas(512, 160), x = c.getContext('2d');
  x.fillStyle = '#15191e'; x.fillRect(0, 0, 512, 160);
  x.fillStyle = '#2a3038';
  for (let r = 0; r < 5; r++) for (let i = 0; i < 15; i++) { const w = r === 4 && i === 5 ? 6 : 1; if (r === 4 && i > 5 && i < 11) continue; rrect(x, 10 + i * 33, 10 + r * 29, 29 * w + (w - 1) * 4, 25, 4); x.fill(); }
  return c;
}

/* ── a light syntax highlighter: comments, strings, numbers, keywords ──── */
const KW_C = 'auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while NULL true false bool';
const KW_JS = 'async await break case catch class const continue debugger default delete do else export extends false finally for from function if import in instanceof let new null of return static super switch this throw true try typeof undefined var void while with yield';
const KW_PY = 'and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield match case self';
const KW = {
  rust: 'as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while',
  go: 'break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false iota',
  csharp: 'abstract as async await base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly record ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using var virtual void volatile while yield get set init required',
  java: 'abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new null package private protected public return short static strictfp super switch synchronized this throw throws transient true false try var void volatile while record',
  kotlin: 'as break class continue do else false for fun if in interface is null object package return super this throw true try typealias val var when while by companion const data enum inline internal lateinit open override private protected public sealed suspend import',
  scala: 'abstract case catch class def do else extends false final finally for if implicit import lazy match new null object override package private protected return sealed super this throw trait try true type val var while with yield given using then enum',
  js: KW_JS, ts: KW_JS + ' interface type enum implements namespace declare abstract private protected public readonly as any number string boolean unknown never keyof',
  python: KW_PY, mojo: KW_PY + ' fn struct var let alias inout owned borrowed raises trait',
  ruby: 'alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require require_relative attr_reader attr_accessor',
  crystal: 'abstract alias annotation as begin break case class def do else elsif end ensure enum extend false for fun if in include lib macro module next nil of private protected require rescue return self struct super then true type typeof unless until when while with yield',
  php: 'abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty extends final finally fn for foreach function global goto if implements include include_once instanceof interface isset list match namespace new null or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield true false',
  elixir: 'after alias and catch cond def defmodule defp defstruct defmacro do else end false fn for if import in nil not or quote raise receive require rescue true try unless unquote use when with',
  erlang: 'after and andalso band begin bnot bor bsl bsr bxor case catch cond div end fun if let not of or orelse receive rem try when xor',
  zig: 'align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while true false null undefined',
  c: KW_C,
  cpp: KW_C + ' alignas alignof asm catch class concept constexpr consteval co_await co_return co_yield decltype delete explicit export friend mutable namespace new noexcept nullptr operator override private protected public requires static_assert template this thread_local throw try typeid typename using virtual',
  swift: 'actor as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate for func guard if import in init inout internal is let nil open operator private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var where while',
  dart: 'abstract as assert async await break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory false final finally for Function get if implements import in interface is late library mixin new null on operator part required rethrow return set show static super switch sync this throw true try typedef var void while with yield',
  haskell: 'case class data default deriving do else family forall foreign if import in infix infixl infixr instance let module newtype of qualified then type where',
  ocaml: 'and as assert begin class constraint do done downto else end exception external false for fun function functor if in include inherit initializer lazy let match method module mutable new nonrec object of open or private rec sig struct then to true try type val virtual when while with',
  fsharp: 'abstract and as assert base begin class default delegate do done downcast downto elif else end exception extern false finally fixed for fun function global if in inherit inline interface internal lazy let match member module mutable namespace new not null of open or override private public rec return static struct then to true try type upcast use val void when while with yield async task',
  clojure: 'def defn defn- defmacro defrecord defprotocol deftype fn let letfn if if-let when when-let cond case do loop recur try catch finally throw ns require import quote nil true false and or not',
  nim: 'addr and as asm bind block break case cast concept const continue converter defer discard distinct div do elif else end enum except export finally for from func if import in include interface is isnot iterator let macro method mixin mod nil not notin object of or out proc ptr raise ref return shl shr static template try tuple type using var when while xor yield true false',
  d: 'abstract alias align asm assert auto bool break byte case cast catch char class const continue debug default delegate do double else enum export extern false final finally float for foreach function goto if immutable import in inout int interface invariant is lazy long mixin module new nothrow null out override package pragma private protected public pure real ref return scope shared short static struct super switch synchronized template this throw true try typeid typeof uint ulong union unittest ushort version void while with',
  julia: 'abstract baremodule begin break catch const continue do else elseif end export false finally for function global if import let local macro module mutable primitive quote return struct true try type using while',
  lua: 'and break do else elseif end false for function goto if in local nil not or repeat return then true until while',
  perl: 'my our local sub if elsif else unless while until for foreach last next redo return use no package require do eval and or not',
  v: 'as asm assert atomic break const continue defer else enum false fn for go goto if import in interface is lock match module mut none or pub return rlock select shared sizeof static struct true type typeof union unsafe volatile',
  docker: 'FROM RUN CMD LABEL MAINTAINER EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS',
  shell: 'if then else elif fi for while until do done case esac function in select return exit export local readonly set unset source echo cd exec',
  make: 'ifeq ifneq ifdef ifndef else endif include define endef export override',
  cmake: 'if else elseif endif foreach endforeach while endwhile function endfunction macro endmacro set project cmake_minimum_required add_executable add_library target_link_libraries target_include_directories target_compile_options find_package include option',
  gradle: 'plugins dependencies repositories implementation testImplementation api id version group application mainClass tasks val var fun',
  toml: 'true false', yaml: 'true false null yes no on off', json: 'true false null',
};
const kwSets = {};
const kwOf = lang => kwSets[lang] || (kwSets[lang] = new Set((KW[lang] || '').split(' ').filter(Boolean)));
const CL = { line: ['//'], block: [['/*', '*/']], q: '"\'', types: 1, calls: 1 };
const HL = {
  rust: Object.assign({}, CL, { life: 1, macro: 1, attr: 1 }), go: Object.assign({}, CL, { q: '"\'`' }), csharp: Object.assign({}, CL, { verb: 1, deco: 1 }),
  java: Object.assign({}, CL, { deco: 1, triple: ['"""'] }), kotlin: Object.assign({}, CL, { deco: 1, triple: ['"""'] }), scala: Object.assign({}, CL, { deco: 1, triple: ['"""'] }),
  swift: Object.assign({}, CL, { deco: 1, triple: ['"""'] }), dart: Object.assign({}, CL, { deco: 1, triple: ['"""', "'''"] }),
  js: Object.assign({}, CL, { q: '"\'`', deco: 1 }), ts: Object.assign({}, CL, { q: '"\'`', deco: 1 }),
  c: Object.assign({}, CL, { pre: 1 }), cpp: Object.assign({}, CL, { pre: 1 }), d: CL, v: CL, gradle: CL,
  zig: Object.assign({}, CL, { block: [], deco: 1 }),
  php: Object.assign({}, CL, { line: ['//', '#'], vars: '$' }),
  python: { line: ['#'], q: '"\'', triple: ['"""', "'''"], deco: 1, types: 1, calls: 1 }, mojo: { line: ['#'], q: '"\'', triple: ['"""', "'''"], deco: 1, types: 1, calls: 1 },
  ruby: { line: ['#'], q: '"\'', sym: 1, types: 1, calls: 1, vars: '@$' }, crystal: { line: ['#'], q: '"\'', sym: 1, types: 1, calls: 1, vars: '@' },
  elixir: { line: ['#'], q: '"\'', triple: ['"""'], sym: 1, types: 1, calls: 1, deco: 1 },
  erlang: { line: ['%'], q: '"\'', types: 1, calls: 1 },
  haskell: { line: ['--'], block: [['{-', '-}']], q: '"\'', types: 1, prime: 1 },
  ocaml: { block: [['(*', '*)']], q: '"\'', types: 1, prime: 1 }, fsharp: { line: ['//'], block: [['(*', '*)']], q: '"\'', triple: ['"""'], types: 1, prime: 1 },
  clojure: { line: [';'], q: '"', lisp: 1, sym: 1 },
  nim: { line: ['#'], block: [['#[', ']#']], q: '"\'', triple: ['"""'], types: 1, calls: 1 },
  julia: { line: ['#'], block: [['#=', '=#']], q: '"\'', triple: ['"""'], types: 1, calls: 1, deco: 1 },
  lua: { line: ['--'], block: [['--[[', ']]']], q: '"\'', calls: 1 },
  perl: { line: ['#'], q: '"\'', vars: '$@%', calls: 1 },
  shell: { line: ['#'], q: '"\'`', vars: '$' }, docker: { line: ['#'], q: '"\'', vars: '$', upper: 1 }, make: { line: ['#'], q: '"\'', vars: '$', target: 1 },
  cmake: { line: ['#'], q: '"', vars: '$', calls: 1, nocase: 1 },
  toml: { line: ['#'], q: '"\'', triple: ['"""', "'''"], keys: '=', sect: 1 }, yaml: { line: ['#'], q: '"\'', keys: ':' }, json: { q: '"', jkeys: 1 },
  text: {},
};
const IDC = /[A-Za-z0-9_$]/;
function lexCode(src, lang) {
  const H = HL[lang] || HL.text, kw = kwOf(lang), out = [];
  const n = src.length;
  let i = 0, plain = '', lineStart = true;
  const flush = () => { if (plain) { out.push(['', plain]); plain = ''; } };
  const emit = (cls, s) => { if (!s) return; if (!cls) { plain += s; return; } flush(); out.push([cls, s]); };
  const nextNon = j => { while (j < n && (src[j] === ' ' || src[j] === '\t')) j++; return src[j]; };
  const strTo = (j, q) => { j += q.length; while (j < n) { const ch = src[j]; if (ch === '\\') { j += 2; continue; } if (src.startsWith(q, j)) return j + q.length; if (ch === '\n' && q.length === 1 && q !== '`') return j; j++; } return n; };
  while (i < n) {
    const ch = src[i];
    if (ch === '\n') { emit('', '\n'); i++; lineStart = true; continue; }
    if (ch === ' ' || ch === '\t' || ch === '\r') { let j = i + 1; while (j < n && (src[j] === ' ' || src[j] === '\t' || src[j] === '\r')) j++; emit('', src.slice(i, j)); i = j; continue; }
    const wasStart = lineStart; lineStart = false;
    if (H.keys && wasStart && ch === '-' && src[i + 1] === ' ') { emit('g', '-'); i++; lineStart = true; continue; }
    // comments: blocks first (a Lua block starts like its line comment)
    let hit = false;
    for (const [a, b] of (H.block || [])) if (src.startsWith(a, i)) { const e = src.indexOf(b, i + a.length); const j = e < 0 ? n : e + b.length; emit('c', src.slice(i, j)); i = j; hit = true; break; }
    if (hit) continue;
    for (const a of (H.line || [])) if (src.startsWith(a, i) && !(a === '#' && H.attr && src[i + 1] === '[')) { let j = src.indexOf('\n', i); if (j < 0) j = n; emit('c', src.slice(i, j)); i = j; hit = true; break; }
    if (hit) continue;
    // attributes, decorators, the preprocessor
    if (H.attr && ch === '#' && (src[i + 1] === '[' || (src[i + 1] === '!' && src[i + 2] === '['))) { let j = src.indexOf(']', i); j = j < 0 ? n : j + 1; emit('m', src.slice(i, j)); i = j; continue; }
    if (H.pre && ch === '#' && wasStart) { const m = /^#\s*\w+/.exec(src.slice(i, i + 40)); if (m) { emit('m', m[0]); i += m[0].length; if (nextNon(i) === '<') { const a = src.indexOf('<', i), b = src.indexOf('>', a); if (b > a && src.slice(a, b).indexOf('\n') < 0) { emit('', src.slice(i, a)); emit('s', src.slice(a, b + 1)); i = b + 1; } } continue; } }
    if (H.deco && ch === '@' && /[A-Za-z_]/.test(src[i + 1] || '')) { let j = i + 1; while (j < n && /[\w.]/.test(src[j])) j++; emit('m', src.slice(i, j)); i = j; continue; }
    if (H.verb && ch === '@' && src[i + 1] === '"') { let j = i + 2; while (j < n) { if (src[j] === '"') { if (src[j + 1] === '"') { j += 2; continue; } j++; break; } j++; } emit('s', src.slice(i, j)); i = j; continue; }
    // strings
    if (H.triple) { const t = H.triple.find(q => src.startsWith(q, i)); if (t) { const e = src.indexOf(t, i + 3); const j = e < 0 ? n : e + 3; emit('s', src.slice(i, j)); i = j; continue; } }
    if (H.q && H.q.indexOf(ch) >= 0) {
      if (ch === "'" && (H.life || H.prime)) {
        const m = /^'(\\.[^']*|[^'\\\n])'/.exec(src.slice(i, i + 12));
        if (!m) { let j = i + 1; while (j < n && IDC.test(src[j])) j++; emit(H.life ? 'a' : '', src.slice(i, j)); i = j; continue; }
      }
      if (ch === "'" && H.prime && i > 0 && IDC.test(src[i - 1])) { emit('', ch); i++; continue; }
      const j = strTo(i, ch);
      const s = src.slice(i, j);
      if (H.jkeys && nextNon(j) === ':') emit('a', s); else emit('s', s);
      i = j; continue;
    }
    if (lang === 'rust' && (ch === 'r' || ch === 'b') && /^b?r#*"/.test(src.slice(i, i + 6))) { const m = /^b?r(#*)"/.exec(src.slice(i, i + 8)); const end = '"' + m[1]; const e = src.indexOf(end, i + m[0].length); const j = e < 0 ? n : e + end.length; emit('s', src.slice(i, j)); i = j; continue; }
    // variables: $x, ${x}, $(x)
    if (H.vars && H.vars.indexOf(ch) >= 0 && /[{(\w]/.test(src[i + 1] || '')) {
      let j = i + 1;
      if (src[j] === '{' || src[j] === '(') { const close = src[j] === '{' ? '}' : ')'; const e = src.indexOf(close, j); j = e < 0 || src.slice(j, e).indexOf('\n') >= 0 ? j + 1 : e + 1; }
      else while (j < n && /\w/.test(src[j])) j++;
      emit('t', src.slice(i, j)); i = j; continue;
    }
    // symbols and keywords: :atom
    if (H.sym && ch === ':' && /[A-Za-z_]/.test(src[i + 1] || '') && (i === 0 || !/[\w:]/.test(src[i - 1]))) { let j = i + 1; while (j < n && /[\w?!\-]/.test(src[j])) j++; emit('n', src.slice(i, j)); i = j; continue; }
    // numbers
    if (/[0-9]/.test(ch) || (ch === '.' && /[0-9]/.test(src[i + 1] || '') && !IDC.test(src[i - 1] || ''))) {
      const m = /^(0[xX][\da-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(\.\d[\d_]*)?([eE][+-]?\d+)?|\.\d+)[a-zA-Z_]*/.exec(src.slice(i, i + 40));
      emit('n', m[0]); i += m[0].length; continue;
    }
    // a section header in TOML, a target in a Makefile
    if (H.sect && ch === '[' && wasStart) { let j = src.indexOf('\n', i); if (j < 0) j = n; emit('k', src.slice(i, j)); i = j; continue; }
    // words
    if (/[A-Za-z_$]/.test(ch) || (H.lisp && /[*+!?<>=\/-]/.test(ch))) {
      let j = i + 1;
      const wre = H.lisp ? /[\w*+!?<>=\/\-.]/ : H.keys ? /[\w.\-]/ : /[\w$]/;
      while (j < n && wre.test(src[j])) j++;
      if ((lang === 'ruby' || lang === 'crystal') && (src[j] === '?' || src[j] === '!') && src[j + 1] !== '=') j++;
      const w = src.slice(i, j);
      const nx = nextNon(j);
      let cls = '';
      if (H.keys && wasStart && nx === H.keys[0]) cls = 'a';
      else if (H.target && wasStart && nx === ':' && src[src.indexOf(':', j) + 1] !== '=') cls = 'f';
      else if (H.upper ? wasStart && kw.has(w.toUpperCase()) : H.nocase ? kw.has(w.toLowerCase()) : kw.has(w)) cls = 'k';
      else if (H.macro && src[j] === '!' && src[j + 1] !== '=') { emit('m', w + '!'); i = j + 1; continue; }
      else if (H.lisp && src[i - 1] === '(') cls = 'f';
      else if (H.calls && nx === '(') cls = 'f';
      else if (H.types && /^[A-Z]/.test(w) && /[a-z]/.test(w)) cls = 't';
      emit(cls, w); i = j; continue;
    }
    emit('', ch); i++;
  }
  flush();
  return out;
}
// HTML, XML and templates: tags, attributes, comments, the template's own tags
function lexMarkup(src) {
  const out = [], n = src.length;
  let i = 0;
  const push = (c, s) => { if (s) out.push([c, s]); };
  while (i < n) {
    if (src.startsWith('<!--', i)) { const e = src.indexOf('-->', i); const j = e < 0 ? n : e + 3; push('c', src.slice(i, j)); i = j; continue; }
    if (src.startsWith('{{', i) || src.startsWith('{%', i) || src.startsWith('<%', i)) {
      const close = src[i + 1] === '{' ? '}}' : src[i] === '<' ? '%>' : '%}';
      const e = src.indexOf(close, i + 2); const j = e < 0 ? n : e + 2; push('m', src.slice(i, j)); i = j; continue;
    }
    if (src[i] === '<' && /[A-Za-z!?\/]/.test(src[i + 1] || '')) {
      let j = i + 1; if (src[j] === '/') j++;
      while (j < n && /[^\s>\/]/.test(src[j])) j++;
      push('g', src.slice(i, j)); i = j;
      while (i < n && src[i] !== '>') {
        if (src.startsWith('/>', i)) break;
        if (src[i] === '"' || src[i] === "'") { const q = src[i]; const e = src.indexOf(q, i + 1); const k = e < 0 ? n : e + 1; push('s', src.slice(i, k)); i = k; continue; }
        if (src.startsWith('{{', i) || src.startsWith('{%', i)) { const close = src[i + 1] === '{' ? '}}' : '%}'; const e = src.indexOf(close, i + 2); const k = e < 0 ? n : e + 2; push('m', src.slice(i, k)); i = k; continue; }
        if (/[A-Za-z_:@\-]/.test(src[i])) { let k = i; while (k < n && /[\w:@.\-]/.test(src[k])) k++; push('a', src.slice(i, k)); i = k; continue; }
        push('', src[i]); i++;
      }
      if (src.startsWith('/>', i)) { push('g', '/>'); i += 2; } else if (src[i] === '>') { push('g', '>'); i++; }
      continue;
    }
    let j = i + 1; while (j < n && src[j] !== '<' && src[j] !== '{') j++;
    push('', src.slice(i, j)); i = j;
  }
  return out;
}
function lexMarkdown(src) {
  const out = [];
  let fence = false;
  src.split('\n').forEach((line, k) => {
    if (k) out.push(['', '\n']);
    if (/^\s*(```|~~~)/.test(line)) { fence = !fence; out.push(['m', line]); return; }
    if (fence) { out.push(['s', line]); return; }
    if (/^\s{0,3}#{1,6}\s/.test(line)) { out.push(['k', line]); return; }
    const m = /^(\s*)([-*+]|\d+\.)(\s+)/.exec(line);
    let rest = line;
    if (m) { out.push(['', m[1]]); out.push(['g', m[2]]); out.push(['', m[3]]); rest = line.slice(m[0].length); }
    const re = /(`[^`]+`)|(\[[^\]]+\]\([^)]+\))|(\*\*[^*]+\*\*)/g;
    let last = 0, mm;
    while ((mm = re.exec(rest))) {
      if (mm.index > last) out.push(['', rest.slice(last, mm.index)]);
      out.push([mm[1] ? 's' : mm[2] ? 'f' : 'k', mm[0]]); last = mm.index + mm[0].length;
    }
    if (last < rest.length) out.push(['', rest.slice(last)]);
  });
  return out;
}
// a file's tokens, a line at a time
function highlight(text, lang) {
  const src = String(text || '').replace(/\r\n?/g, '\n');
  let toks;
  try { toks = lang === 'html' || lang === 'xml' ? lexMarkup(src) : lang === 'markdown' ? lexMarkdown(src) : lexCode(src, lang); }
  catch (e) { toks = [['', src]]; }
  const lines = [[]];
  for (const [c, s] of toks) {
    const parts = s.split('\n');
    parts.forEach((p, k) => { if (k) lines.push([]); if (p) lines[lines.length - 1].push([c, p]); });
  }
  return lines;
}
const hlHtml = lines => lines.map(l => l.map(([c, s]) => (c ? '<span class="' + c + '">' + esc(s) + '</span>' : esc(s))).join('')).join('\n');
const HL_COL = { '': '#d6dde4', k: '#ff7ab6', s: '#a8e07a', c: '#6f8091', n: '#f5b860', t: '#62c4ff', f: '#9db8ff', m: '#4fd1c5', a: '#ffd04a', g: '#ff9466' };
const MONO = 'ui-monospace, "JetBrains Mono", "Red Hat Mono", Menlo, Consolas, monospace';
const fmtBytes = b => (b == null ? '' : b < 1024 ? b + ' B' : b < 1048576 ? fmtN(b / 1024, b < 10240 ? 1 : 0) + ' KB' : fmtN(b / 1048576, 1) + ' MB');

/* ── the crash cart's screen: the POST, the code, or a message ─────────── */
function paintMonitor(cv, st) {
  const x = cv.getContext('2d'), W = cv.width, H = cv.height, s = W / MON_W;
  x.setTransform(1, 0, 0, 1, 0, 0);
  x.fillStyle = '#05080b'; x.fillRect(0, 0, W, H);
  x.setTransform(s, 0, 0, s, 0, 0);
  if (st.mode === 'off') return;
  if (st.mode === 'post') {
    x.font = '600 17px ' + MONO; x.textAlign = 'left';
    st.post.slice(0, st.postN).forEach((l, i) => {
      x.fillStyle = i === 0 ? '#7dfbd8' : '#c6d0da'; x.fillText(l[0], 34, 54 + i * 30);
      if (l[1]) { x.fillStyle = l[2] || '#f2f6f9'; x.fillText(l[1], 34 + x.measureText(l[0]).width, 54 + i * 30); }
    });
    if (st.cursor) { x.fillStyle = '#7dfbd8'; x.fillRect(34, 40 + st.postN * 30, 11, 18); }
    return;
  }
  // the console's frame, as the page draws it
  x.fillStyle = '#0a1016'; x.fillRect(0, 0, MON_W, 46); x.fillRect(0, MON_H - 32, MON_W, 32);
  x.fillStyle = '#1d2731'; x.fillRect(0, 46, MON_W, 1); x.fillRect(0, MON_H - 33, MON_W, 1);
  x.textAlign = 'left'; x.fillStyle = '#f2f6f9'; x.font = '650 15px ' + FONT_SANS; x.fillText(st.fw || '', 16, 28);
  const fwW = x.measureText(st.fw || '').width;
  x.fillStyle = '#93a1af'; x.font = '400 14px ' + FONT_SANS; x.fillText(fit(x, st.sub || '', '400', FONT_SANS, 14, 12, 560).text, 26 + fwW, 28);
  x.fillStyle = '#8c99a7'; x.font = '400 12.5px ' + FONT_SANS; x.fillText('← → or Tab change file     ↑ ↓ scroll     Esc unplug', 16, MON_H - 11);
  if (st.mode === 'msg') {
    x.fillStyle = '#fff'; x.font = '650 20px ' + FONT_SANS; x.fillText(st.title || '', 36, 104);
    x.fillStyle = '#c6d0da'; x.font = '400 15px ' + FONT_SANS;
    wrapLines(x, st.text || '', MON_W - 72, 6).forEach((l, i) => x.fillText(l, 36, 140 + i * 24));
    return;
  }
  // the files
  x.fillStyle = '#070b0f'; x.fillRect(0, 47, 220, MON_H - 80);
  x.fillStyle = '#1d2731'; x.fillRect(220, 47, 1, MON_H - 80);
  const files = st.files || [];
  files.forEach((f, i) => {
    const y = 55 + i * 25;
    if (y > MON_H - 70) return;
    if (i === st.fi) { x.fillStyle = '#15222e'; rrect(x, 6, y, 208, 24, 6); x.fill(); }
    x.fillStyle = i === st.fi ? '#fff' : '#b3bfca'; x.font = '500 13px ' + FONT_SANS;
    x.fillText(fit(x, f.path, '500', FONT_SANS, 13, 11, 140).text, 14, y + 17);
    x.fillStyle = '#6f7f8e'; x.font = '400 12px ' + FONT_SANS; x.textAlign = 'right'; x.fillText(fmtBytes(f.bytes), 206, y + 17); x.textAlign = 'left';
  });
  // the code, from the line the console is scrolled to
  const lines = st.lines || [], LH = 21, top = Math.max(0, Math.floor(st.top || 0));
  const gutW = 12 + String(lines.length).length * 8.4 + 10;
  x.save(); x.beginPath(); x.rect(221, 47, MON_W - 221, MON_H - 80); x.clip();
  x.font = '400 14px ' + MONO;
  const cw = x.measureText('M').width;
  for (let r = 0; r < 26; r++) {
    const li = top + r; if (li >= lines.length) break;
    const y = 47 + 10 + r * LH + 15;
    x.fillStyle = '#475463'; x.textAlign = 'right'; x.fillText(String(li + 1), 221 + gutW - 10, y); x.textAlign = 'left';
    let cx = 221 + gutW + 6;
    for (const [c, t] of lines[li]) {
      const tt = t.replace(/\t/g, '    ');
      x.fillStyle = HL_COL[c] || HL_COL['']; x.fillText(tt, cx, y); cx += tt.length * cw;
      if (cx > MON_W) break;
    }
  }
  x.restore();
}
/* ── open ──────────────────────────────────────────────────────────────── */
export async function open(opts) {
  const o = opts || {};
  const host = o.host;
  if (!host) throw new Error('aisle3d: open() needs opts.host');
  const dark = o.theme !== 'light';
  const P = dark ? DARK : LIGHT, NC = P.noc;
  const reduced = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  const world = o.world && typeof o.world === 'object' ? o.world : {};
  const machine = world.machine && typeof world.machine === 'object' ? world.machine : null;
  const perRack = Math.max(1, Math.floor(+o.perRack) || 42);
  const agg = (run, runs, k, how) => {
    if (run && num(run[k]) != null) return num(run[k]);
    const v = [];
    for (const l of runs) { const x = num(l[k]); if (x != null) v.push(x); }
    return v.length ? how(v) : null;
  };
  const logN = (v, r) => (v == null || !r ? null : r[1] > r[0] ? clamp01(Math.log(Math.max(v, r[0]) / r[0]) / Math.log(r[1] / r[0])) : 0.5);
  const linN = (v, r) => (v == null || !r ? null : clamp01(v / r[1]));
  // the racks' own stats, for their marquees, power strips and floor
  const langOf = list => {
    const m = new Map();
    for (const u of list) { if (!u.lang) continue; const e = m.get(u.lang) || { name: u.lang, n: 0, color: u.langColor, best: u, shares: [] }; e.n++; e.shares.push(u.share); m.set(u.lang, e); }
    return [...m.values()].map(e => Object.assign(e, { avg: mean(e.shares) })).sort((a, b) => b.n - a.n || a.best.rank - b.best.rank);
  };
  // With sections the room is a corridor, a stretch of racks for each; without, the one aisle.
  const corridor = Array.isArray(o.sections) && o.sections.some(s => s && Array.isArray(s.units) && s.units.length > 0);

  /* a benchmark family: its tests, its entries best first, their racks and its own ranges */
  function section(def, k) {
    def = def || {};
    const tests = (Array.isArray(def.tests) ? def.tests : []).map((t, i) => {
      t = t || {};
      return { i, id: t.id != null ? String(t.id) : 't' + i, label: t.label != null ? String(t.label) : t.id != null ? String(t.id) : 'Test ' + (i + 1), category: t.category ? String(t.category) : '', conns: num(t.conns) };
    });
    const nT = tests.length;
    const S = {
      k, id: def.id != null && def.id !== '' ? String(def.id) : 's' + k,
      label: def.label != null && def.label !== '' ? String(def.label) : def.id != null ? String(def.id) : 'Section ' + (k + 1),
      name: def.name ? String(def.name) : '', metric: def.metric ? String(def.metric) : world.metric ? String(world.metric) : 'Score',
      tests, nT, LY: layout(nT), color: P.secs[k % P.secs.length],
    };
    S.units = (Array.isArray(def.units) ? def.units : []).map((s, i) => {
      s = s || {};
      const leds = Array.isArray(s.leds) ? s.leds : [];
      const run = s.run && typeof s.run === 'object' ? s.run : null;
      const runs = leds.filter(l => l && typeof l === 'object');
      const comp = s.completeness && typeof s.completeness === 'object' ? s.completeness : null;
      return {
        i, sec: S, fw: String(s.fw), rank: s.rank != null ? s.rank : i + 1, lang: s.lang ? String(s.lang) : '',
        langColor: s.langColor || '#8b96a3', type: s.type || '', tuned: !!s.tuned, fav: !!s.fav,
        score: s.score == null ? '' : String(s.score), share: clamp01(s.share), leds,
        rack: Math.floor(i / perRack), slot: i % perRack,
        engine: s.engine ? String(s.engine) : '', strength: s.strength && typeof s.strength === 'object' ? s.strength : null,
        spec: num(s.spec), resil: num(s.resil), completeness: comp,
        cpu: agg(run, runs, 'cpu', mean), mem: agg(run, runs, 'memMiB', median), rps: agg(run, runs, 'rps', mean),
        p99: agg(run, runs, 'p99ms', median), bw: agg(run, runs, 'bwMBs', mean), errors: agg(run, runs, 'errors', sum),
        runFrom: run ? 'run' : runs.length ? 'tests' : '',
      };
    });
    S.byFw = new Map(S.units.map(u => [u.fw, u]));
    S.nR = Math.max(1, Math.ceil(S.units.length / perRack));
    // the section's ranges, so a fan or a gauge reads against its neighbours
    const vals = key => S.units.map(u => u[key]).filter(v => v != null && v > 0);
    const hall = {};
    for (const key of ['cpu', 'mem', 'rps', 'p99']) { const v = vals(key); hall[key] = v.length ? [Math.min(...v), Math.max(...v)] : null; }
    hall.cores = machine ? num(machine.cores) : null;
    hall.leader = S.units.length ? scoreNum(S.units[0].score) : null;
    for (const u of S.units) { u.cpuN = linN(u.cpu, hall.cpu); u.memN = logN(u.mem, hall.mem); u.rpsN = linN(u.rps, hall.rps); u.p99N = logN(u.p99, hall.p99); }
    S.hall = hall;
    S.has = { cpu: !!hall.cpu, mem: !!hall.mem, p99: !!hall.p99, rps: !!hall.rps };
    S.racks = Array.from({ length: S.nR }, (_, j) => {
      const us = S.units.filter(u => u.rack === j), sc = us.map(u => scoreNum(u.score)).filter(v => v != null);
      return { sec: S, k: j, us, from: j * perRack + 1, to: Math.min(S.units.length, (j + 1) * perRack), best: us[0] || null, median: sc.length ? median(sc) : null,
        langs: langOf(us), tuned: us.filter(u => u.tuned).length, load: us.length ? mean(us.map(u => u.share)) : 0, rps: sum(us.map(u => u.rps || 0)) };
    });
    S.langs = langOf(S.units);
    for (const t of tests) {
      let best = null;
      for (const u of S.units) { const l = u.leds[t.i]; if (l && l.best) { best = u; break; } }
      if (!best) { let bp = -1; for (const u of S.units) { const l = u.leds[t.i]; if (l && num(l.p) != null && +l.p > bp) { bp = +l.p; best = u; } } }
      t.best = best ? 'best ' + best.fw : '';
    }
    S.family = nT > 0 && tests.every(t => !t.category && t.conns == null) && !S.units.some(u => u.leds.some(l => l && num(l.rps) != null));
    return S;
  }
  const SECS = corridor
    ? o.sections.filter(s => s && Array.isArray(s.units) && s.units.length > 0).map((s, k) => section(s, k))
    : [section({ id: 'main', label: world.view ? String(world.view) : o.title || 'The aisle', name: o.title || '', metric: world.metric, tests: o.tests, units: o.units }, 0)];
  const all = [];
  for (const S of SECS) for (const u of S.units) { u.gi = all.length; all.push(u); }
  let eqN = 0;
  for (const u of all) { u.eq0 = eqN; eqN += u.sec.nT; }
  const byKey = new Map(all.map(u => [u.sec.id + '|' + u.fw, u]));
  const secById = new Map(SECS.map(S => [S.id, S]));
  const sidOf = u => (corridor ? u.sec.id : undefined);   // what the page's callbacks are told
  let cur = (corridor && o.start != null && secById.get(String(o.start))) || SECS[0];
  const unitOf = (fw, sid) => { const S = sid != null ? secById.get(String(sid)) : null; return S ? S.byFw.get(fw) : cur.byFw.get(fw) || all.find(u => u.fw === fw) || null; };

  /* where everything stands. The racks face each other across the aisle: the row at z = 0
     faces +z, the row at z = OPP_Z faces -z. In the corridor each section has a bay for its
     sign and kiosk, a closed cabinet at each end, and its racks in order in one row on the
     left (z = 0), R1 first, closed cabinets facing them across the aisle. */
  const unitsTop = BASE_Y + perRack * U, RACK_H = unitsTop + TOP_H;
  const racks = [], closed = [];
  let endL, endR, rowX0, rowX1;
  if (!corridor) {
    const S = SECS[0], X0 = -((S.nR - 1) * PITCH) / 2;
    S.racks.forEach((R, j) => Object.assign(R, { x: X0 + j * PITCH, z: 0, dir: 1 }));
    rowX0 = X0 - PITCH / 2; rowX1 = X0 + (S.nR - 1) * PITCH + PITCH / 2;
    for (let j = -2; j < S.nR + 2; j++) { if (j < 0 || j >= S.nR) closed.push([X0 + j * PITCH, 0, 1]); closed.push([X0 + j * PITCH, OPP_Z, -1]); }
    endL = rowX0 - 2 * PITCH - 1.4; endR = rowX1 + 2 * PITCH + 1.4;
    S.x0 = S.rx0 = rowX0; S.x1 = S.rx1 = rowX1;
  } else {
    let x = 0;
    for (const S of SECS) {
      S.x0 = x; x += SEC_LEAD;
      closed.push([x + PITCH / 2, 0, 1], [x + PITCH / 2, OPP_Z, -1]); x += PITCH;
      S.racks.forEach((R, j) => { Object.assign(R, { x: x + j * PITCH + PITCH / 2, z: 0, dir: 1 }); closed.push([R.x, OPP_Z, -1]); });
      S.rx0 = x; x += S.nR * PITCH; S.rx1 = x;
      closed.push([x + PITCH / 2, 0, 1], [x + PITCH / 2, OPP_Z, -1]); x += PITCH;
      S.x1 = x;
    }
    rowX0 = 0; rowX1 = x;
    endL = -LOBBY; endR = x + END_BAY;
  }
  for (const S of SECS) for (const R of S.racks) { R.gk = racks.length; racks.push(R); }
  const midX = (endL + endR) / 2;
  const WALL_X = endR - 0.05;
  // the comparison bench: along the lobby's wall in the corridor, across the near end of the one aisle
  const BENCH = corridor ? { x: -5.35, z: -1.0, yaw: 0, L: 2.7, D: 1.0 } : { x: endL + 0.6, z: OPP_Z / 2, yaw: Math.PI / 2, L: 2.7, D: 1.0 };
  BENCH.m = new THREE.Matrix4().makeRotationY(BENCH.yaw).setPosition(BENCH.x, 0, BENCH.z);

  /* the hall round the corridor: more rows of cabinets on both sides, back to back across hot
     aisles and face to face across cold ones, cut where the corridor's bays cut it (the cross
     aisles); a high roof on steel and glass walls to the outside. In the corridor the lobby is a
     glass foyer at the near end. Row fronts sit on the floor tiles' grid. */
  const vw = () => host.clientWidth || window.innerWidth || 1;
  const vh = () => host.clientHeight || window.innerHeight || 1;
  const small = vw() <= 760;
  const HH = 7.2, FH = corridor ? 3.6 : HH, HOT = 1.46, COLD = 1.8, nHall = small ? 2 : 4;
  const HANG = HH - 0.75;   // the underside of the strut grid everything overhead hangs from
  const blocks = [];        // runs of cabinets along x, [first centre, last centre]
  for (const [x] of closed.filter(c => c[1] === OPP_Z).sort((a, b) => a[0] - b[0])) {
    const b = blocks[blocks.length - 1];
    if (b && x - b[1] < PITCH * 1.5) b[1] = x; else blocks.push([x, x]);
  }
  const rowsZ = [{ z: 0, dir: 1 }, { z: OPP_Z, dir: -1 }];   // the corridor's own two first
  for (const side of [-1, 1]) {
    let e = side < 0 ? -RACK_D : OPP_Z + RACK_D;
    for (let i = 0; i < nHall; i++) {
      if (i % 2 === 0) { e += side * (HOT + RACK_D); rowsZ.push({ z: e, dir: side, hall: true, near: i === 0, n: i }); }
      else { e += side * COLD; rowsZ.push({ z: e, dir: -side, hall: true, n: i }); e += side * RACK_D; }
    }
  }
  const rspan = r => (r.dir > 0 ? [r.z - RACK_D, r.z] : [r.z, r.z + RACK_D]);
  let HZ0 = 0, HZ1 = 0;
  for (const r of rowsZ) { const s = rspan(r); HZ0 = Math.min(HZ0, s[0]); HZ1 = Math.max(HZ1, s[1]); }
  HZ0 = Math.floor((HZ0 - 2.3) / 0.6) * 0.6; HZ1 = Math.ceil((HZ1 + 2.3) / 0.6) * 0.6;   // a service aisle along each glass wall
  const HX0 = corridor ? -1.2 : endL, HX1 = endR, FZ0 = -1.75, FZ1 = OPP_Z + 1.75;
  const bx0 = blocks[0][0] - PITCH / 2, bx1 = blocks[blocks.length - 1][1] + PITCH / 2;
  // the aisles, each lit by a line of fittings down its middle (the corridor by two): [z, aisle z0, z1, hall?]
  const lines = [], aisles = [];
  {
    const sp = rowsZ.map(rspan).sort((a, b) => a[0] - b[0]);
    let prev = HZ0;
    const aisle = (a, b) => {
      aisles.push([a, b]);
      if (Math.abs(a) < 0.01 && Math.abs(b - OPP_Z) < 0.01) lines.push([1.05, a, b, 0], [OPP_Z - 1.05, a, b, 0]);
      else lines.push([(a + b) / 2, a, b, 1]);
    };
    for (const s of sp) { if (s[0] - prev > 0.4) aisle(prev, s[0]); prev = s[1]; }
    aisle(prev, HZ1);
  }

  const bin = new Set();
  const own = x => { bin.add(x); return x; };
  const canvases = [];
  const keepCv = c => { canvases.push(c); return c; };
  let disposed = false;

  /* the HUD */
  const root = document.createElement('div');
  root.className = 'a3d';
  const rackChips = S => S.racks.map((R, j) => {
    const a = R.from, b = R.to;
    return '<button type="button" class="a3d-btn a3d-chip" data-rack="' + j + '" aria-label="Go to rack R' + (j + 1) + ', units ' + a + ' to ' + b + '">R' + (j + 1)
      + (b >= a ? '<small>#' + a + (b > a ? '–' + b : '') + '</small>' : '') + '</button>';
  }).join('');
  const chipHtml = corridor
    ? '<button type="button" class="a3d-btn a3d-chip" data-act="entrance" aria-label="Go to the entrance" title="The entrance: the overall board (0)">' + ICON.door + '<span class="a3d-bt">Entrance</span></button>'
      + SECS.map((S, k) => '<button type="button" class="a3d-btn a3d-chip a3d-sec" data-sec="' + esc(S.id) + '" style="--sc:' + S.color + '" aria-label="Go to ' + esc(S.label) + (S.name ? ', ' + esc(S.name) : '') + ', ' + S.units.length + ' entries" title="' + esc(S.name || S.label) + (k < 9 ? ' (' + (k + 1) + ')' : '') + '"><i aria-hidden="true"></i>' + esc(S.label) + '<small>' + S.units.length + '</small></button>').join('')
    : rackChips(SECS[0]);
  const pullHtml = S => {
    const ks = PULL.filter(([k]) => k === 'off' || k === 'score' || S.has[k]);
    return '<span>Pull out by</span>' + ks.map(([k, l]) => '<button type="button" data-pull="' + k + '" aria-pressed="' + (k === 'off') + '">' + l + '</button>').join('')
      + (S.nT ? '<select data-pull-test class="a3d-hide-s" aria-label="Pull out by a test"><option value="">A test…</option>' + S.tests.map(t => '<option value="' + t.i + '">' + esc(t.label) + '</option>').join('') + '</select>' : '')
      // on a phone one select holds every measure
      + '<select data-pull-all class="a3d-show-s" aria-label="Pull the drawers out by">' + ks.map(([k, l]) => '<option value="' + k + '">' + (k === 'off' ? 'Pull out by…' : l) + '</option>').join('')
      + S.tests.map(t => '<option value="t' + t.i + '">' + esc(t.label) + '</option>').join('') + '</select>';
  };
  const secLine = S => S.label + (S.name ? ' · ' + S.name : '') + ' · ' + S.units.length + ' entr' + (S.units.length === 1 ? 'y' : 'ies');
  root.innerHTML = '<style>' + CSS + '</style>'
    + '<canvas class="a3d-cv" tabindex="0" aria-label="The racks in 3D. Drag to look around, scroll to zoom."></canvas>'
    + '<div class="a3d-mon" hidden role="region" aria-label="The crash cart\'s monitor"><div class="a3d-mon-h"><b></b><span></span><a target="_blank" rel="noopener" hidden>' + ICON.ext + 'View on GitHub</a><button type="button" data-act="unplug">Unplug</button></div>'
    + '<div class="a3d-mon-b"><nav class="a3d-mon-f" aria-label="Files"></nav><div class="a3d-mon-c" tabindex="0" aria-label="Source code"><pre class="a3d-gut" aria-hidden="true"></pre><pre class="a3d-code"><code></code></pre></div></div>'
    + '<div class="a3d-mon-k"><span><kbd>←</kbd><kbd>→</kbd> or <kbd>Tab</kbd> change file</span><span><kbd>↑</kbd><kbd>↓</kbd> scroll</span><span><kbd>Esc</kbd> unplug</span></div></div>'
    + '<div class="a3d-top"><div class="a3d-title a3d-glass"><b>' + esc(o.title || (corridor ? 'The corridor' : 'The aisle')) + '</b>' + (corridor ? '<span class="a3d-sub">' + esc(secLine(cur)) + '</span>' : o.subtitle ? '<span>' + esc(o.subtitle) + '</span>' : '') + '</div>'
    + '<div class="a3d-nav a3d-glass" role="toolbar" aria-label="Aisle navigation">'
    + '<button type="button" class="a3d-btn" data-act="prev" aria-label="Previous rack" title="Previous rack ([ or PageUp)">' + ICON.prev + (corridor ? '' : '<span class="a3d-bt">Previous rack</span>') + '</button>'
    + (corridor ? '<span class="a3d-where" aria-live="off"></span>' : '')
    + '<div class="a3d-chips' + (corridor ? ' a3d-scroll' : '') + '">' + chipHtml
    + '<button type="button" class="a3d-btn a3d-chip a3d-benchc" data-act="bench" aria-label="Go to the comparison bench" title="The comparison bench: Shift+click units to bring them here">' + ICON.bench + '<span class="a3d-bt">Bench</span><span class="a3d-dots" aria-hidden="true"></span></button>'
    + '<button type="button" class="a3d-btn a3d-chip" data-act="wall" aria-label="Go to the operations wall" title="The operations wall at the end of the aisle">' + ICON.wall + '<span class="a3d-bt">Wall</span></button></div>'
    + '<button type="button" class="a3d-btn" data-act="next" aria-label="Next rack" title="Next rack (] or PageDown)">' + (corridor ? '' : '<span class="a3d-bt">Next rack</span>') + ICON.next + '</button>'
    + '<span class="a3d-sep" aria-hidden="true"></span>'
    + '<button type="button" class="a3d-btn" data-act="reset" aria-label="Reset view" title="Reset view (Home)">' + ICON.reset + (corridor ? '' : '<span class="a3d-bt">Reset view</span>') + '</button>'
    + '<button type="button" class="a3d-btn" data-act="close" aria-label="Close the 3D aisle (Esc)" title="Close (Esc)">' + ICON.close + '<span class="a3d-bt">' + (corridor ? 'Close' : 'Close (Esc)') + '</span></button>'
    + '</div></div>'
    + '<div class="a3d-bar a3d-glass" role="toolbar" aria-label="Aisle tools">'
    + '<div class="a3d-find">' + ICON.find + '<input type="search" placeholder="' + (vw() <= 760 ? 'Find' : 'Find a framework') + '" aria-label="Find a framework" autocomplete="off" spellcheck="false"><ul class="a3d-res a3d-glass" role="listbox" aria-label="Matches"></ul></div>'
    + '<div class="a3d-seg" role="group" aria-label="Pull the drawers out by">' + pullHtml(cur) + '</div>'
    + '<button type="button" class="a3d-btn a3d-tog" data-act="motion" aria-pressed="false" title="Fans, lights and marquees in motion"><i aria-hidden="true"></i><span class="a3d-bt">Motion</span></button>'
    + '<button type="button" class="a3d-btn a3d-hide-s" data-act="tour" title="A guided walk past the notable units">' + ICON.tour + '<span class="a3d-bt">Tour</span></button>'
    + '<button type="button" class="a3d-btn a3d-lit a3d-hide-s" data-act="unlit" hidden><i aria-hidden="true"></i><span></span></button>'
    + '<button type="button" class="a3d-btn a3d-hide-s" data-act="keys" aria-expanded="false" aria-label="Controls" title="Controls">' + ICON.keys + '</button>'
    + '</div>'
    + '<div class="a3d-tray a3d-glass" hidden aria-label="On the comparison bench"><span>On the bench</span><ul></ul><button type="button" class="a3d-btn" data-act="bench">' + ICON.cmp + '<span>Compare them</span></button><button type="button" class="a3d-btn" data-act="putback">Put them all back</button></div>'
    + '<div class="a3d-keys a3d-glass" hidden><b>Getting around</b><ul>'
    + '<li>Drag to look around, right-drag to pan, scroll to zoom</li>'
    + '<li><kbd>W</kbd><kbd>A</kbd><kbd>S</kbd><kbd>D</kbd> or arrows to walk, <kbd>Q</kbd><kbd>E</kbd> down and up</li>'
    + '<li><kbd>[</kbd><kbd>]</kbd> change rack' + (corridor ? ', <kbd>1</kbd>–<kbd>' + Math.min(9, SECS.length) + '</kbd> a section, <kbd>0</kbd> the entrance' : '') + ', <kbd>Home</kbd> back to the start</li>'
    + '<li>Point at a light, a fan or a gauge to read it; click a unit to open it, <kbd>Shift</kbd>+click to take it to the bench</li>'
    + '<li>Click a language, a bar or a test on the wall to light or pull out those units</li>'
    + '</ul><button type="button" class="a3d-btn" data-act="keys-hide">Got it</button></div>'
    + '<div class="a3d-cap a3d-glass" hidden aria-live="polite"><b></b><div class="a3d-cap-t"></div><div class="a3d-row"><span></span><button type="button" class="a3d-btn" data-act="tour-next">Next</button><button type="button" class="a3d-btn" data-act="tour-stop">End the tour</button></div></div>'
    + '<div class="a3d-tip a3d-glass" role="tooltip"></div>'
    + '<div class="a3d-tip a3d-ledtip a3d-glass" role="tooltip"></div>'
    + '<div class="a3d-toast a3d-glass" role="status"></div>'
    + '<aside class="a3d-panel a3d-glass" aria-label="Unit details" aria-hidden="true">'
    + '<div class="a3d-pbar"><button type="button" class="a3d-btn a3d-loc" aria-pressed="false"><i aria-hidden="true"></i><span>Locator light</span></button><b class="a3d-ptitle" hidden></b>'
    + '<span class="a3d-sp"></span><button type="button" class="a3d-btn" data-act="putback" hidden>Put them all back</button><button type="button" class="a3d-btn" data-close aria-label="Slide the unit back into the rack">' + ICON.back + '<span>Slide back in</span></button></div>'
    + '<div class="a3d-pact"><button type="button" class="a3d-btn" data-act="cmp" aria-pressed="false" title="Take it to the comparison bench (Shift+click a unit)">' + ICON.cmp + '<span>Compare</span></button>'
    + (typeof o.sourceUrl === 'function' ? '<button type="button" class="a3d-btn" data-act="mon" title="Roll the crash cart over and read its code">' + ICON.mon + '<span>Plug in a monitor</span></button>' : '') + '</div>'
    + '<div class="a3d-pbody"></div></aside>'
    + '<div class="a3d-msg">Racking ' + all.length + ' unit' + (all.length === 1 ? '' : 's') + '…</div>'
    + '<div class="a3d-live" aria-live="polite"></div>';
  const addedCls = ['a3d-host', dark ? 'a3d-dark' : 'a3d-light'];
  host.classList.add(...addedCls);
  const hadRole = host.hasAttribute('role');
  if (!hadRole) { host.setAttribute('role', 'dialog'); host.setAttribute('aria-modal', 'true'); host.setAttribute('aria-label', o.title || '3D aisle'); }
  host.appendChild(root);
  const $ = s => root.querySelector(s);
  let cv = $('.a3d-cv');
  const tipEl = $('.a3d-tip:not(.a3d-ledtip)'), ledTipEl = $('.a3d-ledtip'), panel = $('.a3d-panel');
  const pbody = $('.a3d-pbody'), locBtn = $('.a3d-loc'), msgEl = $('.a3d-msg'), live = $('.a3d-live'), keysEl = $('.a3d-keys');
  const findIn = $('.a3d-find input'), findRes = $('.a3d-res'), capEl = $('.a3d-cap'), litBtn = $('[data-act="unlit"]');
  const motionBtn = $('[data-act="motion"]'), keysBtn = $('[data-act="keys"]'), segEl = $('.a3d-seg');
  const pact = $('.a3d-pact'), cmpBtn = $('.a3d-pact [data-act="cmp"]'), monBtn = $('.a3d-pact [data-act="mon"]'), pTitle = $('.a3d-ptitle');
  const closeBtn = $('.a3d-pbar [data-close]'), putBtn = $('.a3d-pbar [data-act="putback"]');
  const trayEl = $('.a3d-tray'), toastEl = $('.a3d-toast'), benchChip = $('.a3d-benchc'), whereEl = $('.a3d-where'), subEl = $('.a3d-sub');
  const monEl = $('.a3d-mon');
  const btn = { prev: $('[data-act="prev"]'), next: $('[data-act="next"]') };
  const chipEls = Array.from(root.querySelectorAll('.a3d-chip[data-rack]'));
  const secEls = Array.from(root.querySelectorAll('.a3d-chip[data-sec]'));
  const wallChip = $('.a3d-chip[data-act="wall"]'), entChip = $('.a3d-chip[data-act="entrance"]');
  let prefs = {};
  try { prefs = JSON.parse(localStorage.getItem('a3d-prefs') || '{}') || {}; } catch (e) { prefs = {}; }
  const savePrefs = () => { try { localStorage.setItem('a3d-prefs', JSON.stringify(prefs)); } catch (e) { /* storage off */ } };
  try { if (localStorage.getItem('a3d-help') !== '0' && !prefs.keysSeen) { keysEl.hidden = false; keysBtn.setAttribute('aria-expanded', 'true'); } } catch (e) { keysEl.hidden = false; }
  let toastTimer = 0;
  function toast(text) {
    toastEl.textContent = text; toastEl.classList.add('on');
    clearTimeout(toastTimer); toastTimer = setTimeout(() => toastEl.classList.remove('on'), 2600);
  }


  function fail(text) {
    msgEl.className = 'a3d-msg err';
    msgEl.innerHTML = '<div>' + esc(text) + '</div><button type="button" class="a3d-btn" data-act="close">' + ICON.close + '<span>Close</span></button>';
    const onKeyFail = e => { if (e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); closeFail(); } };
    function closeFail() { if (disposed) return; teardownDom(); window.removeEventListener('keydown', onKeyFail, true); try { o.onClose && o.onClose(); } catch (e) { console.error(e); } }
    msgEl.querySelector('button').onclick = closeFail;
    root.querySelector('.a3d-nav [data-act="close"]').onclick = closeFail;
    window.addEventListener('keydown', onKeyFail, true);
    return { close() { if (!disposed) { teardownDom(); window.removeEventListener('keydown', onKeyFail, true); } }, setFav() {}, focus() {} };
  }
  function teardownDom() {
    disposed = true;
    root.remove();
    host.classList.remove(...addedCls);
    if (!hadRole) { host.removeAttribute('role'); host.removeAttribute('aria-modal'); host.removeAttribute('aria-label'); }
  }

  /* the renderer. On a desktop the room goes into a multisampled HDR target and a last pass
     brings it to the screen (occlusion, bloom, tone mapping); on a phone, or without float
     targets, it is drawn straight to a multisampled screen as before. Two samples: four would
     cost another 50 MB at 1080p for edges the bloom mostly softens anyway. */
  let renderer, post = null;
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  const startRenderer = direct => {
    const r = new THREE.WebGLRenderer({ canvas: cv, antialias: direct, depth: direct, powerPreference: 'high-performance' });
    r.setPixelRatio(dpr);
    r.setSize(vw(), vh(), false);
    r.toneMapping = THREE.NeutralToneMapping;
    r.toneMappingExposure = P.exposure;
    r.outputColorSpace = THREE.SRGBColorSpace;
    return r;
  };
  try {
    renderer = startRenderer(small);
    if (!small) {
      try { post = makePost(renderer, { samples: 2, exposure: P.exposure, fog: P.hazeD, ao: P.ao, bloom: P.bloom }); } catch (e) { post = null; }
      if (!post) {
        // no float targets here: a fresh canvas, multisampled, straight to the screen
        renderer.dispose(); try { renderer.forceContextLoss(); } catch (e) { /* fine */ }
        const fresh = cv.cloneNode(false); cv.replaceWith(fresh); cv = fresh;
        renderer = startRenderer(true);
      }
    }
  } catch (e) {
    return fail('This browser could not start WebGL, so the 3D aisle cannot open here.');
  }
  const aniso = Math.min(8, renderer.capabilities.getMaxAnisotropy());
  // a screen or a lit sign shows its own colours: with the HDR pass it says so in its alpha
  const display = m => {
    if (!post) return m;
    m.onBeforeCompile = sh => { sh.fragmentShader = sh.fragmentShader.replace('#include <opaque_fragment>', '#include <opaque_fragment>\n  gl_FragColor.a = 0.0;'); };
    m.customProgramCacheKey = () => 'a3d-display';
    return m;
  };

  // the fonts the panels are printed in; a missing one falls back, a slow one does not hold the room up
  try {
    const want = ['600 34px "Saira SC"', '700 34px "Saira SC"', '600 24px "Inter"', '700 24px "Inter"', '500 24px "Inter"', '700 40px "DSEG7"'];
    await Promise.race([
      Promise.all(want.map(f => document.fonts.load(f).catch(() => null))).then(() => document.fonts.ready),
      new Promise(r => setTimeout(r, 2500)),
    ]);
  } catch (e) { /* no FontFaceSet: system fonts */ }
  if (disposed) { if (post) post.dispose(); renderer.dispose(); return { close() {}, setFav() {}, focus() {} }; }

  // A canvas is let go once its texture is on the GPU (a redraw paints a fresh one),
  // so a hundred panels do not keep a hundred canvases alive.
  const freeImage = t => { const c = t.image; if (c && c.getContext && c.width > 1) { c.width = 1; c.height = 1; } };
  const tex = (cvs, opt) => {
    const t = own(new THREE.CanvasTexture(cvs));
    t.colorSpace = opt && opt.linear ? THREE.NoColorSpace : THREE.SRGBColorSpace;
    t.anisotropy = aniso;
    if (opt && opt.repeat) { t.wrapS = t.wrapT = THREE.RepeatWrapping; t.repeat.set(opt.repeat[0], opt.repeat[1]); }
    if (opt && opt.nearest) { t.minFilter = t.magFilter = THREE.NearestFilter; t.generateMipmaps = false; t.anisotropy = 1; }
    if (!(opt && opt.keep)) t.onUpdate = freeImage;
    t.userData.size = cvs.width + 'x' + cvs.height;
    t.userData.px = cvs.width * cvs.height;
    return t;
  };
  // a redraw paints a fresh canvas; a new size needs fresh storage on the GPU
  const repaint = (t, w, h, draw) => {
    const c = canvas(w, h); draw(c);
    if (t.userData.size && t.userData.size !== w + 'x' + h) t.dispose();
    t.userData.size = w + 'x' + h; t.userData.px = w * h;
    t.image = c; t.needsUpdate = true;
  };
  const T = { value: 0 };   // the one clock everything that moves reads

  /* the scene */
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(P.haze);
  scene.fog = new THREE.FogExp2(P.haze, P.hazeD);   // a lit haze: the far rows fade into it, not into black
  const camera = new THREE.PerspectiveCamera(FOV, vw() / vh(), 0.02, 120);

  // what the metal reflects: the aisle itself, prefiltered. Two lines of fixtures overhead, the
  // rows of racks on both sides speckled with their lights, the floor, the ceiling.
  let envRT = null;
  try {
    const es = new THREE.Scene(), bx = new THREE.BoxGeometry(1, 1, 1), tmp = [bx];
    const em = (color, k, extra) => { const m = new THREE.MeshBasicMaterial(Object.assign({ color: new THREE.Color(color).multiplyScalar(k || 1) }, extra || {})); tmp.push(m); return m; };
    const put = (m, sx, sy, sz, x, y, z) => { const o = new THREE.Mesh(bx, m); o.scale.set(sx, sy, sz); o.position.set(x, y, z); es.add(o); return o; };
    put(em(dark ? 0x0b0d11 : 0xc9d0d7, 1, { side: THREE.BackSide }), 44, 7.4, 34, 0, 2.4, 0);                   // the hall
    put(em(dark ? 0x12161b : 0xd9dee3), 44, 0.02, 34, 0, -1.2, 0);                                            // the floor
    put(em(dark ? 0x07090c : 0xeef1f4), 44, 0.02, 34, 0, 5.9, 0);                                             // the roof
    for (const z of [-16.4, 16.4]) put(em(dark ? 0x1b2a44 : 0xe3eef8, dark ? 0.7 : 1.5), 44, 5.4, 0.05, 0, 2.6, z);   // the glass walls
    // the racks: dark fronts, and on them their lights
    const led = canvas(256, 128), lx = led.getContext('2d'), lr = rng(5);
    lx.fillStyle = dark ? '#06080a' : '#1b2026'; lx.fillRect(0, 0, 256, 128);
    for (let i = 0; i < 260; i++) { lx.fillStyle = ['#3dff8f', '#3dff8f', '#3dff8f', '#3aa0ff', '#ffb020'][Math.floor(lr() * 5)]; lx.globalAlpha = 0.5 + lr() * 0.5; lx.fillRect(Math.floor(lr() * 64) * 4, Math.floor(lr() * 64) * 2, 2, 1); }
    const ledT = new THREE.CanvasTexture(led); ledT.colorSpace = THREE.SRGBColorSpace; ledT.wrapS = ledT.wrapT = THREE.RepeatWrapping; ledT.repeat.set(10, 1); tmp.push(ledT);
    const rackM = em(0xffffff, dark ? 2.2 : 1.2, { map: ledT });
    for (const z of [-2.1, 2.1, -5.2, 5.2, -8.4, 8.4]) put(rackM, 44, 2.15, 0.05, 0, -0.12, z);
    // the fixtures, in lengths, as they hang
    const lampM = em(dark ? 0xd6e6ff : 0xffffff, dark ? 7 : 4.5);
    for (const z of [-1.05, 1.05, -3.7, 3.7, -6.8, 6.8, -9.9, 9.9]) for (let x = -21; x < 21; x += 1.8) put(lampM, 1.2, 0.03, 0.1, x, 1.72, z);
    const pm = new THREE.PMREMGenerator(renderer);
    envRT = pm.fromScene(es, 0.035);
    pm.dispose(); for (const t of tmp) t.dispose(); led.width = led.height = 1;
    scene.environment = envRT.texture;
    scene.environmentIntensity = P.envK;
  } catch (e) { envRT = null; }

  // light: in the corridor a light from each side of the aisle, so both rows show their faces
  scene.add(new THREE.HemisphereLight(P.hemi[0], P.hemi[1], P.hemi[2]));
  if (!corridor) {
    const sun = new THREE.DirectionalLight(P.dir[0], P.dir[1]);
    sun.position.set(SECS[0].racks[0].x - 2.2, 4.2, 5.2);
    sun.target.position.set(midX, 1, 0);
    scene.add(sun, sun.target);
  } else {
    for (const [zf, zt] of [[OPP_Z + 3.2, 0], [-3.2, OPP_Z]]) {
      const sun = new THREE.DirectionalLight(P.dir[0], P.dir[1] * 0.72);
      sun.position.set(midX - 3, 4.2, zf); sun.target.position.set(midX, 1, zt);
      scene.add(sun, sun.target);
    }
  }
  const spotAt = (x, z, tx, tz, k, ang) => {
    const sp = new THREE.SpotLight(P.spot[0], P.spot[1] * (k || 1), 9, ang || 0.78, 0.9, 1.6);
    sp.position.set(x, 2.95, z); sp.target.position.set(tx, 0.85, tz);
    scene.add(sp, sp.target);
  };
  if (!corridor) {
    const nR = SECS[0].nR, nSpots = Math.min(P.spots, nR);
    for (let i = 0; i < nSpots; i++) {
      const x = nSpots === 1 ? midX : rowX0 + 0.3 + (rowX1 - rowX0 - 0.6) * i / (nSpots - 1);
      spotAt(x, 1.35, x, -0.2);
    }
    spotAt(BENCH.x + 1.5, BENCH.z, BENCH.x, BENCH.z, 0.8, 0.7);
  } else {
    // a pool of light over each section and over the bench; the wall lights itself
    const nS = Math.min(small ? 2 : 7, SECS.length);
    for (let i = 0; i < nS; i++) { const S = SECS[i], x = (S.rx0 + S.rx1) / 2; spotAt(x, OPP_Z / 2, x, OPP_Z / 2, 0.62, 0.85); }
    spotAt(BENCH.x, BENCH.z + 1.6, BENCH.x, BENCH.z, 0.8, 0.7);
  }

  /* the fittings overhead light the hall: a long light down each aisle (two down the corridor),
     added to every lit material (diffuse, and a highlight no brighter than the fitting it shows).
     The rows of cabinets keep an aisle's light in its aisle: a surface sees the lines of other
     aisles only above the cabinets' tops (in the foyer, there are no rows). A material with its
     own shader patch runs this one first. */
  const NL = 14;
  const LINE = {
    uA3dLine: { value: new THREE.Vector4(2.9, HX0, RACK_H, Math.min(NL, lines.length)) },   // height, the foyer's end, the cabinets' top, count
    uA3dL: { value: Array.from({ length: NL }, (_, i) => (lines[i] ? new THREE.Vector4(...lines[i]) : new THREE.Vector4(1e4, 0, 0, 0))) },
    uA3dLineC: { value: new THREE.Color(P.lamp).multiplyScalar(P.lineK) }, uA3dLamp: { value: new THREE.Color(P.lamp).multiplyScalar(P.lampK) },
    uA3dExt: { value: new THREE.Vector2(-1e4, 1e4) }, uA3dExtH: { value: new THREE.Vector2(bx0 - 0.9, bx1 + 0.9) },
  };
  const lineLit = sh => {
    Object.assign(sh.uniforms, LINE);
    sh.vertexShader = 'varying vec3 vA3dW;\n' + sh.vertexShader.replace('#include <project_vertex>', [
      '#include <project_vertex>',
      '{ vec4 a3dW = vec4(transformed, 1.0);',
      '#ifdef USE_INSTANCING',
      '  a3dW = instanceMatrix * a3dW;',
      '#endif',
      '  vA3dW = (modelMatrix * a3dW).xyz; }'].join('\n'));
    sh.fragmentShader = 'uniform vec4 uA3dLine;\nuniform vec4 uA3dL[' + NL + '];\nuniform vec3 uA3dLineC;\nuniform vec3 uA3dLamp;\nuniform vec2 uA3dExt;\nuniform vec2 uA3dExtH;\nvarying vec3 vA3dW;\n'
      + 'float a3dX(vec2 e, float x) { return smoothstep(e.x - 1.5, e.x + 0.5, x) * (1.0 - smoothstep(e.y - 0.5, e.y + 1.5, x)); }\n'
      + sh.fragmentShader.replace('#include <lights_fragment_begin>', [
      '#include <lights_fragment_begin>',
      'if (vA3dW.y < uA3dLine.x + 0.05) {',
      '  vec3 a3dN = inverseTransformDirection(normal, viewMatrix), a3dR = reflect(normalize(vA3dW - cameraPosition), a3dN);',
      '  float a3dExC = a3dX(uA3dExt, vA3dW.x), a3dExH = a3dX(uA3dExtH, vA3dW.x);',
      '  float a3dTop = smoothstep(uA3dLine.z - 0.3, uA3dLine.z + 0.35, vA3dW.y), a3dFoyer = step(vA3dW.x, uA3dLine.y);',
      '  PhysicalMaterial a3dM = material;',
      '  vec3 a3dSpec = vec3(0.0);',
      // a reflection is never brighter than the fitting it shows
      '  vec3 a3dCap = uA3dLamp * F_Schlick(material.specularColor, material.specularF90, saturate(dot(geometryNormal, geometryViewDir)));',
      '  #ifdef A3D_MATTE',
      '    a3dCap *= 0.25;',
      '  #endif',
      '  for (int i = 0; i < ' + NL + '; i++) {',
      '    if (float(i) >= uA3dLine.w) break;',
      '    vec4 L = uA3dL[i];',
      '    float dz = abs(L.x - vA3dW.z);',
      '    if (dz > 6.5) continue;',
      '    float own = step(L.y - 0.06, vA3dW.z) * step(vA3dW.z, L.z + 0.06);',
      '    if (L.w < 0.5) own = max(own, a3dFoyer);',
      '    float vis = max(own, a3dTop) * (L.w > 0.5 ? a3dExH : a3dExC) * (1.0 - smoothstep(5.0, 6.5, dz));',
      '    if (vis <= 0.0) continue;',
      '    vec3 q0 = vec3(0.0, uA3dLine.x, L.x);',
      '    vec2 d = q0.yz - vA3dW.yz;',
      '    float rr = sqrt(dot(d, d) + 0.02);',
      '    vec2 l = d / rr;',
      '    float k = max(l.x, 0.0) * vis / rr;',   // a fitting faces down; a long light falls off as the distance
      '    reflectedLight.directDiffuse += uA3dLineC * (max(a3dN.y * l.x + a3dN.z * l.y, 0.0) * k) * BRDF_Lambert(material.diffuseColor);',
      // the highlight comes from the point of the line nearest the reflected ray, its width widening it
      '    vec3 w0 = q0 - vA3dW;',
      '    vec2 ex = L.w > 0.5 ? uA3dExtH : uA3dExt;',
      '    float t = clamp((a3dR.x * dot(a3dR, w0) - w0.x) / max(1.0 - a3dR.x * a3dR.x, 1e-3), ex.x, ex.y);',
      '    vec3 ls = vec3(t, q0.yz) - vA3dW;',
      '    float ld = length(ls);',
      '    ls /= ld;',
      '    a3dM.roughness = min(1.0, material.roughness + 0.07 / ld);',
      '    a3dSpec += uA3dLineC * (max(dot(a3dN, ls), 0.0) * k) * BRDF_GGX(normalize((viewMatrix * vec4(ls, 0.0)).xyz), geometryViewDir, geometryNormal, a3dM);',
      '  }',
      '  reflectedLight.directSpecular += min(a3dSpec, a3dCap);',
      '}'].join('\n'));
  };
  const patch = (m, fn, key) => { const base = m.onBeforeCompile; m.onBeforeCompile = (sh, r) => { base.call(m, sh, r); fn(sh, r); }; m.customProgramCacheKey = () => key; return m; };

  // materials
  const std = (color, rough, metal, extra) => { const m = own(new THREE.MeshStandardMaterial(Object.assign({ color, roughness: rough, metalness: metal }, extra || {}))); m.onBeforeCompile = lineLit; m.customProgramCacheKey = () => 'a3d-std'; return m; };
  const basic = (color, extra) => own(new THREE.MeshBasicMaterial(Object.assign({ color }, extra || {})));
  // a bundle of cables: many runs side by side, each a little lighter or darker
  const cableT = tex(keepCv((() => {
    const c = canvas(64, 4), x = c.getContext('2d'), r = rng(9);
    for (let i = 0; i < 64; i += 2) { const v = Math.round(150 + r() * 105); x.fillStyle = 'rgb(' + v + ',' + v + ',' + v + ')'; x.fillRect(i, 0, 2, 4); x.fillStyle = 'rgba(0,0,0,.35)'; x.fillRect(i + 1.6, 0, 0.4, 4); }
    return c;
  })()));
  const M = {
    frame: std(P.frame, P.frameRough, P.frameMetal),
    roof: std(P.frame, 0.78, 0.25),   // a cabinet's roof: painted, matte
    inner: std(P.inner, 0.8, 0.2),
    plinth: std(P.plinth, 0.7, 0.3),
    post: std(P.post, 0.42, 0.75),
    fixture: std(P.fixture, 0.36, 0.85),
    tray: std(P.tray, 0.4, 0.85),
    rod: std(P.tray, 0.5, 0.7),
    cableB: std(0xffffff, 0.62, 0, { color: P.cable[0], map: cableT }),
    cableY: std(0xffffff, 0.62, 0, { color: P.cable[1], map: cableT }),
    wall: std(P.wall, 0.95, 0, { emissive: P.wallWash, emissiveMap: own(new THREE.CanvasTexture((() => {
      // light from the ceiling washing down the walls
      const c = canvas(4, 256), x = c.getContext('2d'), g = x.createLinearGradient(0, 0, 0, 256);
      g.addColorStop(0, '#fff'); g.addColorStop(0.12, '#c8c8c8'); g.addColorStop(0.45, '#3a3a3a'); g.addColorStop(1, '#000');
      x.fillStyle = g; x.fillRect(0, 0, 4, 256); return keepCv(c);
    })())) }),
    ceil: std(P.ceil, 0.95, 0),
    body: std(P.body, 0.36, 0.8),
    plateEdge: std(P.face[1], 0.55, 0.4),
    rail: std(P.rail, 0.3, 0.85),
    lamp: basic(new THREE.Color(P.lamp).multiplyScalar(P.lampK)),
    wire: basic(dark ? 0x2a2f35 : 0x8e979f),
    bezel: std(dark ? 0x171a1f : 0x2a3036, 0.38, 0.8),   // anodised: the fittings show in it
    cart: std(P.cart[0], 0.45, 0.6),
    cartDark: std(P.cart[1], 0.6, 0.35),
    rubber: std(P.cart[2], 0.9, 0),
    benchTop: std(0xffffff, 0.7, 0.05, { map: tex(keepCv((() => { const c = canvas(512, 192), x = c.getContext('2d'); x.fillStyle = dark ? '#1b2a33' : '#5d7480'; x.fillRect(0, 0, 512, 192); x.strokeStyle = dark ? 'rgba(98,196,255,.16)' : 'rgba(255,255,255,.25)'; x.lineWidth = 1; for (let i = 0; i <= 512; i += 16) { x.beginPath(); x.moveTo(i, 0); x.lineTo(i, 192); x.stroke(); } for (let j = 0; j <= 192; j += 16) { x.beginPath(); x.moveTo(0, j); x.lineTo(512, j); x.stroke(); } x.fillStyle = dark ? '#2f6d8a' : '#2a5368'; x.fillRect(0, 0, 512, 6); x.fillRect(0, 186, 512, 6); return c; })())) }),
    monitor: std(dark ? 0x2a2f35 : 0x3a4148, 0.4, 0.55),
    benchLeg: std(P.bench[0], 0.4, 0.7),
  };
  M.postFaceL = std(0xffffff, 0.5, 0.45, { map: tex(keepCv(postTexture(P, perRack, 'right'))) });   // the left post's opening edge is on its right
  M.postFaceR = std(0xffffff, 0.5, 0.45, { map: tex(keepCv(postTexture(P, perRack, 'left'))) });
  const rearT = tex(keepCv(rearTexture(P)), { repeat: [1, Math.max(1, Math.round(perRack / 10))] });
  M.rear = std(0xffffff, 0.75, 0.2, { map: rearT, emissiveMap: rearT, emissive: 0xffffff, emissiveIntensity: P.rearLit });
  M.pdu = std(0xffffff, 0.6, 0.3, { map: tex(keepCv(rearPduTexture(P, dark))) });

  /* the hall: its floor, walls and roof, what hangs from the roof, the lights and the cable ladders */
  const shiftX = (((rowX0 % 0.6) + 0.6) % 0.6);
  const floorT = tex(keepCv(tileTexture(P, false)), { repeat: [1, 1] });
  /* The raised floor, matte: the seams between its tiles cut by the shader and box-filtered over
     each pixel (sharp near, a faint grid far off, never shimmering), each tile's edges bevelled to
     catch the light, and no two tiles quite alike: a shade lighter or darker, a little more or
     less worn, their speckle turned. The texture coordinates count tiles. */
  const tileFloor = (m, seed) => patch(m, sh => {
      sh.uniforms.uSeam = { value: new THREE.Color(P.seam) };
      sh.fragmentShader = '#define A3D_MATTE\n' + sh.fragmentShader
        .replace('#include <common>', '#include <common>\nuniform vec3 uSeam;\nfloat a3dHash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7)) + ' + seed.toFixed(1) + ') * 43758.5453); }')
        .replace('#include <map_fragment>', [
          'vec2 tc = vMapUv, tid = floor(tc), tf = tc - tid;',
          'float th = a3dHash(tid);',
          'vec2 tflip = step(0.5, vec2(fract(th * 7.31), fract(th * 3.17)));',
          'diffuseColor *= textureGrad(map, tid + mix(tf, 1.0 - tf, tflip), dFdx(tc), dFdy(tc));',
          'diffuseColor.rgb *= 0.96 + 0.08 * th;',
          'const float SEAM_N = 150.0;',
          'vec2 tw = max(fwidth(tc), vec2(1e-5));',
          'vec2 ta = tc + 0.5 / SEAM_N + 0.5 * tw, tb = tc + 0.5 / SEAM_N - 0.5 * tw;',
          'vec2 ti = clamp((floor(ta) + min(fract(ta) * SEAM_N, 1.0) - floor(tb) - min(fract(tb) * SEAM_N, 1.0)) / (SEAM_N * tw), 0.0, 1.0);',
          'diffuseColor.rgb = mix(uSeam, diffuseColor.rgb, (1.0 - ti.x) * (1.0 - ti.y));'].join('\n'))
        .replace('#include <roughnessmap_fragment>', '#include <roughnessmap_fragment>\n  roughnessFactor = clamp(roughnessFactor + (th - 0.5) * 0.06, 0.0, 1.0);')
        .replace('#include <normal_fragment_maps>', [
          '#include <normal_fragment_maps>',
          '{',
          '  vec2 ed = min(tf, 1.0 - tf) * 0.6, sg = sign(tf - 0.5);',
          '  vec2 bev = (1.0 - smoothstep(0.002, 0.009, ed)) * step(0.002, ed);',
          '  float near = 1.0 - smoothstep(0.003, 0.012, max(tw.x, tw.y) * 0.6);',
          '  vec3 tx = normalize((viewMatrix * vec4(1.0, 0.0, 0.0, 0.0)).xyz), tz = normalize((viewMatrix * vec4(0.0, 0.0, -1.0, 0.0)).xyz);',
          '  normal = normalize(normal + 0.8 * near * (bev.x * sg.x * tx + bev.y * sg.y * tz));',
          '}'].join('\n'));
  }, 'a3d-floor-' + seed);
  const floorRough = P.floorRough;
  // floor in tile units: u along x, v along -z, one tile a unit, the seams on the grid the rows stand on
  const tileGeo = rects => {
    const pos = [], uv = [], idx = [];
    for (const [x0, x1, z0, z1] of rects) {
      const b = pos.length / 3;
      for (const [x, z] of [[x0, z0], [x0, z1], [x1, z1], [x1, z0]]) { pos.push(x, 0, z); uv.push((x - shiftX) / 0.6, -z / 0.6); }
      idx.push(b, b + 1, b + 2, b, b + 2, b + 3);
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    g.setAttribute('normal', new THREE.Float32BufferAttribute(pos.map((v, i) => (i % 3 === 1 ? 1 : 0)), 3));
    g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
    g.setIndex(idx); g.computeBoundingSphere();
    return own(g);
  };
  scene.add(new THREE.Mesh(tileGeo(corridor ? [[HX0, HX1, HZ0, HZ1], [endL, HX0, FZ0, FZ1]] : [[HX0, HX1, HZ0, HZ1]]), tileFloor(std(0xffffff, floorRough, 0, { map: floorT }), 1)));
  // a row of perforated tiles in front of every row: the cold air comes up through them
  const perfT = tex(keepCv(tileTexture(P, true)), { repeat: [1, 1] });
  const perfM = tileFloor(std(0xffffff, floorRough, 0.15, { map: perfT, polygonOffset: true, polygonOffsetFactor: -1, polygonOffsetUnits: -1 }), 2);
  const perfR = [], sx0 = corridor ? rowX0 : rowX0 - 2 * PITCH, sx1 = corridor ? rowX1 : rowX1 + 2 * PITCH;
  for (const r of rowsZ) {
    const z0 = r.dir > 0 ? r.z : r.z - 0.6;
    if (!r.hall) perfR.push([sx0, sx1, z0, z0 + 0.6]); else for (const b of blocks) perfR.push([b[0] - PITCH / 2, b[1] + PITCH / 2, z0, z0 + 0.6]);
  }
  const strips = new THREE.Mesh(tileGeo(perfR), perfM); strips.position.y = 0.0005;
  scene.add(strips);

  const parts = new Map();
  const add = (key, g, m) => { if (!parts.has(key)) parts.set(key, []); parts.get(key).push({ g, m }); };
  const _q = new THREE.Quaternion(), _e = new THREE.Euler(), _s = new THREE.Vector3(1, 1, 1), _p = new THREE.Vector3();
  const mat4 = (x, y, z, ry = 0, rx = 0) => new THREE.Matrix4().compose(_p.set(x, y, z), _q.setFromEuler(_e.set(rx, ry, 0)), _s);
  const box = (key, base, w, h, d, x, y, z) => add(key, new THREE.BoxGeometry(w, h, d), base.clone().multiply(mat4(x, y, z)));
  const plane = (key, base, w, h, x, y, z, ry = 0, rx = 0) => add(key, new THREE.PlaneGeometry(w, h), base.clone().multiply(mat4(x, y, z, ry, rx)));
  const cyl = (key, base, r0, r1, h, x, y, z, seg = 14) => add(key, new THREE.CylinderGeometry(r0, r1, h, seg), base.clone().multiply(mat4(x, y, z)));

  const I4 = new THREE.Matrix4();
  // what hangs from the roof hangs from a strut: one runs the hall's length wherever something hangs
  const strutZ = new Set();
  const hangTop = x => (corridor && x < HX0 ? FH : HANG);
  const hang = (x, y0, z, t, key) => {
    const top = hangTop(x);
    box(key || 'wire', I4, t || 0.004, top - y0, t || 0.004, x, (top + y0) / 2, z);
    if (top === HANG) strutZ.add(Math.round(z * 100) / 100);
  };
  /* the building: glass on the long sides down to a sill, the operations wall solid at the far end;
     in the corridor a glass foyer at the near end, the doors in its front */
  const glassParts = [], OBS = [];   // OBS: what stands on the floor, [x0, z0, x1, z1] (for the visitor)
  const curtain = (cx, cz, len, ry, h, door) => {
    const B = mat4(cx, 0, cz, ry), gh = h - 0.5;
    const sill = (a, b) => plane('sill', B, b - a, 0.9, (a + b) / 2, 0.45, 0);
    if (door) { sill(-len / 2, door[0]); sill(door[1], len / 2); } else sill(-len / 2, len / 2);
    plane('sill', B, len, 0.5, 0, h - 0.25, 0);
    glassParts.push({ g: new THREE.PlaneGeometry(len, gh), m: B.clone().multiply(mat4(0, gh / 2, -0.012)) });
    const n = Math.max(1, Math.round(len / 1.8));
    for (let i = 0; i <= n; i++) box('mull', B, 0.07, gh, 0.1, -len / 2 + i * len / n, gh / 2, -0.03);
    for (const y of h > 5 ? [0.9, 3.4, 5.9] : [0.9, h - 0.5]) {
      if (door && y < 2) { box('mull', B, door[0] + len / 2, 0.06, 0.1, (door[0] - len / 2) / 2, y, -0.03); box('mull', B, len / 2 - door[1], 0.06, 0.1, (door[1] + len / 2) / 2, y, -0.03); }
      else box('mull', B, len, 0.06, 0.1, 0, y, -0.03);
    }
  };
  const hx = (HX0 + HX1) / 2, hl = HX1 - HX0, hz = (HZ0 + HZ1) / 2, hw = HZ1 - HZ0;
  curtain(hx, HZ0, hl, 0, HH);
  curtain(hx, HZ1, hl, Math.PI, HH);
  plane('wall', I4, hw, HH, HX1, HH / 2, hz, -Math.PI / 2);
  plane('deck', I4, hl, hw, hx, HH, hz, 0, Math.PI / 2);
  if (corridor) {
    curtain(HX0, (HZ0 + FZ0) / 2, FZ0 - HZ0, Math.PI / 2, HH);
    curtain(HX0, (FZ1 + HZ1) / 2, HZ1 - FZ1, Math.PI / 2, HH);
    plane('wall', I4, FZ1 - FZ0, HH - FH, HX0, (HH + FH) / 2, OPP_Z / 2, Math.PI / 2);   // over the foyer's opening
    const fl = HX0 - endL, fx = (HX0 + endL) / 2;
    curtain(fx, FZ0, fl, 0, FH);
    curtain(fx, FZ1, fl, Math.PI, FH);
    curtain(endL, OPP_Z / 2, FZ1 - FZ0, Math.PI / 2, FH, [-1.0, 1.0]);
    plane('ceil', I4, fl, FZ1 - FZ0, fx, FH, OPP_Z / 2, 0, Math.PI / 2);
    // the doors: their frame, where the two glass leaves meet, the pull handles
    const DB = mat4(endL, 0, OPP_Z / 2, Math.PI / 2);
    for (const sd of [-1, 1]) { box('mull', DB, 0.1, 2.3, 0.12, sd * 1.0, 1.15, -0.03); box('rail', DB, 0.025, 0.8, 0.035, sd * 0.1, 1.05, 0.02); }
    box('mull', DB, 2.1, 0.1, 0.12, 0, 2.3, -0.03);
    box('mull', DB, 0.035, 2.25, 0.06, 0, 1.12, -0.02);
    // the reception desk by the glass, a screen on it
    box('desk', I4, 2.0, 1.04, 0.6, -5.1, 0.52, FZ1 - 0.5); box('deskTop', I4, 2.1, 0.04, 0.72, -5.1, 1.06, FZ1 - 0.5);
    box('monitor', I4, 0.5, 0.32, 0.03, -5.5, 1.32, FZ1 - 0.62); box('monitor', I4, 0.06, 0.14, 0.06, -5.5, 1.13, FZ1 - 0.6);
    OBS.push([-6.15, FZ1 - 0.86, -4.05, FZ1]);
  } else plane('wall', I4, hw, HH, endL, HH / 2, hz, Math.PI / 2);
  // two lines of light over the corridor: fittings 1.2 m long on a 1.8 m pitch, each hung on two wires
  const lampLen = corridor ? endR - endL - 0.8 : rowX1 - rowX0 + 4 * PITCH;
  const FIT = 1.2, FIT_P = 1.8, nFit = Math.max(1, Math.floor((lampLen - FIT) / FIT_P) + 1);
  const fit0 = midX - (nFit - 1) * FIT_P / 2;
  LINE.uA3dExt.value.set(fit0 - FIT / 2, fit0 + (nFit - 1) * FIT_P + FIT / 2);
  for (const z of [1.05, OPP_Z - 1.05]) for (let i = 0; i < nFit; i++) {
    const x = fit0 + i * FIT_P;
    box('fixture', I4, FIT, 0.05, 0.12, x, 2.925, z);
    box('fixture', I4, FIT + 0.01, 0.012, 0.128, x, 2.906, z);   // the frame round the diffuser
    plane('lamp', I4, FIT - 0.04, 0.09, x, 2.8995, z, 0, Math.PI / 2);
    for (const dx of [-FIT * 0.4, FIT * 0.4]) hang(x + dx, 2.95, z);
  }
  // the cable ladders over each row: two channel rails, rungs, the cables laid in them, hung on rods;
  // over the corridor's rows a drop of cable into each cabinet's roof
  const trayLen = corridor ? rowX1 - rowX0 + 1.2 : lampLen, trayX = corridor ? (rowX0 + rowX1) / 2 : midX;
  const TRAY_Y = 2.62;
  const lenX = (key, r, len, x, y, z, seg) => add(key, new THREE.CylinderGeometry(r, r, len, seg || 10, 1, true), new THREE.Matrix4().compose(_p.set(x, y, z), _q.setFromEuler(_e.set(0, 0, Math.PI / 2)), _s));
  const ladder = (z, len, cx, step) => {
    for (const sz of [-1, 1]) {
      box('tray', I4, len, 0.064, 0.006, cx, TRAY_Y + 0.032, z + sz * 0.118);
      for (const y of [TRAY_Y + 0.003, TRAY_Y + 0.061]) box('tray', I4, len, 0.006, 0.024, cx, y, z + sz * 0.106);
    }
    for (let x = cx - len / 2 + 0.12; x < cx + len / 2; x += step) box('tray', I4, 0.024, 0.012, 0.226, x, TRAY_Y + 0.008, z);
    for (let x = cx - len / 2 + 0.4; x < cx + len / 2; x += 1.2) {
      for (const sz of [-1, 1]) hang(x, TRAY_Y - 0.02, z + sz * 0.135, 0.008, 'rod');
      box('tray', I4, 0.032, 0.02, 0.3, x, TRAY_Y - 0.012, z);
    }
    lenX('cableB', 0.034, len, cx, TRAY_Y + 0.048, z - 0.045);
    lenX('cableB', 0.022, len, cx, TRAY_Y + 0.036, z + 0.04);
    lenX('cableY', 0.018, len, cx, TRAY_Y + 0.032, z + 0.085);
  };
  for (const z of [-0.55, OPP_Z + 0.55]) ladder(z, trayLen, trayX, 0.3);
  for (const r of rowsZ) if (r.hall) ladder(r.z - r.dir * RACK_D / 2, bx1 - bx0 + 1.2, (bx0 + bx1) / 2, 0.6);
  /* the roof's steel: a beam across the hall over each column, columns in the hot aisles (never in a
     cross aisle), the struts; red sprinkler mains, two ducts */
  for (const b of blocks) {
    const x = (b[0] + b[1]) / 2;
    for (const a of aisles) if (Math.abs(a[1] - a[0] - HOT) < 0.05) {
      const z = (a[0] + a[1]) / 2;
      box('steel', I4, 0.34, HH - 0.7, 0.34, x, (HH - 0.7) / 2, z); box('steel', I4, 0.5, 0.03, 0.5, x, 0.015, z);
      OBS.push([x - 0.25, z - 0.25, x + 0.25, z + 0.25]);
    }
    box('steel', I4, 0.014, 0.46, hw, x, HH - 0.47, hz);
    for (const y of [HH - 0.24, HH - 0.7]) box('steel', I4, 0.2, 0.024, hw, x, y, hz);
  }
  const mains = [OPP_Z / 2, ...lines.filter(l => l[3] && l[2] - l[1] > 1.7).map(l => l[0])];
  for (const z of mains) {
    lenX('sprink', 0.045, hl, hx, HANG - 0.12, z, 12); strutZ.add(Math.round(z * 100) / 100);
    for (let x = HX0 + 1.5; x < HX1; x += 3) { box('sprink', I4, 0.024, 0.26, 0.024, x, HANG - 0.29, z); box('rail', I4, 0.05, 0.03, 0.05, x, HANG - 0.43, z); }
  }
  const hots = aisles.filter(a => Math.abs(a[1] - a[0] - HOT) < 0.05).map(a => (a[0] + a[1]) / 2);
  for (const z of [Math.min(...hots), Math.max(...hots)]) { box('duct', I4, hl - 1, 0.55, 0.9, hx, HANG - 0.75, z); for (let x = HX0 + 1.2; x < HX1 - 1; x += 2.4) for (const sz of [-1, 1]) hang(x, HANG - 0.48, z + sz * 0.47, 0.01, 'rod'); }
  const drops = (x, z, dir) => {
    const top = TRAY_Y + 0.02, bot = RACK_H - 0.01, zz = z - dir * 0.47;
    add('cableB', new THREE.CylinderGeometry(0.02, 0.02, top - bot, 8, 1, true), mat4(x - 0.13, (top + bot) / 2, zz));
    add('cableY', new THREE.CylinderGeometry(0.011, 0.011, top - bot, 8, 1, true), mat4(x + 0.12, (top + bot) / 2, zz - dir * 0.05));
  };

  // a cabinet: its frame, sides, roof, back, plinth; open fronts get posts, the rest a door
  function cabinet(base, isOpen) {
    const hw = RACK_W / 2;
    box('frame', base, SIDE_T, RACK_H, RACK_D, -hw + SIDE_T / 2, RACK_H / 2, -RACK_D / 2);
    box('frame', base, SIDE_T, RACK_H, RACK_D, hw - SIDE_T / 2, RACK_H / 2, -RACK_D / 2);
    box('roof', base, RACK_W, 0.014, RACK_D, 0, RACK_H - 0.007, -RACK_D / 2);
    box('plinth', base, RACK_W - 0.03, PLINTH_H, RACK_D - 0.06, 0, PLINTH_H / 2, -RACK_D / 2 - 0.005);
    if (!isOpen) return;
    const uh = perRack * U, cy = BASE_Y + uh / 2, bw = hw - (OPEN_HALF + POST_W);
    box('inner', base, RACK_W - 2 * SIDE_T, RACK_H - PLINTH_H, 0.012, 0, PLINTH_H + (RACK_H - PLINTH_H) / 2, -RACK_D + 0.02);
    plane('rear', base, 2 * OPEN_HALF + 2 * POST_W, uh, 0, cy, -RACK_D + 0.0265);
    for (const sx of [-1, 1]) {
      box('post', base, 0.05, uh * 0.86, 0.045, sx * 0.17, cy, -RACK_D + 0.075);
      plane('pdu', base, 0.032, uh * 0.86 - 0.02, sx * 0.17, cy, -RACK_D + 0.0976);
    }
    box('frame', base, RACK_W, TOP_H, FRAME_D, 0, unitsTop + TOP_H / 2, -FRAME_D / 2);
    box('frame', base, RACK_W, BASE_Y - PLINTH_H, FRAME_D, 0, PLINTH_H + (BASE_Y - PLINTH_H) / 2, -FRAME_D / 2);
    box('frame', base, bw, uh, FRAME_D, -(OPEN_HALF + POST_W + bw / 2), cy, -FRAME_D / 2);
    box('frame', base, bw, uh, FRAME_D, OPEN_HALF + POST_W + bw / 2, cy, -FRAME_D / 2);
    box('inner', base, 2 * OPEN_HALF + 2 * POST_W, 0.01, RACK_D - 0.05, 0, BASE_Y - 0.005, -RACK_D / 2);
    box('inner', base, 2 * OPEN_HALF + 2 * POST_W, 0.01, RACK_D - 0.05, 0, unitsTop + 0.005, -RACK_D / 2);
    // the marquee's housing on the top frame
    box('bezel', base, 0.56, 0.08, 0.012, 0, unitsTop + 0.052, 0.006);
    for (const sx of [-1, 1]) {
      const x = sx * (OPEN_HALF + POST_W / 2);
      box('post', base, POST_W, uh + 0.02, POST_D, x, cy, -RECESS - POST_D / 2);
      box('post', base, POST_W, uh + 0.02, POST_D, x, cy, -RACK_D + 0.12);
      plane(sx < 0 ? 'postFaceL' : 'postFaceR', base, POST_W, uh, x, cy, -RECESS + 0.0004);
      box('inner', base, 0.006, uh, RACK_D - 0.2, sx * (OPEN_HALF + POST_W + 0.004), cy, -RACK_D / 2 - 0.02);
    }
  }
  const rackMat = R => mat4(R.x, 0, R.z, R.dir < 0 ? Math.PI : 0);
  for (const R of racks) { cabinet(rackMat(R), true); drops(R.x, R.z, R.dir); }
  // the neighbours: closed cabinets at the ends of each run, and across the aisle in the one aisle
  const doors = [];
  const doorSpots = closed.map(([x, z, dir]) => { const m = mat4(x, 0, z, dir < 0 ? Math.PI : 0); cabinet(m, false); drops(x, z, dir); return m; });
  // the doors: perforated steel, or (one kind in three) smoked glass. The equipment behind sits a few
  // centimetres back and shifts behind the door as you walk past; its lights glow (with the bloom; on
  // a phone, flat and with their halos, as before)
  const doorKinds = [doorTexture(P, 11, dark, false), doorTexture(P, 29, dark, false), doorTexture(P, 47, dark, true)];
  const doorW = RACK_W - 0.012, doorH = RACK_H - PLINTH_H - 0.012;
  doorKinds.forEach((d, i) => {
    const glass = i === 2, inT = tex(keepCv(d.inner));
    M['door' + i] = patch(std(0xffffff, 0.55, 0.35, { map: tex(keepCv(d.sheet)) }), sh => {
      sh.uniforms.tInner = { value: inT };
      sh.uniforms.uDoor = { value: new THREE.Vector4(doorW, doorH, post ? 0.035 : 0, glass ? 0.6 : 0.9) };
      sh.fragmentShader = 'uniform sampler2D tInner;\nuniform vec4 uDoor;\n' + sh.fragmentShader
        .replace('#include <map_fragment>', [
          'vec4 dSheet = texture2D(map, vMapUv);',
          'vec3 dV = normalize(cameraPosition - vA3dW), dN = normalize(inverseTransformDirection(vNormal, viewMatrix));',
          'vec2 dOff = -vec2(dot(dV, vec3(dN.z, 0.0, -dN.x)), dV.y) / max(dot(dV, dN), 0.2) * uDoor.z / uDoor.xy;',
          'vec3 dIn = texture2D(tInner, clamp(vMapUv + dOff, 0.0, 1.0)).rgb;',
          'diffuseColor.rgb *= dSheet.rgb * dSheet.a;',
          'vec3 dGlow = dIn * (1.0 - dSheet.a) * uDoor.w * (1.0 + smoothstep(0.35, 0.75, max(dIn.r, max(dIn.g, dIn.b))) * ' + (post ? '2.5' : '0.3') + ');'].join('\n'))
        .replace('#include <emissivemap_fragment>', '#include <emissivemap_fragment>\n  totalEmissiveRadiance += dGlow;')
        .replace('#include <metalnessmap_fragment>', '#include <metalnessmap_fragment>\n  metalnessFactor *= dSheet.a;')
        .replace('#include <roughnessmap_fragment>', '#include <roughnessmap_fragment>\n  roughnessFactor = mix(' + (glass ? '0.06' : '0.8') + ', roughnessFactor, dSheet.a);');
    }, 'a3d-door-' + (glass ? 'glass' : 'mesh'));
  });
  doorSpots.forEach((m, i) => {
    const kind = (i * 7 + 3) % 3;
    plane('door' + kind, m, doorW, doorH, 0, PLINTH_H + 0.006 + doorH / 2, 0.006);
    doors.push({ m, kind });
  });

  /* the comparison bench, against the near end wall: a workbench under its own lamp */
  {
    const B = BENCH.m, L = BENCH.L, D = BENCH.D;
    box('benchTop', B, L, 0.04, D, 0, BENCH_Y - 0.02, 0);
    box('benchLeg', B, L - 0.06, 0.03, 0.04, 0, BENCH_Y - 0.06, D / 2 - 0.05);
    for (const sx of [-1, 1]) for (const sz of [-1, 1]) box('benchLeg', B, 0.045, BENCH_Y - 0.04, 0.045, sx * (L / 2 - 0.08), (BENCH_Y - 0.04) / 2, sz * (D / 2 - 0.07));
    box('benchLeg', B, L - 0.2, 0.025, D - 0.2, 0, 0.16, 0);
    box('benchLeg', B, L, 0.5, 0.025, 0, BENCH_Y + 0.25, -D / 2 + 0.0125);
    box('fixture', B, L * 0.9, 0.05, 0.12, 0, 2.55, 0.12);
    plane('lamp', B, L * 0.9 - 0.02, 0.08, 0, 2.524, 0.12, 0, Math.PI / 2);
    const top = hangTop(BENCH.x);
    for (const sx of [-1, 1]) { box('wire', B, 0.004, top - 2.58, 0.004, sx * L * 0.4, (top + 2.58) / 2, 0.12); if (top === HANG) strutZ.add(Math.round(new THREE.Vector3(sx * L * 0.4, 0, 0.12).applyMatrix4(B).z * 100) / 100); }
    OBS.push(corridor ? [BENCH.x - L / 2, BENCH.z - D / 2, BENCH.x + L / 2, BENCH.z + D / 2] : [BENCH.x - D / 2, BENCH.z - L / 2, BENCH.x + D / 2, BENCH.z + L / 2]);
  }

  /* the hall's rows: a shell and a door per cabinet, instanced. The first row out on each side wears
     the corridor's doors (the equipment behind them in parallax); further out, one flat door. The
     far rows and the near ring outside are the first things a slow machine gives up. */
  const hallG = new THREE.Group(), hallFar = new THREE.Group();
  scene.add(hallG, hallFar);
  const inst = (geo, mat, list, group) => {
    if (!list.length) return null;
    const im = new THREE.InstancedMesh(geo, mat, list.length);
    list.forEach((m, i) => im.setMatrixAt(i, m));
    im.computeBoundingSphere();
    group.add(im);
    return im;
  };
  {
    const far = canvas(256, 850), fc = far.getContext('2d');
    fc.drawImage(doorKinds[0].inner, 0, 0, 256, 850); fc.drawImage(doorKinds[0].sheet, 0, 0, 256, 850);
    const farT = tex(keepCv(far));
    M.doorFar = std(0xffffff, 0.6, 0.3, { map: farT, emissiveMap: farT, emissive: 0xffffff, emissiveIntensity: dark ? 0.6 : 0.12 });
    const shellGeo = own(new THREE.BoxGeometry(RACK_W - 0.004, RACK_H, RACK_D).translate(0, RACK_H / 2, -RACK_D / 2));
    shellGeo.clearGroups(); shellGeo.addGroup(0, 12, 0); shellGeo.addGroup(12, 6, 1); shellGeo.addGroup(18, 18, 0);   // the roof (+y) matte
    const doorGeo = own(new THREE.PlaneGeometry(doorW, doorH).translate(0, PLINTH_H + 0.006 + doorH / 2, 0.006));
    const near = [[], [], []], farL = [], shN = [], shF = [];
    let k = 0;
    for (const r of rowsZ) if (r.hall) for (const b of blocks) {
      const [z0, z1] = rspan(r);
      OBS.push([b[0] - PITCH / 2, z0, b[1] + PITCH / 2, z1]);
      for (let x = b[0]; x <= b[1] + 1e-6; x += PITCH) {
        const m = mat4(x, 0, r.z, r.dir < 0 ? Math.PI : 0);
        if (r.near) { shN.push(m); near[(k++ * 7 + 3) % 3].push(m); } else { shF.push(m); farL.push(m); }
      }
    }
    inst(shellGeo, [M.frame, M.roof], shN, hallG); inst(shellGeo, [M.frame, M.roof], shF, hallFar);
    near.forEach((l, i) => inst(doorGeo, M['door' + i], l, hallG));
    inst(doorGeo, M.doorFar, farL, hallFar);
  }
  // the corridor's own cabinets stand on the floor too
  for (const [x, z, dir] of closed.concat(racks.map(R => [R.x, R.z, R.dir]))) { const s = rspan({ z, dir }); OBS.push([x - RACK_W / 2, s[0], x + RACK_W / 2, s[1]]); }
  const coldBand = basic(new THREE.Color(P.ledB).multiplyScalar(dark ? 1.4 : 1));
  M.coldBand = coldBand; M.ledG = basic(new THREE.Color(P.ledG).multiplyScalar(2)); M.ledR = basic(new THREE.Color(P.ledR).multiplyScalar(2.2));
  // aisle containment on the outer cold aisles: glass doors at each end, a glass roof; a badge reader
  const coldA = aisles.filter(a => Math.abs(a[1] - a[0] - COLD) < 0.05);
  const visitA = coldA.filter(a => a[1] < 0).sort((p, q) => q[1] - p[1])[0];   // the one nearest behind the racks stays open: the visitor walks it
  if (!small) for (const a of coldA) if (a !== visitA) for (const b of blocks) {
    const x0 = b[0] - PITCH / 2, x1 = b[1] + PITCH / 2, w = a[1] - a[0], zc = (a[0] + a[1]) / 2;
    glassParts.push({ g: new THREE.PlaneGeometry(x1 - x0, w), m: mat4((x0 + x1) / 2, RACK_H, zc, 0, Math.PI / 2) });
    for (const [x, sd] of [[x0, -1], [x1, 1]]) {
      for (const zz of [a[0] + 0.03, a[1] - 0.03]) box('mull', I4, 0.05, RACK_H, 0.05, x, RACK_H / 2, zz);
      box('mull', I4, 0.06, 0.14, w, x, RACK_H - 0.07, zc); box('coldBand', I4, 0.064, 0.03, w - 0.12, x, RACK_H - 0.1, zc);
      glassParts.push({ g: new THREE.PlaneGeometry(w - 0.08, RACK_H - 0.16), m: mat4(x, (RACK_H - 0.16) / 2, zc, Math.PI / 2) });
      box('mull', I4, 0.03, RACK_H - 0.16, 0.025, x, (RACK_H - 0.16) / 2, zc);
      box('bezel', I4, 0.03, 0.12, 0.08, x + sd * 0.04, 1.2, a[0] + 0.2); box('ledG', I4, 0.034, 0.012, 0.012, x + sd * 0.04, 1.25, a[0] + 0.2);
    }
  }
  // a sign on each end of every row, its letter (the corridor's own two rows are the sections')
  {
    const hr = rowsZ.filter(r => r.hall).sort((p, q) => p.z - q.z), nb = hr.filter(r => r.z < 0).length;
    const rc = canvas(512, 96 * Math.ceil(hr.length / 2)), rx = rc.getContext('2d');
    hr.forEach((r, i) => {
      const cx = (i % 2) * 256, cy = Math.floor(i / 2) * 96;
      rx.fillStyle = P.plate; rx.fillRect(cx, cy, 256, 96);
      rx.strokeStyle = P.plateLine; rx.lineWidth = 4; rx.strokeRect(cx + 2, cy + 2, 252, 92);
      rx.fillStyle = P.ledB; rx.fillRect(cx + 22, cy + 28, 10, 40);
      rx.fillStyle = P.plateText; rx.font = '650 46px ' + FONT_SANS; rx.textAlign = 'left';
      const t = 'Row ' + 'ABCDGHJKLM'[i < nb ? 4 - nb + i : 4 + (i - nb)];
      rx.fillText(t, cx + 50, centreY(rx, t, cy + 48));
      const u0 = (i % 2) / 2, v1 = 1 - Math.floor(i / 2) * 96 / rc.height, v0 = v1 - 96 / rc.height;
      for (const [x, ry] of [[bx0 - 0.006, -Math.PI / 2], [bx1 + 0.006, Math.PI / 2]]) {
        const g = new THREE.PlaneGeometry(0.5, 0.1875), uv = g.attributes.uv;
        for (let j = 0; j < uv.count; j++) uv.setXY(j, u0 + uv.getX(j) * 0.5, v0 + uv.getY(j) * (v1 - v0));
        add('rowSign', g, mat4(x, RACK_H + 0.13, r.z - r.dir * RACK_D / 2, ry));
        box('bezel', I4, 0.03, 0.04, 0.3, x - Math.sign(ry) * 0.012, RACK_H + 0.02, r.z - r.dir * RACK_D / 2);
      }
    });
    const rt = tex(keepCv(rc));
    M.rowSign = P.plateLit ? basic(0xffffff, { map: rt }) : std(0xffffff, 0.72, 0.1, { map: rt });
  }
  // the cooling units along the glass walls, hazard stripes on the floor in front of them, the
  // walkway's yellow line; exits signed in green; cameras on the roof's struts; extinguishers
  {
    const crahs = [], n = Math.max(1, Math.round((bx1 - bx0) / 4.4));
    for (const [z, ry, sd] of [[HZ0 + 1.0, 0, 1], [HZ1 - 1.0, Math.PI, -1]]) {
      for (let i = 0; i < n; i++) {
        const x = bx0 + (i + 0.5) * (bx1 - bx0) / n;
        crahs.push(mat4(x, 0, z, ry));
        OBS.push([x - 1.2, Math.min(z, z - sd * 0.9), x + 1.2, Math.max(z, z - sd * 0.9)]);
        plane('hazard', I4, 2.4, 0.42, x, 0.002, z + sd * 0.24, 0, -Math.PI / 2);
      }
      plane('yellow', I4, bx1 - bx0, 0.07, (bx0 + bx1) / 2, 0.002, z + sd * 0.75, 0, -Math.PI / 2);
    }
    M.crah = std(P.crah[0], 0.55, 0.3);
    M.crahFace = std(0xffffff, 0.6, 0.3, { map: tex(keepCv(crahTexture(P))) });
    inst(own(new THREE.BoxGeometry(2.4, 1.95, 0.9).translate(0, 0.975, -0.45)), M.crah, crahs, hallG);
    inst(own(new THREE.PlaneGeometry(2.3, 1.85).translate(0, 0.975, 0.004)), M.crahFace, crahs, hallG);
    M.hazard = std(0xffffff, 0.85, 0, { map: tex(keepCv(hazardTexture()), { repeat: [8, 1] }), polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2 });
    M.yellow = std(0xf2c200, 0.85, 0, { polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2 });
    const exitM = basic(new THREE.Color(1, 1, 1).multiplyScalar(1.5), { map: tex(keepCv(exitTexture())) });
    M.exit = exitM;
    const exitAt = (x, y, z, ry, hung) => {
      const B = mat4(x, y, z, ry);
      box('bezel', B, 0.42, 0.23, 0.04, 0, 0, -0.02); plane('exit', B, 0.38, 0.19, 0, 0, 0.001);
      if (hung) for (const s of [-0.15, 0.15]) { const p = new THREE.Vector3(s, 0, 0).applyMatrix4(B); hang(p.x, y + 0.11, p.z); }
    };
    if (corridor) exitAt(endL + 0.05, 2.55, OPP_Z / 2, Math.PI / 2, false);
    for (const z of [HZ0 + 1.75, HZ1 - 1.75]) { exitAt(HX0 + 0.9, 2.75, z, Math.PI / 2, true); exitAt(HX1 - 0.9, 2.75, z, -Math.PI / 2, true); }
    M.dome = std(0x08090b, 0.1, 0.3);
    const domeG = new THREE.SphereGeometry(0.075, 16, 8, 0, Math.PI * 2, Math.PI / 2, Math.PI / 2);
    const cam = (x, y, z, hung) => {
      add('dome', domeG.clone(), mat4(x, y, z)); cyl('fixture', I4, 0.09, 0.09, 0.03, x, y + 0.015, z, 16); box('ledR', I4, 0.012, 0.012, 0.012, x + 0.05, y - 0.02, z + 0.03);
      if (hung) hang(x, y + 0.03, z, 0.02, 'rod');
    };
    for (const b of blocks) cam((b[0] + b[1]) / 2 + 0.3, 3.4, OPP_Z / 2 + 0.85, true);
    for (const a of coldA) cam((bx0 + bx1) / 2, 3.4, (a[0] + a[1]) / 2, true);
    if (corridor) for (const z of [FZ0 + 0.5, FZ1 - 0.5]) cam(endL + 0.6, FH, z, false);
    domeG.dispose();
    M.ext = std(0xc4261d, 0.38, 0.15); M.extSign = basic(0xd62f24);
    const ext = (x, z, ry) => {
      const B = mat4(x, 0, z, ry);
      cyl('ext', B, 0.085, 0.085, 0.5, 0, 0.55, 0.1, 16); box('rubber', B, 0.05, 0.08, 0.12, 0, 0.84, 0.12); box('rubber', B, 0.02, 0.36, 0.02, 0.07, 0.62, 0.17);
      plane('extSign', B, 0.16, 0.16, 0, 1.6, 0.012);
    };
    if (corridor) { ext(HX0 - 0.2, FZ0 + 0.012, 0); ext(-6.6, FZ1 - 0.012, Math.PI); }
    for (const b of blocks) for (const a of aisles) if (Math.abs(a[1] - a[0] - HOT) < 0.05 && Math.abs((a[0] + a[1]) / 2 + RACK_D + HOT / 2) < 0.01) ext((b[0] + b[1]) / 2 + 0.17, (a[0] + a[1]) / 2, Math.PI / 2);
    if (corridor) { box('bezel', I4, 0.03, 0.12, 0.08, endL + 0.06, 1.2, OPP_Z / 2 + 1.3); box('ledG', I4, 0.034, 0.012, 0.012, endL + 0.06, 1.25, OPP_Z / 2 + 1.3); }
  }
  // the struts, now that everything that hangs from them is placed; and over the corridor the signs' wires
  if (corridor) for (const zs of [OPP_Z / 2 - 0.62, OPP_Z / 2 + 0.62]) for (const dz of [-0.755, 0.755]) strutZ.add(Math.round((zs + dz) * 100) / 100);
  for (const z of strutZ) box('steel', I4, hl, 0.04, 0.04, hx, HANG + 0.02, z);
  Object.assign(M, {
    sill: std(P.wall, 0.9, 0), deck: std(P.deck, 0.9, 0.2), mull: std(P.mull, 0.4, 0.7), steel: std(P.steel, 0.6, 0.35),
    sprink: std(P.sprink, 0.45, 0.25), duct: std(P.duct, 0.42, 0.85), desk: std(P.desk[0], 0.6, 0.1), deskTop: std(P.desk[1], 0.45, 0.05),
  });
  // the glass, all of it one mesh: the walls, the containment
  hallG.add(new THREE.Mesh(own(mergeParts(glassParts)), own(new THREE.MeshStandardMaterial({ color: P.glass[0], transparent: true, opacity: P.glass[1], roughness: 0.05, metalness: 0, depthWrite: false, side: THREE.DoubleSide }))));
  // outside: a sky that keeps its distance (it goes where the camera goes), a nearer ring of city
  // or campus that does not, and the ground out there
  const skyW = small ? 1024 : 2048;
  const sky = new THREE.Mesh(own(new THREE.CylinderGeometry(70, 70, 80, 48, 1, true)), basic(0xffffff, { map: tex(keepCv(skyTexture(P, skyW, skyW / 4)), { repeat: [2, 1] }), side: THREE.BackSide, fog: false, depthWrite: false }));
  sky.position.y = 20; sky.renderOrder = -2;
  const ring = new THREE.Mesh(own(new THREE.CylinderGeometry(58, 58, 30, 48, 1, true)), basic(0xffffff, { map: tex(keepCv(nearTexture(P, skyW, skyW / 8)), { repeat: [2, 1] }), side: THREE.BackSide, fog: false, transparent: true, depthWrite: false }));
  ring.position.set(midX, 14, hz);
  const ground = new THREE.Mesh(own(new THREE.PlaneGeometry(400, 400)), basic(P.ground));
  ground.rotation.x = -Math.PI / 2; ground.position.set(midX, -0.05, hz);
  scene.add(sky, ground); hallFar.add(ring);
  for (const [key, list] of parts) {
    const mesh = new THREE.Mesh(own(mergeParts(list)), M[key]);
    mesh.matrixAutoUpdate = false;
    scene.add(mesh);
  }

  /* each rack's own hardware: its plate, a marquee of its stats, a power strip
     with its language mix, a floor strip warmed by its average share */
  const onRack = (mesh, R, lx, ly, lz) => { mesh.position.set(R.x + R.dir * lx, ly, R.z + R.dir * lz); if (R.dir < 0) mesh.rotation.y += Math.PI; return mesh; };
  const plateGeo = own(new THREE.PlaneGeometry(0.3, 0.05));
  const mqGeo = own(new THREE.PlaneGeometry(0.54, 0.54 * MQ_ROWS / MQ_COLS));
  const glowT = tex(keepCv(glowTexture()), { linear: true });
  const pickRack = [];   // power strips and marquees answer the pointer too
  const mqs = [];
  const rname = R => (corridor ? R.sec.label + ' ' : '') + 'R' + (R.k + 1);
  for (const R of racks) {
    const k = R.k, S = R.sec;
    const t = tex(keepCv(labelTexture(P, k, R.from, R.to)));
    const pm = new THREE.Mesh(plateGeo, P.plateLit ? basic(0xffffff, { map: t }) : std(0xffffff, 0.72, 0.1, { map: t }));
    scene.add(onRack(pm, R, 0, unitsTop + TOP_H - 0.037, 0.0008));
    const top3 = R.langs.slice(0, 4).map(l => l.name + ' ' + l.n).join(', ') + (R.langs.length > 4 ? ' +' + (R.langs.length - 4) : '');
    const msg = [rname(R) + '  #' + R.from + (R.to > R.from ? '–' + R.to : ''),
      corridor && S.name ? S.name : '',
      R.best ? 'Best ' + R.best.fw + (R.best.score ? ' ' + R.best.score : '') : '',
      R.median != null ? 'Median ' + fmtN(R.median, R.median < 100 ? 1 : 0) : '',
      R.langs.length ? R.langs.length + (R.langs.length === 1 ? ' language: ' : ' languages: ') + top3 : '',
      R.tuned ? R.tuned + ' tuned' : 'None tuned',
      'Load ' + Math.round(R.load * 100) + '% of the leader'].filter(Boolean).join('   •   ') + '   •   ';
    const mc = marqueeCanvas(msg);
    const mt = tex(mc, { linear: true, nearest: true, keep: true });
    const mm = own(new THREE.ShaderMaterial({
      uniforms: THREE.UniformsUtils.merge([THREE.UniformsLib.fog, { tMsg: { value: null }, uShift: { value: MQ_COLS }, uMsgW: { value: mc.width }, uOnC: { value: new THREE.Color(P.mq[0]).multiplyScalar(dark ? 1.25 : 1.1) }, uOffC: { value: new THREE.Color(P.mq[1]) }, uBg: { value: new THREE.Color(P.mq[2]) } }]),
      vertexShader: MQ_VS, fragmentShader: MQ_FS, fog: true,
    }));
    mm.uniforms.tMsg.value = mt;
    const mq = new THREE.Mesh(mqGeo, mm);
    onRack(mq, R, 0, unitsTop + 0.052, 0.0125);
    mq.userData = { rack: R.gk, part: 'marquee', msg };
    scene.add(mq); mqs.push({ mesh: mq, w: mc.width, speed: 20 });
    pickRack.push(mq);
    // the power strip down the right side of the front frame
    const bw = RACK_W / 2 - (OPEN_HALF + POST_W), uh = perRack * U;
    const pt = tex(keepCv(rackPduTexture(P, R)));
    const pd = new THREE.Mesh(own(new THREE.PlaneGeometry(bw - 0.006, uh)), std(0xffffff, 0.6, 0.3, { map: pt, emissiveMap: pt, emissive: 0xffffff, emissiveIntensity: dark ? 0.6 : 0.22 }));
    onRack(pd, R, OPEN_HALF + POST_W + bw / 2, BASE_Y + uh / 2, 0.0006);
    pd.userData = { rack: R.gk, part: 'pdu' };
    scene.add(pd); pickRack.push(pd);
    // the floor in front of it, cold blue to hot amber by its average share
    const sc = rampColor(P.ramp, R.load);
    const fs = new THREE.Mesh(own(new THREE.PlaneGeometry(RACK_W - 0.07, 0.034)), basic(sc.clone().multiplyScalar(P.stripK)));
    fs.rotation.x = -Math.PI / 2; fs.position.set(R.x, 0.0014, R.z + R.dir * 0.03);
    const fg = new THREE.Mesh(own(new THREE.PlaneGeometry(RACK_W * 1.15, 0.9)), basic(sc, { alphaMap: glowT, transparent: true, opacity: P.stripGlow, depthWrite: false, blending: dark ? THREE.AdditiveBlending : THREE.NormalBlending }));
    fg.rotation.x = -Math.PI / 2; fg.position.set(R.x, 0.0018, R.z + R.dir * 0.05);
    fg.renderOrder = 1;
    scene.add(fs, fg);
  }
  // light running along the cable tray over each rack, as fast as the rack's throughput
  const pulses = [];
  for (const S of SECS) {
    const rpsMax = Math.max(1, ...S.racks.map(R => R.rps));
    for (const R of S.racks) {
      if (!R.rps) continue;
      const pm = own(new THREE.ShaderMaterial({
        uniforms: THREE.UniformsUtils.merge([THREE.UniformsLib.fog, { uTime: { value: 0 }, uRate: { value: 0.4 + 2.2 * R.rps / rpsMax }, uColor: { value: new THREE.Color(P.ledB).multiplyScalar(dark ? 1.6 : 1.2) } }]),
        vertexShader: MQ_VS, fragmentShader: PULSE_FS, fog: true,
      }));
      pm.uniforms.uTime = T;
      const pl = new THREE.Mesh(own(new THREE.PlaneGeometry(PITCH - 0.02, 0.03)), pm);
      scene.add(onRack(pl, R, 0, 2.665, -0.55 + 0.121)); pulses.push(pl);
    }
  }

  // the sign over the aisle
  const signs = [], kiosks = [];
  if (!corridor) {
    const sw = Math.min(1.7, Math.max(1.1, rowX1 - rowX0 + 0.2)), sh = sw * 200 / 1280;
    const t = tex(keepCv(signTexture(P, o.title, o.subtitle)));
    const sign = new THREE.Mesh(own(new THREE.PlaneGeometry(sw, sh)), P.signLit ? basic(0xffffff, { map: t }) : std(0xffffff, 0.8, 0, { map: t }));
    sign.position.set(midX, 2.6, 1.07);
    const back = new THREE.Mesh(own(new THREE.BoxGeometry(sw + 0.03, sh + 0.03, 0.03)), M.fixture);
    back.position.set(midX, 2.6, 1.05);
    scene.add(sign, back);
    for (const dx of [-sw / 2 + 0.08, sw / 2 - 0.08]) {
      const w = new THREE.Mesh(own(new THREE.BoxGeometry(0.004, 2.894 - 2.6 - sh / 2, 0.004)), M.wire);
      w.position.set(midX + dx, (2.894 + 2.6 + sh / 2) / 2, 1.05);
      scene.add(w);
    }
  } else {
    /* each section's bay: a lit sign hung across the aisle, read from both ways; a kiosk with
       its summary; its lane down the middle of the floor, in its colour, its name at the start */
    const lit = (t, k) => (P.signLit ? display(basic(new THREE.Color(1, 1, 1).multiplyScalar(k || 1), { map: t, toneMapped: false })) : std(0xffffff, 0.8, 0, { map: t, emissiveMap: t, emissive: 0xffffff, emissiveIntensity: 0.42 }));
    const SW = 1.75, SH = SW * 288 / 1280, TK = small ? 0.6 : 0.8;
    const laneGlowT = tex(keepCv((() => { const c = canvas(4, 64), x = c.getContext('2d'), g = x.createLinearGradient(0, 0, 0, 64); g.addColorStop(0, 'rgba(255,255,255,0)'); g.addColorStop(0.5, '#fff'); g.addColorStop(1, 'rgba(255,255,255,0)'); x.fillStyle = g; x.fillRect(0, 0, 4, 64); return c; })()), { linear: true });
    for (const S of SECS) {
      // the signs hang to one side and then the other, so from the entrance one does not hide the next
      const xs = S.x0 + SEC_LEAD * 0.55, zc = OPP_Z / 2, zs = zc + (S.k % 2 ? 0.62 : -0.62);
      const t = tex(keepCv(secSignTexture(P, S, TK)));
      const g = new THREE.Group(); g.position.set(xs, 2.38, zs);
      const f1 = new THREE.Mesh(own(new THREE.PlaneGeometry(SW, SH)), lit(t, P.signK)); f1.rotation.y = -Math.PI / 2; f1.position.x = -0.026;
      const f2 = new THREE.Mesh(f1.geometry, f1.material); f2.rotation.y = Math.PI / 2; f2.position.x = 0.026;
      const bk = new THREE.Mesh(own(new THREE.BoxGeometry(0.05, SH + 0.05, SW + 0.05)), M.fixture);
      const edge = new THREE.Mesh(own(new THREE.BoxGeometry(0.056, 0.014, SW + 0.056)), basic(new THREE.Color(S.color).multiplyScalar(dark ? 1.6 : 1)));
      edge.position.y = -SH / 2 - 0.02;
      g.add(f1, f2, bk, edge);
      for (const dz of [-SW / 2 + 0.12, SW / 2 - 0.12]) { const w = new THREE.Mesh(own(new THREE.BoxGeometry(0.004, HANG - 2.38 - SH / 2, 0.004)), M.wire); w.position.set(0, (HANG - 2.38 + SH / 2) / 2, dz); g.add(w); }
      f1.userData = f2.userData = { sec: S, part: 'sign' };
      scene.add(g); signs.push(f1, f2);
      // the lane: a stripe of light down the aisle's middle, the section's name painted where it starts
      const laneLen = S.x1 - S.x0 - 0.4;
      const lane = new THREE.Mesh(own(new THREE.PlaneGeometry(laneLen, 0.05)), basic(new THREE.Color(S.color).multiplyScalar(P.laneK)));
      lane.rotation.x = -Math.PI / 2; lane.position.set(S.x0 + 0.2 + laneLen / 2, 0.0016, zc);
      const lg = new THREE.Mesh(own(new THREE.PlaneGeometry(laneLen, 0.3)), basic(new THREE.Color(S.color), { alphaMap: laneGlowT, transparent: true, opacity: dark ? 0.1 : 0.08, depthWrite: false, blending: dark ? THREE.AdditiveBlending : THREE.NormalBlending }));
      lg.rotation.x = -Math.PI / 2; lg.position.set(lane.position.x, 0.002, zc); lg.renderOrder = 1;
      const lt = tex(keepCv(laneTexture(P, S, small ? 0.4 : 0.5)));
      const lab = new THREE.Mesh(own(new THREE.PlaneGeometry(1.5, 1.5 * 256 / 1024)), basic(0xffffff, { map: lt, transparent: true, depthWrite: false, opacity: dark ? 0.92 : 1 }));
      lab.rotation.x = -Math.PI / 2; lab.rotation.z = -Math.PI / 2; lab.position.set(S.x0 + 0.62, 0.0022, zc); lab.renderOrder = 1;
      scene.add(lane, lg, lab);
      // the kiosk at the bay's near corner across from the racks, so it hides none of them,
      // turned to whoever walks in
      const kt = tex(keepCv(kioskTexture(P, S, world, TK)));
      const kg = new THREE.Group(); kg.position.set(S.x0 + 0.7, 0, OPP_Z - 0.85); kg.rotation.y = -Math.PI / 2 - 0.5;
      const KW = 0.62, KH = KW * 1080 / 640;
      const post = new THREE.Mesh(own(new THREE.BoxGeometry(0.1, 0.7, 0.1)), M.bezel); post.position.y = 0.35;
      const foot = new THREE.Mesh(own(new THREE.BoxGeometry(0.46, 0.03, 0.34)), M.bezel); foot.position.y = 0.015;
      const shell = new THREE.Mesh(own(new THREE.BoxGeometry(KW + 0.05, KH + 0.05, 0.06)), M.bezel); shell.position.set(0, 0.7 + KH / 2, -0.03);
      const scr = new THREE.Mesh(own(new THREE.PlaneGeometry(KW, KH)), display(basic(0xffffff, { map: kt, toneMapped: false })));
      scr.position.set(0, 0.7 + KH / 2, 0.0015);
      const band = new THREE.Mesh(own(new THREE.BoxGeometry(KW + 0.056, 0.012, 0.064)), basic(new THREE.Color(S.color).multiplyScalar(dark ? 1.6 : 1)));
      band.position.set(0, 0.7 + KH + 0.03, -0.03);
      scr.userData = { sec: S, part: 'kiosk' };
      kg.add(post, foot, shell, scr, band);
      scene.add(kg); kiosks.push(scr);
    }
    /* the lobby: two boards flank the way in, the overall top ten on the left, the test machine
       and the sections in order on the right; between them the corridor */
    const BW = 1.3, BH = BW * 9 / 16, BK = small ? 0.5 : 0.75;
    const ot = tex(keepCv(overallTexture(P, o.overall, world, SECS, BK)));
    const mt = tex(keepCv(machineTexture(P, machine, SECS, world, BK)));
    for (const [z, ry, map, part] of [[OPP_Z / 2 - 1.4, -Math.PI / 2 + 0.42, ot, 'overall'], [OPP_Z / 2 + 1.4, -Math.PI / 2 - 0.42, mt, 'machine']]) {
      const g = new THREE.Group(); g.position.set(-2.9, 0, z); g.rotation.y = ry;
      const scr = new THREE.Mesh(own(new THREE.PlaneGeometry(BW, BH)), display(basic(0xffffff, { map, toneMapped: false })));
      scr.position.set(0, 0.98 + BH / 2, 0.002);
      const shell = new THREE.Mesh(own(new THREE.BoxGeometry(BW + 0.06, BH + 0.06, 0.07)), M.bezel); shell.position.set(0, 0.98 + BH / 2, -0.034);
      for (const dx of [-BW * 0.32, BW * 0.32]) { const leg = new THREE.Mesh(own(new THREE.BoxGeometry(0.06, 0.98, 0.06)), M.bezel); leg.position.set(dx, 0.49, -0.04); g.add(leg); }
      const foot = new THREE.Mesh(own(new THREE.BoxGeometry(BW * 0.8, 0.03, 0.42)), M.bezel); foot.position.set(0, 0.015, -0.04);
      const lip = new THREE.Mesh(own(new THREE.BoxGeometry(BW + 0.066, 0.012, 0.076)), basic(new THREE.Color(P.noc.accent).multiplyScalar(dark ? 1.4 : 1)));
      lip.position.set(0, 0.98 + BH + 0.036, -0.034);
      scr.userData = { part };
      g.add(shell, scr, foot, lip);
      scene.add(g); kiosks.push(scr);
    }
  }
  // the bench's placard
  {
    const bt = tex(keepCv(benchSignTexture(P)));
    const bs = new THREE.Mesh(own(new THREE.PlaneGeometry(1.2, 1.2 * 256 / 768)), P.signLit ? display(basic(0xffffff, { map: bt, toneMapped: false })) : std(0xffffff, 0.8, 0, { map: bt }));
    bs.position.set(0, BENCH_Y + 0.5 + 0.22, -BENCH.D / 2 + 0.03);
    bs.position.applyMatrix4(BENCH.m); bs.rotation.y = BENCH.yaw;
    scene.add(bs);
    var benchSign = bs;
  }

  /* the operations wall: six screens across the end of the aisle */
  const NOC_W = small ? 960 : 1280, NOC_H = Math.round(NOC_W * 9 / 16);
  const nocGeo = own(new THREE.PlaneGeometry(1.3, 1.3 * 9 / 16));
  const noc = {};
  const nocDefs = [['hist', 0, 0], ['view', 1, 0], ['langs', 2, 0], ['tests', 0, 1], ['machine', 1, 1], ['sel', 2, 1]];
  const housingGeo = own(new THREE.BoxGeometry(1.34, 1.34 * 9 / 16 + 0.04, 0.05));
  const CURVE = 12 * DEG;   // the side screens turn in toward the aisle, like a control room's wall
  for (const [id, col, row] of nocDefs) {
    const c = canvas(NOC_W, NOC_H);
    const t = tex(c, { keep: true });
    t.anisotropy = aniso;
    const m = new THREE.Mesh(nocGeo, display(basic(0xffffff, { map: t, toneMapped: false })));
    const side = col - 1, y = 2.0 + (row ? -0.38 : 0.38);
    m.rotation.y = -Math.PI / 2 - side * CURVE;
    if (!side) m.position.set(WALL_X - 0.03, y, OPP_Z / 2);
    else m.position.set(WALL_X - 0.03 - 0.665 * Math.sin(CURVE), y, OPP_Z / 2 + side * (0.68 + 0.665 * Math.cos(CURVE)));
    const hs = new THREE.Mesh(housingGeo, M.bezel);
    hs.rotation.copy(m.rotation);
    hs.position.copy(m.position).add(new THREE.Vector3(0.027, 0, 0).applyAxisAngle(new THREE.Vector3(0, 1, 0), -side * CURVE));
    m.userData = { noc: id };
    scene.add(m, hs);
    noc[id] = { mesh: m, cv: c, t, hits: [], due: true };
  }
  // the wall's stand: a beam across the top and two legs
  for (const y of [2.78, 1.22]) { const b = new THREE.Mesh(own(new THREE.BoxGeometry(0.08, 0.05, 1.4)), M.bezel); b.position.set(WALL_X + 0.01, y, OPP_Z / 2); scene.add(b); }
  const nocScale = NOC_W / 1280;
  let raf = 0, lastT = 0, renders = 0, shiftKey = false, dirty = true, lastDraw = 0;   // the loop's state (the loop is further down)
  /* the units: per section, where a panel's lights, display and fan sit */
  const faceGeo = own(new THREE.PlaneGeometry(PANEL_W, UNIT_H));
  const farGeo = own(new THREE.PlaneGeometry(PANEL_W, UNIT_H));
  const plateBox = own(new THREE.BoxGeometry(PANEL_W, UNIT_H, PLATE_T));
  const bodyGeo = own(new THREE.BoxGeometry(BODY_W, UNIT_H * 0.95, BODY_D));
  const railGeo = own(new THREE.BoxGeometry(0.007, 0.013, BODY_D * 0.93));
  const faceW = small ? 768 : TW, faceH = Math.round(faceW * TH / TW);
  const lcdGeos = new Map();
  for (const S of SECS) {
    const L = S.LY;
    S.lcdW = (L.lcd[1] - L.lcd[0]) / TW * PANEL_W; S.lcdH = (L.lcdY[1] - L.lcdY[0]) / TH * UNIT_H;
    const key = S.lcdW.toFixed(5);
    if (!lcdGeos.has(key)) lcdGeos.set(key, own(new THREE.PlaneGeometry(S.lcdW, S.lcdH)));
    S.lcdGeo = lcdGeos.get(key);
    S.lcdPx = [small ? 192 : 256, Math.round((small ? 192 : 256) * S.lcdH / S.lcdW)];
    S.lcdCx = pxX((L.lcd[0] + L.lcd[1]) / 2); S.lcdCy = pxY((L.lcdY[0] + L.lcdY[1]) / 2);
    S.RL = [   // the round lights on a panel: locator, activity, error, four completeness pips
      [pxX(L.locX), pxY(L.locY), 0.0062, 0.024], [pxX(L.actX), pxY(L.stY), 0.0028, 0.011], [pxX(L.errX), pxY(L.stY), 0.0028, 0.011],
      [pxX(L.pipX), pxY(L.pipY[0]), 0.0029, 0.01], [pxX(L.pipX + 11), pxY(L.pipY[0]), 0.0029, 0.01],
      [pxX(L.pipX), pxY(L.pipY[1]), 0.0029, 0.01], [pxX(L.pipX + 11), pxY(L.pipY[1]), 0.0029, 0.01],
    ];
    S.eqX = S.tests.map((_, t) => pxX(L.eqX0 + L.sp * (t + 0.5)));
    S.eqW = S.nT ? L.sp * 0.74 / TW * PANEL_W : 0; S.eqH = (L.eqY[1] - L.eqY[0]) / TH * UNIT_H; S.eqCy = pxY((L.eqY[0] + L.eqY[1]) / 2);
    S.fanD = 2 * L.fanR / TW * PANEL_W; S.fanX = pxX(L.fanX); S.fanY = pxY(L.cy);
    S.K = interiorPlan(S.nT);
  }
  const PORT_X = pxX(983), PORT_Y = pxY(46);   // the console port, between the display and the right ear
  const favT = tex(keepCv(favTexture()), { linear: true });
  const favGeo = own(new THREE.PlaneGeometry(PANEL_W, UNIT_H));
  const favMat = basic(new THREE.Color(P.ledB), { alphaMap: favT, transparent: true, opacity: P.favK, depthWrite: false, blending: P.favAdd ? THREE.AdditiveBlending : THREE.NormalBlending });
  const pipeGeo = own(new THREE.PlaneGeometry(PANEL_W - 0.004, 0.0011));
  const pipeMat = basic(new THREE.Color(P.ledB).multiplyScalar(P.favPipeK));
  const blankT = tex(canvas(4, 4));
  const lcdMat = t => (P.lcdLit ? basic(0xffffff, { map: t }) : std(0xffffff, 0.35, 0, { map: t }));
  const WHITE = new THREE.Color(1, 1, 1);
  const slid = new Set();   // the units that are out of their slot, if only a little

  for (const u of all) {
    const R = u.sec.racks[u.rack];
    u.R = R; u.dir = R.dir; u.yaw = u.yaw0 = R.dir < 0 ? Math.PI : 0;
    u.x0 = R.x; u.y0 = BASE_Y + (perRack - u.slot - 0.5) * U; u.z0 = R.z + R.dir * FACE_Z;
    const g = new THREE.Group();
    g.position.set(u.x0, u.y0, u.z0); g.rotation.y = u.yaw;
    u.plate = new THREE.Mesh(plateBox, M.plateEdge); u.plate.position.z = -PLATE_T / 2; u.plate.userData = { u, part: 'plate' };
    u.body = new THREE.Mesh(bodyGeo, M.body); u.body.position.z = -PLATE_T - BODY_D / 2 - 0.0004; u.body.userData = { u, part: 'body' };
    u.railL = new THREE.Mesh(railGeo, M.rail); u.railL.position.set(-BODY_W / 2 - 0.0035, -0.004, -PLATE_T - BODY_D * 0.47);
    u.railR = new THREE.Mesh(railGeo, M.rail); u.railR.position.set(BODY_W / 2 + 0.0035, -0.004, -PLATE_T - BODY_D * 0.47);
    for (const m of [u.plate, u.body, u.railL, u.railR]) { m.visible = false; m.matrixAutoUpdate = false; m.updateMatrix(); }
    g.add(u.plate, u.body, u.railL, u.railR);
    u.group = g; u.slide = 0; u.tw = null; u.fx = null; u.dim = 0; u.litUp = false; u.chartS = 0; u.chartV = null;
    u.near = null; u.hi = null; u.cmp = null; u.lodD = 1e9;
    scene.add(g);
  }

  /* Far off, a panel is a slot in one atlas, every panel in one draw; near the camera
     it gets its own sharp texture, from a pool, a few a frame. */
  const ACOLS = 8, AW = 256, AH = 24, ACH = 23;
  const atlasW = ACOLS * AW, atlasH = Math.max(AH, Math.ceil(all.length / ACOLS) * AH);
  const atlasCv = keepCv(canvas(atlasW, atlasH)), actx = atlasCv.getContext('2d');
  const slotCv = canvas(AW, ACH);
  function paintSlot(u) {
    const L = u.sec.LY, sc = AW / TW, vy = ACH / TH;
    drawFace(slotCv, u, L, P);
    const lw = (L.lcd[1] - L.lcd[0]) * sc, lh = (L.lcdY[1] - L.lcdY[0]) * vy;
    const lc = canvas(Math.max(8, Math.round(lw * 2)), Math.max(4, Math.round(lh * 2))); drawLcd(lc, u, P);
    const sx = slotCv.getContext('2d'); sx.setTransform(1, 0, 0, 1, 0, 0); sx.drawImage(lc, L.lcd[0] * sc, L.lcdY[0] * vy, lw, lh);
    const ax = (u.gi % ACOLS) * AW, ay = Math.floor(u.gi / ACOLS) * AH;
    actx.clearRect(ax, ay, AW, AH);
    actx.drawImage(slotCv, ax, ay);
    actx.drawImage(slotCv, 0, ACH - 1, AW, 1, ax, ay + ACH, AW, 1);   // a gutter, so mipmaps do not bleed
  }
  for (const u of all) paintSlot(u);
  const atlasT = tex(atlasCv, { keep: true });
  const farMat = std(0xffffff, 0.6, 0.25, { map: atlasT, emissiveMap: atlasT, emissive: 0xffffff, emissiveIntensity: 1 });
  const lcdK = P.lcdLit ? 0.9 / Math.max(0.05, P.faceEm) : 1;
  patch(farMat, sh => {
    sh.uniforms.uLcdK = { value: lcdK };
    sh.vertexShader = 'attribute vec4 aUv;\nattribute vec4 aEm;\nattribute vec2 aFx;\nvarying vec4 vEm;\nvarying vec2 vLoc;\nvarying float vLcd;\n' + sh.vertexShader
      .replace('#include <uv_vertex>', '#include <uv_vertex>\n  vMapUv = aUv.xy + uv * aUv.zw;\n  vEmissiveMapUv = vMapUv;\n  vEm = aEm; vLoc = uv; vLcd = aFx.y;')
      .replace('#include <project_vertex>', '#include <project_vertex>\n  if (aFx.x > 0.5) gl_Position = vec4(2.0, 2.0, 2.0, 1.0);');
    sh.fragmentShader = 'uniform float uLcdK;\nvarying vec4 vEm;\nvarying vec2 vLoc;\nvarying float vLcd;\n' + sh.fragmentShader
      .replace('#include <emissivemap_fragment>', '#include <emissivemap_fragment>\n  totalEmissiveRadiance *= vEm.rgb * vEm.a;\n  if (vLoc.x > vLcd && vLoc.x < 0.9512 && vLoc.y > 0.1739 && vLoc.y < 0.8261) totalEmissiveRadiance *= uLcdK;');
  }, 'a3d-far');
  for (const [name, size] of [['aUv', 4], ['aEm', 4], ['aFx', 2]]) farGeo.setAttribute(name, new THREE.InstancedBufferAttribute(new Float32Array(Math.max(1, all.length) * size), size));
  const farFaces = new THREE.InstancedMesh(farGeo, farMat, Math.max(1, all.length));
  farFaces.count = all.length; farFaces.frustumCulled = false; farFaces.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
  farFaces.userData = { part: 'far' };
  scene.add(farFaces);

  /* the lights, the equalisers and the fans: one instanced draw each. They are paint on a
     panel, so they leave the depth alone (the occlusion would read them as bumps). */
  function instanced(count, vs, fs, uniforms, attrs, opt) {
    const geo = own(new THREE.PlaneGeometry(1, 1));
    for (const [name, size] of attrs) geo.setAttribute(name, new THREE.InstancedBufferAttribute(new Float32Array(Math.max(1, count) * size), size));
    const mat = own(new THREE.ShaderMaterial({
      uniforms: THREE.UniformsUtils.merge([THREE.UniformsLib.fog, uniforms]),
      vertexShader: vs, fragmentShader: fs, fog: true, transparent: true,
      depthWrite: false, blending: opt.additive ? THREE.AdditiveBlending : THREE.NormalBlending,
      side: THREE.DoubleSide,
    }));
    if ('uTime' in mat.uniforms) mat.uniforms.uTime = T;
    const mesh = new THREE.InstancedMesh(geo, mat, Math.max(1, count));
    mesh.count = count;
    mesh.frustumCulled = false;
    mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    mesh.renderOrder = opt.order || 2;
    scene.add(mesh);
    return mesh;
  }
  const per = 7;
  const decorLeds = [];
  doors.forEach(d => { for (const l of doorKinds[d.kind].leds) decorLeds.push({ m: d.m, l }); });
  const nLens = all.length * per, nGlow = nLens + (P.decorGlowK > 0 && !post ? decorLeds.length : 0);
  const LED_ATTRS = [['aColor', 3], ['aLevel', 1], ['aHot', 1], ['aBlink', 2], ['aDim', 1]];
  const EQ_ATTRS = [['aColor', 3], ['aLevel', 1], ['aHot', 1], ['aDim', 1]];
  const lens = instanced(nLens, LED_VS, LENS_FS, { uTime: { value: 0 }, uOff: { value: new THREE.Color(P.ledOff) }, uBoost: { value: P.ledBoost } }, LED_ATTRS, { order: 2 });
  const glow = instanced(nGlow, LED_VS, GLOW_FS, { uTime: { value: 0 }, uGlow: { value: P.glowK }, uTint: { value: dark ? 0 : 1 } }, LED_ATTRS, { additive: dark, order: 3 });
  const eq = instanced(eqN, EQ_VS, EQ_FS, { uOff: { value: new THREE.Color(P.eqOff) }, uBoost: { value: P.ledBoost } }, EQ_ATTRS, { order: 2 });
  const eqGlow = instanced(eqN, EQ_VS, EQG_FS, { uGlow: { value: P.eqGlowK }, uTint: { value: dark ? 0 : 1 } }, EQ_ATTRS, { additive: dark, order: 3 });
  const fans = instanced(all.length, FAN_VS, FAN_FS, { uTime: { value: 0 }, uHousing: { value: new THREE.Color(P.fan[0]) }, uBlade: { value: new THREE.Color(P.fan[1]) }, uCavity: { value: new THREE.Color(P.fan[2]) } }, [['aSpeed', 1], ['aPhase', 1], ['aDim', 1]], { order: 2 });
  const cG = new THREE.Color(P.ledG), cB = new THREE.Color(P.ledB), cA = new THREE.Color(P.ledA), cR = new THREE.Color(P.ledR);
  const setAttr = (mesh, name, i, a, b, c, d) => { const at = mesh.geometry.attributes[name], k = i * at.itemSize; at.array[k] = a; if (b !== undefined) at.array[k + 1] = b; if (c !== undefined) at.array[k + 2] = c; if (d !== undefined) at.array[k + 3] = d; };
  function setMat(mesh, i, x, y, z, sx, sy) {
    const e = mesh.instanceMatrix.array, o16 = i * 16;
    e[o16] = sx; e[o16 + 1] = 0; e[o16 + 2] = 0; e[o16 + 3] = 0;
    e[o16 + 4] = 0; e[o16 + 5] = sy; e[o16 + 6] = 0; e[o16 + 7] = 0;
    e[o16 + 8] = 0; e[o16 + 9] = 0; e[o16 + 10] = 1; e[o16 + 11] = 0;
    e[o16 + 12] = x; e[o16 + 13] = y; e[o16 + 14] = z; e[o16 + 15] = 1;
  }
  // an instance on a unit's front: its offset turned with the unit (a unit only ever turns about y)
  function setRot(mesh, i, u, lx, ly, lz, sx, sy) {
    const p = u.group.position, c = Math.cos(u.yaw), s = Math.sin(u.yaw);
    const e = mesh.instanceMatrix.array, o16 = i * 16;
    e[o16] = c * sx; e[o16 + 1] = 0; e[o16 + 2] = -s * sx; e[o16 + 3] = 0;
    e[o16 + 4] = 0; e[o16 + 5] = sy; e[o16 + 6] = 0; e[o16 + 7] = 0;
    e[o16 + 8] = s; e[o16 + 9] = 0; e[o16 + 10] = c; e[o16 + 11] = 0;
    e[o16 + 12] = p.x + c * lx + s * lz; e[o16 + 13] = p.y + ly; e[o16 + 14] = p.z - s * lx + c * lz; e[o16 + 15] = 1;
  }
  function ledsOf(u) {
    const b = u.gi * per, dim = u.dim, S = u.sec;
    const put = (j, c, lv, hot, blink, phase) => {
      for (const m of [lens, glow]) { setAttr(m, 'aColor', b + j, c.r, c.g, c.b); setAttr(m, 'aLevel', b + j, lv); setAttr(m, 'aHot', b + j, hot); setAttr(m, 'aBlink', b + j, blink, phase); setAttr(m, 'aDim', b + j, dim); }
    };
    put(0, cB, u.fav ? 1 : -1, 0, 0, 0);
    // the activity light blinks faster the closer the entry is to the leader (the board's ACT)
    put(1, cG, u.share > 0 ? 0.85 : -1, 0, u.share > 0 ? 2.6 - 2.0 * u.share : 0, (hash(u.fw) % 1000) / 1000);
    put(2, cA, u.errors > 0 ? 0.95 : -1, 0, u.errors > 0 ? 1.7 : 0, 0.3);
    COMP.forEach(([k], j) => { const v = u.completeness ? u.completeness[k] : null; put(3 + j, v ? cG : cR, v == null ? -1 : 0.72, 0, 0, 0); });
    for (let t = 0; t < S.nT; t++) {
      const l = u.leds[t], p = l ? num(l.p) : null, i = u.eq0 + t;
      for (const m of [eq, eqGlow]) { setAttr(m, 'aColor', i, cG.r, cG.g, cG.b); setAttr(m, 'aLevel', i, p == null ? -1 : clamp01(p)); setAttr(m, 'aHot', i, p != null && l.best ? 1 : 0); setAttr(m, 'aDim', i, dim); }
    }
    setAttr(fans, 'aSpeed', u.gi, u.cpuN == null ? 0 : 0.12 + 2.3 * u.cpuN);
    setAttr(fans, 'aPhase', u.gi, (hash(u.fw) % 628) / 100);
    setAttr(fans, 'aDim', u.gi, dim);
  }
  function placeUnit(u) {
    const S = u.sec, b = u.gi * per;
    for (let j = 0; j < per; j++) {
      const [x, y, s, gs] = S.RL[j];
      setRot(lens, b + j, u, x, y, LED_Z, s, s);
      setRot(glow, b + j, u, x, y, LED_Z + 0.0004, gs, gs);
    }
    for (let t = 0; t < S.nT; t++) {
      const i = u.eq0 + t;
      setRot(eq, i, u, S.eqX[t], S.eqCy, 0.0009, S.eqW, S.eqH);
      setRot(eqGlow, i, u, S.eqX[t], S.eqCy, 0.0014, S.eqW * 1.7, S.eqH / 0.86);
    }
    setRot(fans, u.gi, u, S.fanX, S.fanY, 0.0007, S.fanD, S.fanD);
    setRot(farFaces, u.gi, u, 0, 0, 0.0001, 1, 1);
    lens.instanceMatrix.needsUpdate = glow.instanceMatrix.needsUpdate = fans.instanceMatrix.needsUpdate = farFaces.instanceMatrix.needsUpdate = true;
    if (S.nT) eq.instanceMatrix.needsUpdate = eqGlow.instanceMatrix.needsUpdate = true;
  }
  const ledAttrsDirty = () => {
    for (const m of [lens, glow, eq, eqGlow]) for (const k of ['aColor', 'aLevel', 'aHot', 'aDim', 'aBlink']) if (m.geometry.attributes[k]) m.geometry.attributes[k].needsUpdate = true;
    for (const k of ['aSpeed', 'aPhase', 'aDim']) fans.geometry.attributes[k].needsUpdate = true;
  };
  const farDirty = () => { farGeo.attributes.aEm.needsUpdate = farGeo.attributes.aFx.needsUpdate = true; if (farFaces.instanceColor) farFaces.instanceColor.needsUpdate = true; };
  for (const u of all) {
    const ax = (u.gi % ACOLS) * AW, ay = Math.floor(u.gi / ACOLS) * AH;
    setAttr(farFaces, 'aUv', u.gi, ax / atlasW, 1 - (ay + ACH) / atlasH, AW / atlasW, ACH / atlasH);
    setAttr(farFaces, 'aEm', u.gi, 1, 1, 1, P.faceEm);
    setAttr(farFaces, 'aFx', u.gi, 0, u.sec.LY.lcd[0] / TW);
    farFaces.setColorAt(u.gi, WHITE);
    ledsOf(u); placeUnit(u);
  }
  farGeo.attributes.aUv.needsUpdate = true; farDirty();
  if (nGlow > nLens) {
    const v = new THREE.Vector3();
    decorLeds.forEach((d, j) => {
      v.set(d.l.x * doorW, PLINTH_H + 0.006 + doorH / 2 + d.l.y * doorH, 0.009).applyMatrix4(d.m);
      const i = nLens + j, c = new THREE.Color(d.l.color);
      setMat(glow, i, v.x, v.y, v.z, 0.012 + 0.008 * d.l.level, 0.012 + 0.008 * d.l.level);
      setAttr(glow, 'aColor', i, c.r, c.g, c.b); setAttr(glow, 'aLevel', i, d.l.level * P.decorGlowK); setAttr(glow, 'aHot', i, 0); setAttr(glow, 'aBlink', i, 0, 0); setAttr(glow, 'aDim', i, 0);
    });
  }
  ledAttrsDirty();

  // the pool of sharp panels
  const NEAR_N = small ? 28 : 72, NEAR_BUDGET = small ? 1 : 3;
  const nearPool = [];
  let lodWant = [], lodDirty = true, lodPaints = 0, lodStamp = 0;
  function makeNear() {
    const e = { u: null, tf: null, tl: null };
    e.matFace = std(0xffffff, 0.6, 0.25, { map: blankT, emissiveMap: blankT, emissive: 0xffffff, emissiveIntensity: P.faceEm });
    e.matLcd = lcdMat(blankT);
    e.face = new THREE.Mesh(faceGeo, e.matFace); e.face.position.z = 0.0001;
    e.lcd = new THREE.Mesh(faceGeo, e.matLcd);
    return e;
  }
  function paintNear(e, u) {
    const S = u.sec;
    const df = c => drawFace(c, u, S.LY, P), dl = c => drawLcd(c, u, P);
    if (!e.tf) { const c = canvas(faceW, faceH); df(c); e.tf = tex(c); } else repaint(e.tf, faceW, faceH, df);
    if (!e.tl) { const c = canvas(S.lcdPx[0], S.lcdPx[1]); dl(c); e.tl = tex(c); } else repaint(e.tl, S.lcdPx[0], S.lcdPx[1], dl);
    e.matFace.map = e.matFace.emissiveMap = e.tf; e.matLcd.map = e.tl;
    e.lcd.geometry = S.lcdGeo; e.lcd.position.set(S.lcdCx, S.lcdCy, 0.0003);
    lodPaints++;
  }
  const forced = u => u === popped || !!u.cmp || (mon && mon.u === u);
  function grant(u) {
    if (u.near) return;
    let e = nearPool.find(x => !x.u);
    if (!e && nearPool.length < NEAR_N) { e = makeNear(); nearPool.push(e); }
    if (!e) {
      let worst = null;
      // the farthest of those the last look did not ask for
      for (const x of nearPool) if (x.u && !forced(x.u) && x.u.lodW !== lodStamp && (!worst || x.u.lodD > worst.u.lodD)) worst = x;
      if (!worst) { e = makeNear(); nearPool.push(e); }   // all of them needed: one more
      else { revoke(worst.u); e = worst; }
    }
    paintNear(e, u);
    e.u = u; u.near = e;
    u.group.add(e.face, e.lcd);
    setAttr(farFaces, 'aFx', u.gi, 1); farGeo.attributes.aFx.needsUpdate = true;
    faceGlow(u);
    invalidate();
  }
  function revoke(u) {
    const e = u.near;
    if (!e) return;
    if (u.hi) hiRes(u, false);
    u.group.remove(e.face, e.lcd);
    e.u = null; u.near = null;
    setAttr(farFaces, 'aFx', u.gi, 0); farGeo.attributes.aFx.needsUpdate = true;
  }
  const frustum = new THREE.Frustum(), _pm = new THREE.Matrix4(), _sph = new THREE.Sphere(new THREE.Vector3(), 0.32);
  const lodPos = new THREE.Vector3(1e9, 0, 0), lodDir = new THREE.Vector3(), _lf = new THREE.Vector3();
  function lodTick() {
    camera.getWorldDirection(_lf);
    if (lodDirty || camera.position.distanceToSquared(lodPos) > 0.0016 || _lf.dot(lodDir) < 0.9992) {
      lodPos.copy(camera.position); lodDir.copy(_lf); lodDirty = false;
      _pm.multiplyMatrices(camera.projectionMatrix, camera.matrixWorldInverse); frustum.setFromProjectionMatrix(_pm);
      const want = [], cp = camera.position;
      for (const u of all) {
        const p = u.group.position;
        u.lodD = Math.sqrt(cp.distanceToSquared(p));
        if (forced(u)) { want.push(u); continue; }
        if (u.lodD > (small ? NEAR_R * 0.72 : NEAR_R)) continue;
        _sph.center.copy(p);
        if (frustum.intersectsSphere(_sph)) want.push(u);
      }
      want.sort((a, b) => (forced(b) - forced(a)) || a.lodD - b.lodD);
      if (want.length > NEAR_N) want.length = NEAR_N;
      lodStamp++;
      for (const u of want) u.lodW = lodStamp;
      lodWant = want.filter(u => !u.near);
    }
    let n = 0;
    while (lodWant.length && n < NEAR_BUDGET) { const u = lodWant.shift(); if (!u.near) { grant(u); n++; } }
    return lodWant.length > 0;
  }

  // fav: the locator lit, the whole front washed blue, light pipes along its edges
  function favFx(u) {
    if (u.fav && !u.fx) {
      const ov = new THREE.Mesh(favGeo, favMat); ov.position.z = 0.0005; ov.renderOrder = 1;   // under the lights, which draw over it
      const top = new THREE.Mesh(pipeGeo, pipeMat); top.position.set(0, UNIT_H / 2 - 0.0007, 0.0006);
      const bot = new THREE.Mesh(pipeGeo, pipeMat); bot.position.set(0, -UNIT_H / 2 + 0.0007, 0.0006);
      u.fx = [ov, top, bot]; u.group.add(ov, top, bot);
    } else if (!u.fav && u.fx) {
      for (const m of u.fx) u.group.remove(m);
      u.fx = null;
    }
  }
  all.forEach(favFx);

  // the drawer chart: a coloured body for each drawer that is out, in one draw
  const selfLit = (mat, k) => patch(mat, sh => { sh.fragmentShader = sh.fragmentShader.replace('#include <emissivemap_fragment>', '#include <emissivemap_fragment>\n  totalEmissiveRadiance += diffuseColor.rgb * ' + k.toFixed(2) + ';'); }, 'a3d-lit-' + k.toFixed(2));
  const chartBodies = new THREE.InstancedMesh(bodyGeo, selfLit(std(0xffffff, 0.45, 0.3), dark ? 0.55 : 0.18), Math.max(1, all.length));
  chartBodies.count = all.length; chartBodies.frustumCulled = false; chartBodies.visible = false;
  chartBodies.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
  for (const u of all) { chartBodies.setColorAt(u.gi, WHITE); setMat(chartBodies, u.gi, 0, -9, 0, 0, 0); }
  scene.add(chartBodies);
  function placeChartBody(u) {
    const on = chart && u.sec === cur && u.slide > 0.0006 && u !== popped && !u.cmp;
    if (on) setRot(chartBodies, u.gi, u, 0, 0, u.body.position.z, 1, 1);
    else setMat(chartBodies, u.gi, 0, -9, 0, 0, 0);
    chartBodies.instanceMatrix.needsUpdate = true;
  }

  /* the podium for the top three, in front of the operations wall: each block
     carries its unit in miniature, turning slowly, its own panel on its front.
     It shows the section you are in; it repaints when you are near it. */
  const podium = [], podiumPick = [];
  const podCols = dark ? ['#f3c742', '#d5dde6', '#e09a62'] : ['#b8860b', '#6b7683', '#a0592a'];
  {
    const PX = WALL_X - 0.8, PZ = OPP_Z / 2, ST = 0.42, hts = [0.34, 0.24, 0.17].map(h => h + ST), dz = [0, -0.44, 0.44];
    const stage = new THREE.Mesh(own(new THREE.BoxGeometry(0.62, ST, 1.48)), std(P.plinth, 0.5, 0.4));
    stage.position.set(PX, ST / 2, PZ); scene.add(stage); OBS.push([PX - 0.31, PZ - 0.74, PX + 0.31, PZ + 0.74]);
    const miniBox = own(new THREE.BoxGeometry(0.4, 0.036, 0.26)), miniFace = own(new THREE.PlaneGeometry(0.4, 0.4 * UNIT_H / PANEL_W));
    for (let k = 0; k < 3; k++) {
      const h = hts[k], z = PZ + dz[k];
      const blk = new THREE.Mesh(own(new THREE.BoxGeometry(0.36, h - ST, 0.38)), std(P.frame, 0.32, 0.6));
      blk.position.set(PX, ST + (h - ST) / 2, z); blk.userData = { u: null, part: 'podium' };
      const lab = new THREE.Mesh(own(new THREE.PlaneGeometry(0.22, 0.22)), basic(0xffffff, { map: tex(keepCv(podiumRank(k, podCols[k]))), transparent: true, depthWrite: false }));
      lab.rotation.y = -Math.PI / 2; lab.position.set(PX - 0.182, Math.max(ST + 0.11, h - 0.14), z);
      const rim = new THREE.Mesh(own(new THREE.BoxGeometry(0.366, 0.008, 0.386)), basic(new THREE.Color(podCols[k]).multiplyScalar(dark ? 1.5 : 0.9)));
      rim.position.set(PX, h - 0.004, z);
      const mini = new THREE.Group();
      mini.position.set(PX, h + 0.08, z); mini.rotation.y = -Math.PI / 2;
      const mb = new THREE.Mesh(miniBox, M.body); mb.userData = { u: null, part: 'podium' };
      const mfT = tex(canvas(4, 4));
      const mf = new THREE.Mesh(miniFace, basic(0xffffff, { map: mfT }));
      mf.position.z = 0.1306;
      mini.add(mb, mf);
      const npT = tex(canvas(4, 4));
      const np = new THREE.Mesh(own(new THREE.PlaneGeometry(0.42, 0.13)), basic(0xffffff, { map: npT, transparent: true, depthWrite: false }));
      np.rotation.y = -Math.PI / 2; np.position.set(PX, h + 0.23, z); np.renderOrder = 4;
      scene.add(blk, lab, rim, mini, np);
      podium.push({ k, mini, base: h + 0.08, phase: k * 2.1, blk, mb, mfT, npT, parts: [blk, lab, rim, mini, np] });
      podiumPick.push(blk, mb);
    }
  }
  let podiumSec = null, podiumDue = false;
  function skinPodium(S) {
    podiumSec = S; podiumDue = false;
    for (const p of podium) {
      const u = S.units[p.k];
      for (const m of p.parts) m.visible = !!u;
      p.blk.userData.u = p.mb.userData.u = u || null;
      if (!u) continue;
      repaint(p.mfT, faceW, faceH, c => drawFace(c, u, S.LY, P));
      const pc = podiumPlate(u, p.k, podCols[p.k], P);
      repaint(p.npT, pc.width, pc.height, c => c.getContext('2d').drawImage(pc, 0, 0));
      pc.width = pc.height = 1;
    }
    invalidate();
  }
  skinPodium(cur);

  /* an open unit's insides: a kit lent to whichever unit is out; the bench has its own */
  const floorY = -UNIT_H * 0.475, zMid = -PLATE_T - BODY_D / 2;
  const shellGeo = (() => {
    const tl = [];
    tl.push({ g: new THREE.BoxGeometry(BODY_W, 0.002, BODY_D), m: mat4(0, floorY, zMid) });
    tl.push({ g: new THREE.BoxGeometry(0.002, UNIT_H * 0.9, BODY_D), m: mat4(-BODY_W / 2, -0.001, zMid) });
    tl.push({ g: new THREE.BoxGeometry(0.002, UNIT_H * 0.9, BODY_D), m: mat4(BODY_W / 2, -0.001, zMid) });
    tl.push({ g: new THREE.BoxGeometry(BODY_W, UNIT_H * 0.9, 0.002), m: mat4(0, -0.001, -PLATE_T - BODY_D) });
    return own(mergeParts(tl));
  })();
  const K0 = SECS[0].K;
  const boardGeo = own(new THREE.PlaneGeometry(BODY_W - 0.003, BODY_D - 0.003));
  const chipGeo = own(new THREE.BoxGeometry(1, 1, 1)); chipGeo.translate(0, 0.5, 0);
  const chipMat = selfLit(std(0xffffff, 0.35, 0.2), dark ? 0.7 : 0.22);
  const finT = tex(keepCv((() => { const c = canvas(128, 128), x = c.getContext('2d'); x.fillStyle = dark ? '#2a2f35' : '#9aa3ac'; x.fillRect(0, 0, 128, 128); x.fillStyle = dark ? '#5d666f' : '#e3e7ea'; for (let i = 0; i < 128; i += 10) x.fillRect(i, 0, 5, 128); return c; })()));
  const cpuGeo = own(new THREE.BoxGeometry(K0.cpu, 0.026, K0.cpu)), heatGeo = own(new THREE.PlaneGeometry(K0.cpu * 2.1, K0.cpu * 2.1));
  const ramGeo = own(new THREE.BoxGeometry(0.0034, 0.03, K0.ramLen)); ramGeo.translate(0, 0.015, 0);
  const ramMat = std(dark ? 0x1d3b2c : 0x2a6b4c, 0.5, 0.3);
  const ramLedGeo = own(new THREE.BoxGeometry(0.0038, 0.0028, K0.ramLen * 0.92));
  const ramLedMat = basic(new THREE.Color(P.holo).multiplyScalar(dark ? 1.5 : 1));
  const RAM_ORDER = [3, 4, 2, 5, 1, 6, 0, 7];
  const nicGeo = own(new THREE.BoxGeometry(0.0025, 0.03, 0.11)), nicMat = std(dark ? 0x173326 : 0x245a40, 0.5, 0.3);
  const nicLedGeo = own(new THREE.BoxGeometry(0.0055, 0.004, 0.008));
  const psuT = tex(keepCv((() => {
    const c = canvas(256, 256), x = c.getContext('2d');
    x.fillStyle = dark ? '#262b31' : '#a8b0b8'; x.fillRect(0, 0, 256, 256);
    x.strokeStyle = dark ? '#0c0e10' : '#4f5963'; x.lineWidth = 5;
    for (let r = 24; r < 96; r += 18) { x.beginPath(); x.arc(128, 110, r, 0, Math.PI * 2); x.stroke(); }
    x.fillStyle = dark ? '#c9d1d9' : '#1d2126'; x.font = '700 30px ' + FONT_SANS; x.textAlign = 'center'; x.fillText('1600 W', 128, 238);
    return c;
  })()));
  const psuGeo = own(new THREE.BoxGeometry(0.07, 0.034, 0.12)), psuMat = std(0xffffff, 0.45, 0.55, { map: psuT });
  const maxNT = Math.max(1, ...SECS.map(S => S.nT));
  const _m4 = new THREE.Matrix4();
  function makeKit(full) {
    const K = K0, kit = { full, u: null, k: 0, tw: null };
    const g = kit.g = new THREE.Group(); g.visible = false;
    g.add(new THREE.Mesh(shellGeo, M.body));
    kit.pcbPx = full ? [small ? 640 : 1024, Math.round((small ? 640 : 1024) * BODY_D / BODY_W)] : [512, Math.round(512 * BODY_D / BODY_W)];
    kit.pcbT = tex(canvas(4, 4));
    kit.board = new THREE.Mesh(boardGeo, std(0xffffff, 0.55, 0.25, { map: kit.pcbT, emissiveMap: kit.pcbT, emissive: 0xffffff, emissiveIntensity: dark ? 0.2 : 0.05 }));
    kit.board.rotation.x = -Math.PI / 2; kit.board.position.set(0, floorY + 0.0012, zMid);
    kit.board.userData = { part: 'board', kit };
    // a chip per test, its height its share of the best: a little bar chart
    kit.chips = new THREE.InstancedMesh(chipGeo, chipMat, maxNT);
    kit.chips.count = 0; kit.chips.frustumCulled = false; kit.chips.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    kit.chips.userData = { part: 'chips', kit };
    for (let t = 0; t < maxNT; t++) kit.chips.setColorAt(t, WHITE);
    // the CPU: a heatsink that glows with the load
    kit.cpuMat = std(0xffffff, 0.4, 0.7, { map: finT, emissive: 0x000000 });
    kit.cpu = new THREE.Mesh(cpuGeo, kit.cpuMat); kit.cpu.position.set(0, floorY + 0.015, K.zCpu);
    kit.heatMat = basic(0xffffff, { alphaMap: glowT, transparent: true, opacity: 0, depthWrite: false, blending: dark ? THREE.AdditiveBlending : THREE.NormalBlending });
    kit.heat = new THREE.Mesh(heatGeo, kit.heatMat); kit.heat.rotation.x = -Math.PI / 2; kit.heat.position.set(0, floorY + 0.0295, K.zCpu);
    // memory: as many sticks as it uses, the nearest the CPU first
    kit.ram = new THREE.InstancedMesh(ramGeo, ramMat, 8); kit.ramLed = new THREE.InstancedMesh(ramLedGeo, ramLedMat, 8);
    for (let i = 0; i < 8; i++) {
      const x = K.ramX[RAM_ORDER[i]];
      kit.ram.setMatrixAt(i, _m4.makeTranslation(x, floorY + 0.002, K.zRam));
      kit.ramLed.setMatrixAt(i, _m4.makeTranslation(x, floorY + 0.0335, K.zRam));
    }
    kit.ram.count = kit.ramLed.count = 0;
    // the NIC, its activity light flickering with the throughput; the power supply
    kit.nic = new THREE.Mesh(nicGeo, nicMat); kit.nic.position.set(K.nic, floorY + 0.017, K.zRam);
    kit.nicLed = [cA, cG].map((c, j) => { const m = new THREE.Mesh(nicLedGeo, basic(c.clone())); m.position.set(K.nic, floorY + 0.0335, K.zRam + 0.045 - j * 0.016); return m; });
    kit.psu = new THREE.Mesh(psuGeo, psuMat); kit.psu.position.set(K.psu, floorY + 0.019, K.zRam);
    g.add(kit.board, kit.chips, kit.cpu, kit.heat, kit.ram, kit.ramLed, kit.nic, kit.psu, ...kit.nicLed);
    if (full) {
      // the lid; once open, it slides back into the rack and only its tag stays out
      kit.lidPx = [small ? 640 : 1024, Math.round((small ? 640 : 1024) * BODY_D / BODY_W)];
      kit.lidT = tex(canvas(4, 4));
      kit.lid = new THREE.Mesh(own(new THREE.PlaneGeometry(BODY_W - 0.002, BODY_D - 0.002)), std(0xffffff, 0.45, 0.55, { map: kit.lidT }));
      kit.lid.rotation.x = -Math.PI / 2; kit.lid.position.set(0, UNIT_H * 0.475 + 0.0006, zMid);
      kit.lid.userData = { part: 'lid', kit };
      // the strength hologram, projected up from the CPU
      kit.holoPx = small ? 512 : 640;
      kit.holoT = tex(canvas(4, 4));
      kit.holoMat = own(new THREE.ShaderMaterial({ uniforms: { tHolo: { value: kit.holoT }, uTime: T, uAlpha: { value: 0 } }, vertexShader: HOLO_VS, fragmentShader: HOLO_FS, transparent: true, depthWrite: false, side: THREE.DoubleSide }));
      kit.holo = new THREE.Mesh(own(new THREE.PlaneGeometry(0.23, 0.23)), kit.holoMat);
      kit.holo.position.set(0, floorY + 0.03 + 0.05 + 0.115, K.zCpu - 0.02);
      kit.holo.renderOrder = 6;
      kit.beamMat = own(new THREE.ShaderMaterial({ uniforms: { uColor: { value: new THREE.Color(P.holo) }, uAlpha: { value: 0 }, uTime: T }, vertexShader: HOLO_VS, fragmentShader: BEAM_FS, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide }));
      kit.beam = new THREE.Mesh(own(new THREE.CylinderGeometry(0.1, 0.014, 0.05, 40, 1, true)), kit.beamMat);
      kit.beam.position.set(0, floorY + 0.03 + 0.025, K.zCpu - 0.01);
      kit.beam.renderOrder = 5;
      g.add(kit.lid, kit.holo, kit.beam);
    }
    return kit;
  }
  function setKitOpen(kit, k) {
    kit.k = k;
    const u = kit.u;
    if (kit.full) { kit.lid.position.z = zMid - k * LID_BACK; kit.lid.position.y = UNIT_H * 0.475 + 0.0006 + k * 0.004; }
    if (u) {
      const S = u.sec, K = S.K;
      for (let t = 0; t < S.nT; t++) {
        const l = u.leds[t], p = l ? num(l.p) : null;
        const grow = clamp01(k * 1.6 - (t / Math.max(1, S.nT)) * 0.6);
        const h = (p == null ? 0.0025 : 0.004 + p * K.chipMax) * easeOut(grow) + 0.0003;
        kit.chips.setMatrixAt(t, _m4.makeScale(K.chipW, h, K.chipW).setPosition(K.chipX[t], floorY + 0.0022, K.zChip));
      }
      kit.chips.instanceMatrix.needsUpdate = true;
      kit.heatMat.opacity = (0.15 + 0.6 * (u.cpuN || 0)) * k;
      kit.cpuMat.emissiveIntensity = (dark ? 0.3 + 2.2 * (u.cpuN || 0) : 0.2 + 0.9 * (u.cpuN || 0)) * k;
    }
    if (kit.full) {
      const hk = clamp01((k - 0.45) / 0.55);
      kit.holoMat.uniforms.uAlpha.value = u && (u.strength || u.spec != null || u.resil != null || u.completeness) ? hk : 0;
      kit.beamMat.uniforms.uAlpha.value = kit.holoMat.uniforms.uAlpha.value * (dark ? 1 : 0.6);
      kit.holo.visible = kit.beam.visible = kit.holoMat.uniforms.uAlpha.value > 0.002;
      kit.holo.scale.setScalar(0.85 + 0.15 * hk);
    }
  }
  function dressKit(kit, u) {
    kit.u = u;
    const S = u.sec;
    repaint(kit.pcbT, kit.pcbPx[0], kit.pcbPx[1], c => drawPcb(c, u, S.tests, S.K, P));
    if (kit.full) {
      repaint(kit.lidT, kit.lidPx[0], kit.lidPx[1], c => drawLid(c, u, P));
      repaint(kit.holoT, kit.holoPx, kit.holoPx, c => drawHolo(c, u, P));
    }
    const pk = new THREE.Color();
    kit.chips.count = S.nT;
    for (let t = 0; t < S.nT; t++) {
      const l = u.leds[t], p = l ? num(l.p) : null;
      if (p == null) pk.set(P.eqOff); else if (l.best) pk.setRGB(1, 1, 0.92); else pk.copy(cG).multiplyScalar(0.35 + 0.65 * clamp01(p));
      kit.chips.setColorAt(t, pk);
    }
    if (kit.chips.instanceColor) kit.chips.instanceColor.needsUpdate = true;
    const sticks = u.memN == null ? 0 : Math.max(1, Math.round(1 + u.memN * 7));
    kit.ram.count = kit.ramLed.count = sticks;
    kit.ram.instanceMatrix.needsUpdate = kit.ramLed.instanceMatrix.needsUpdate = true;
    const hc = rampColor(P.heat, 0.25 + 0.75 * (u.cpuN || 0));
    kit.cpuMat.emissive.copy(hc); kit.heatMat.color.copy(hc);
    kit.nicLed[1].material.color.copy(u.rps ? cG : new THREE.Color(P.ledOff));
    u.group.add(kit.g);
    kit.g.visible = true;
    setKitOpen(kit, 0);
  }
  function closeKit(kit) {
    if (kit.tw) { tweens.delete(kit.tw); kit.tw = null; }
    kit.g.visible = false; if (kit.g.parent) kit.g.parent.remove(kit.g);
    kit.u = null; setKitOpen(kit, 0);
  }
  const kit0 = makeKit(true);
  const kits = [kit0];

  // the shadow an open unit casts on the panels below it
  const shT = tex(keepCv(shadowTexture()), { linear: true });
  const shadow = new THREE.Mesh(own(new THREE.PlaneGeometry(PANEL_W, 0.075)), basic(0x000000, { alphaMap: shT, transparent: true, opacity: 0, depthWrite: false }));
  shadow.visible = false; shadow.renderOrder = 1;
  scene.add(shadow);

  /* camera and controls */
  const controls = new OrbitControls(camera, cv);
  controls.enableDamping = !reduced;
  controls.dampingFactor = 0.09;
  controls.screenSpacePanning = true;
  controls.zoomToCursor = true;
  controls.minDistance = 0.16;
  controls.maxDistance = 22;   // far enough to take in the hall from over the rows
  controls.minPolarAngle = 0.18;
  controls.maxPolarAngle = Math.PI / 2 + 0.34;
  controls.rotateSpeed = 0.6;
  controls.panSpeed = 0.9;

  // The projection's centre sits in the middle of what is left of the screen: the
  // card's panel reserves the right (or, narrow, the bottom), the HUD on a phone the top.
  const shift = { x: 0, y: 0 };
  const topBar = $('.a3d-top');
  const topRes = () => { const b = topBar.getBoundingClientRect().bottom - root.getBoundingClientRect().top; return vw() <= 760 ? Math.max(0, b) : Math.max(0, b - 72); };
  function applyView() {
    const W = vw(), H = vh();
    const sx = shift.x, sy = shift.y, st = topRes();
    if (sx < 0.5 && sy < 0.5 && st < 0.5) { camera.clearViewOffset(); camera.fov = FOV; camera.aspect = W / H; }
    else {
      camera.fov = 2 * Math.atan(Math.tan(FOV * DEG / 2) * (H + sy + st) / H) / DEG;
      camera.aspect = (W + sx) / (H + sy + st);
      camera.setViewOffset(W + sx, H + sy + st, sx, sy, W, H);
    }
    camera.updateProjectionMatrix();
  }
  const V = (x, y, z) => new THREE.Vector3(x, y, z);
  // the nearest distance along a direction from which a set of points is all in view, clear of
  // the HUD and of the card the view will have (its projection shifted as applyView will)
  const fitCam = new THREE.PerspectiveCamera(FOV, 1, 0.02, 90), _fp = new THREE.Vector3();
  function fitView(target, dir, pts, dmin, dmax, S) {
    S = S || { x: 0, y: 0 };
    const W = vw(), H = vh(), st = topRes();
    if (S.x < 0.5 && S.y < 0.5 && st < 0.5) { fitCam.clearViewOffset(); fitCam.fov = FOV; fitCam.aspect = W / H; }
    else { fitCam.fov = 2 * Math.atan(Math.tan(FOV * DEG / 2) * (H + S.y + st) / H) / DEG; fitCam.aspect = (W + S.x) / (H + S.y + st); fitCam.setViewOffset(W + S.x, H + S.y + st, S.x, S.y, W, H); }
    fitCam.updateProjectionMatrix();
    const yb = 1 - 2 * 76 / H;   // the tool bar along the bottom
    let d = dmin;
    for (; d < dmax; d += 0.04) {
      fitCam.position.copy(target).addScaledVector(dir, d); fitCam.lookAt(target); fitCam.updateMatrixWorld();
      if (pts.every(p => { _fp.copy(p).project(fitCam); return _fp.z < 1 && Math.abs(_fp.x) < 0.93 && _fp.y < 0.9 && _fp.y > -yb; })) break;
    }
    return { pos: target.clone().addScaledVector(dir, d), target: target.clone() };
  }
  const ZC = OPP_Z / 2;
  function entranceView() {
    const a = vw() / vh();
    if (a < 1.05) return { target: V(0.5, 1.45, ZC), pos: V(endL + 0.6, 1.62, ZC) };
    return { target: V(1.2, 1.42, ZC), pos: V(endL + 0.9, 1.66, ZC + 0.05) };
  }
  function overview() {
    if (corridor) return entranceView();
    const a = vw() / vh(), t = Math.tan(FOV * DEG / 2), hf = (vh() - topRes()) / vh();
    const rx0 = SECS[0].racks[0].x;
    if (a < 1.05) {
      // a tall screen: R1 whole, the rest of the row going away from it
      const d = Math.max((RACK_H * 1.12) / 2 / (t * hf), (PITCH * 1.3) / 2 / (t * a));
      return { target: V(rx0 + 0.12, 1.04, -0.2), pos: V(rx0 - 0.5, 1.47, Math.min(OPP_Z - 0.45, d)) };
    }
    const len = Math.min(rowX1 - rowX0, 3 * PITCH);
    return { target: V(rowX0 + len * 0.66, 1.02, -0.2), pos: V(rowX0 - 1.1, 1.52, Math.min(OPP_Z - 0.45, 2.98 + len * 0.15 + Math.max(0, 1.5 - a) * 1.6)) };
  }
  // in front of a rack, on its side of the aisle
  function rackView(R) {
    const W = vw(), H = vh(), Hf = H - topRes();
    const t = Math.tan(FOV * DEG / 2);
    const d = Math.min(OPP_Z - 0.35, Math.max((RACK_H + 0.28) / 2 / (t * Hf / H), (RACK_W + 0.42) / 2 / (t * W / H)));
    return { target: V(R.x, RACK_H / 2 + 0.02, R.z), pos: V(R.x, RACK_H / 2 + 0.16, R.z + R.dir * d) };
  }
  // a section from its bay: the sign over you, the kiosk at your side, its racks going away
  function sectionView(S) {
    const a = vw() / vh();
    if (a < 1.05) return { target: V(S.x0 + 2.4, 1.45, ZC - 0.2), pos: V(S.x0 - 2.9, 1.55, ZC + 0.2) };
    return { target: V(S.x0 + 2.6, 1.58, ZC - 0.25), pos: V(S.x0 - 2.4, 1.55, ZC + 0.35) };
  }
  function wallView() {
    const W = vw(), H = vh(), t = Math.tan(FOV * DEG / 2);
    // the screens, and the podium in front of them along the bottom of the frame
    const d = Math.max(2.8 / 2 / (t * (H - topRes()) / H), 4.5 / 2 / (t * W / H));
    return { target: V(WALL_X, 1.6, ZC), pos: V(Math.max(endL + 0.6, WALL_X - d), 1.52, ZC) };
  }
  function podiumView() {
    return { target: V(WALL_X - 0.8, 0.84, ZC), pos: V(WALL_X - 2.35, 1.2, ZC - 0.55) };
  }
  function chartView() {
    const a = vw() / vh();
    if (!corridor) {
      const rx0 = SECS[0].racks[0].x, nR = SECS[0].nR;
      if (a < 1.05) return { target: V(rx0 + 0.1, 1.0, 0.15), pos: V(rx0 - 1.2, 1.7, 2.6) };
      return { target: V(midX + 0.15, 0.95, 0.12), pos: V(rowX0 - 1.4, 1.9, Math.min(OPP_Z - 0.4, 2.0 + 0.13 * nR)) };
    }
    // the section's row of drawers along its length, as in the one aisle
    const S = cur, mx = (S.rx0 + S.rx1) / 2;
    if (S.nR === 1 || a < 1.05) return { target: V(S.rx0 + 0.35, 0.98, 0.15), pos: V(S.rx0 - 1.0, 1.75, 2.6) };
    return { target: V(mx + 0.15, 0.95, 0.12), pos: V(S.rx0 - 1.4, 1.9, Math.min(OPP_Z - 0.4, 2.0 + 0.13 * S.nR)) };
  }
  function reserve() {
    const W = vw(), H = vh();
    if (W <= 760) { const r = panel.getBoundingClientRect(); return { x: 0, y: Math.min(H * 0.6, (r.height || H * 0.5) + 24) }; }
    return { x: Math.min(panel.classList.contains('wide') ? 580 : 420, W - 32) + 32, y: 0 };
  }
  function popView(u) {
    const W = vw(), H = vh(), S = reserve();
    const t = Math.tan(FOV * DEG / 2);
    const tx = t * (W - S.x) / H, ty = t * (H - S.y - topRes()) / H;
    const d = Math.max(0.34, (PANEL_W * 0.58) / (0.78 * tx), 0.2 / (0.86 * ty));
    const yaw = u.yaw + 0.2, el = 0.6;
    const c = Math.cos(u.yaw), s = Math.sin(u.yaw), lz = POP - 0.21;
    const target = V(u.x0 + s * lz, u.y0 + 0.075, u.z0 + c * lz);
    const pos = target.clone().add(V(Math.sin(yaw) * Math.cos(el), Math.sin(el), Math.cos(yaw) * Math.cos(el)).multiplyScalar(d));
    pos.y = clamp(pos.y, 0.15, CEIL - 0.25);
    pos.z = u.dir > 0 ? Math.min(pos.z, OPP_Z - 0.35) : Math.max(pos.z, 0.35);
    return { pos, target };
  }

  /* tweens: camera moves, slides, the panel's shift */
  const tweens = new Set();
  function tween(dur, step, ease, done, delay) {
    if (reduced || dur <= 0) { step(1); if (done) done(); return null; }
    const tw = { t0: performance.now() + (delay || 0), dur, step, ease: ease || easeInOut, done };
    tweens.add(tw); invalidate();
    return tw;
  }
  function runTweens(now) {
    for (const tw of Array.from(tweens)) {
      if (now < tw.t0) continue;
      const k = clamp((now - tw.t0) / tw.dur, 0, 1);
      tw.step(tw.ease(k));
      if (k >= 1) { tweens.delete(tw); if (tw.done) tw.done(); }
    }
    return tweens.size > 0;
  }
  let camTw = null;
  function stopCam() { if (camTw) { tweens.delete(camTw); camTw = null; } }
  // a long flight goes by the middle of the aisle, above the heads, so it does not cut through racks
  const _arc = new THREE.Vector3();
  let spyRef = null;   // the visitor, once she is in: she keeps out of the views flown to
  function flyTo(view, dur) {
    if (spyRef) spyRef.shot = view;
    stopCam();
    hideTips();
    if (hovered && hovered !== popped) setHover(null);   // the pointer no longer means what it meant
    if (controls._sphericalDelta) controls._sphericalDelta.set(0, 0, 0);
    if (controls._panOffset) controls._panOffset.set(0, 0, 0);
    const p0 = camera.position.clone(), t0 = controls.target.clone();
    const dist = p0.distanceTo(view.pos) + t0.distanceTo(view.target);
    const arc = corridor && Math.abs(p0.x - view.pos.x) > 2.5 ? V((p0.x + view.pos.x) / 2, Math.max(p0.y, view.pos.y, 1.5) + 0.25, ZC) : null;
    camTw = tween(dur || clamp(520 + dist * 230, 650, corridor ? 1700 : 1400), k => {
      if (arc) {
        const a = (1 - k) * (1 - k), b = 2 * (1 - k) * k, c = k * k;
        camera.position.set(a * p0.x + b * arc.x + c * view.pos.x, a * p0.y + b * arc.y + c * view.pos.y, a * p0.z + b * arc.z + c * view.pos.z);
      } else camera.position.lerpVectors(p0, view.pos, k);
      controls.target.lerpVectors(t0, view.target, k);
    }, easeInOut, () => { camTw = null; });
    invalidate();
  }
  let shiftTw = null;
  function shiftTo(S) {
    if (shiftTw) tweens.delete(shiftTw);
    const x0 = shift.x, y0 = shift.y;
    shiftTw = tween(340, k => { shift.x = x0 + (S.x - x0) * k; shift.y = y0 + (S.y - y0) * k; applyView(); }, easeOut, () => { shiftTw = null; });
  }

  /* the units' slides */
  let hovered = null, popped = null, home = null, aligned = -1, atOverview = true, chart = null, filter = null, mon = null;
  const restSlide = u => (chart && u.sec === cur ? u.chartS : Math.max(u.litUp ? 0.032 : 0, u === hovered ? LIFT : 0));
  function setSlide(u, s) {
    u.slide = s;
    if (!u.cmp) u.group.position.z = u.z0 + u.dir * s;
    if (s > 0.0006) slid.add(u); else slid.delete(u);
    const vis = s > 0.0006, cin = chart && u.sec === cur, close = vis && (!cin || u === popped || u === hovered);
    u.plate.visible = !!u.cmp || close;   // in the chart, the coloured bodies say it all
    u.railL.visible = u.railR.visible = !u.cmp && close;
    u.body.visible = vis && u !== popped && !cin && !u.cmp;
    placeUnit(u);
    if (chart) placeChartBody(u);
    if (shadow.userData.u === u) shadow.material.opacity = 0.42 * clamp01(s / POP);
  }
  function slideTo(u, to, dur, ease, done, delay) {
    if (u.tw) { tweens.delete(u.tw); u.tw = null; }
    const from = u.slide;
    if (Math.abs(to - from) < 1e-5) { if (done) done(); return; }
    u.tw = tween(dur, k => setSlide(u, from + (to - from) * k), ease, () => { u.tw = null; if (done) done(); }, delay);
  }

  /* hover, tooltips */
  function setHover(u) {
    if (u !== hovered) {
      const prev = hovered;
      hovered = u;
      if (prev) { faceGlow(prev); if (prev !== popped && !prev.cmp && !(chart && prev.sec === cur)) slideTo(prev, restSlide(prev), 160, easeOut); }
      if (u) { faceGlow(u); if (u !== popped && !u.cmp && !(chart && u.sec === cur)) slideTo(u, restSlide(u), 140, easeOut); }
      cv.classList.toggle('hot', !!u);
      if (!popped) nocDue('sel', 'hist');
      invalidate();
    }
  }
  const _tint = new THREE.Color(), _col = new THREE.Color();
  function faceGlow(u) {
    const tint = chart && u.sec === cur && u.chartV != null ? rampColor(P.ramp, u.chartV) : null;
    const em = tint || WHITE;
    _col.copy(WHITE).multiplyScalar(u.dim ? 0.13 : 1);
    if (tint && !u.dim) _col.lerp(tint, dark ? 0.18 : 0.32);
    const ei = u.dim ? P.faceEm * 0.25 : (tint ? (dark ? 0.62 : 0.14) : 0) + (u === hovered ? P.faceEmHot : P.faceEm);
    farFaces.setColorAt(u.gi, _col);
    setAttr(farFaces, 'aEm', u.gi, em.r, em.g, em.b, ei);
    farDirty();
    const e = u.near;
    if (e) {
      e.matFace.emissive.copy(em); e.matFace.color.copy(_col); e.matFace.emissiveIntensity = ei;
      e.matLcd.color.setScalar(u.dim ? 0.15 : 1);
    }
  }
  function placeTip(el, x, y) {
    const r = root.getBoundingClientRect();
    const w = el.offsetWidth, h = el.offsetHeight;
    let left = x - r.left + 16, top = y - r.top + 18;
    if (left + w > r.width - 8) left = x - r.left - w - 14;
    if (top + h > r.height - 8) top = y - r.top - h - 14;
    el.style.transform = 'translate3d(' + Math.max(8, left) + 'px,' + Math.max(8, top) + 'px,0)';
  }
  function hideTips() { tipEl.classList.remove('on'); ledTipEl.classList.remove('on'); tipEl.dataset.k = ledTipEl.dataset.k = ''; }
  const cores = (u, n) => { const c = u.sec.hall.cores; return c ? ' (about ' + fmtN(Math.min(c, n / 100)) + ' of ' + c + ' cores)' : ' (about ' + fmtN(n / 100) + ' cores)'; };
  const fromRuns = u => (u.runFrom === 'tests' ? ' across its tests' : '');
  function pullLine(u) {
    if (!chart || u.sec !== cur) return '';
    const name = chartLabel();
    if (u.chartV == null) return '<div class="a3d-tt-k">Pulled out by ' + esc(name) + ': no figure, so it stays in</div>';
    let v = '';
    if (chart.kind === 'score') v = esc(u.score) + ' (' + Math.round(u.share * 100) + '% of the leader)';
    else if (chart.kind === 'test') { const l = u.leds[chart.i]; v = fmtN(clamp01(l.p) * 100, 1) + '% of the best' + (num(l.rps) != null ? ', ' + fmtRps(+l.rps) + ' req/s' : ''); }
    else if (chart.kind === 'cpu') v = fmtN(u.cpu) + '% CPU' + cores(u, u.cpu);
    else if (chart.kind === 'mem') v = fmtMem(u.mem) + ' (log scale)';
    else if (chart.kind === 'p99') v = fmtMs(u.p99) + ' p99 (log scale)';
    return '<div class="a3d-tt-s">Pulled out by ' + esc(name) + ': <b>' + v + '</b></div>';
  }
  function unitTip(u, region) {
    const kind = region ? region.kind : 'unit', h = '<div class="a3d-tt-h"><span class="a3d-tt-n">' + esc(u.fw) + '</span></div>', hall = u.sec.hall;
    if (kind === 'loc') return h + '<div class="a3d-tt-s">' + (u.fav ? '<span class="a3d-tt-fav">Locator light is on.</span> Click to turn it off.' : 'Locator light. Click to light it up and mark this entry as a favourite.') + '</div>';
    if (kind === 'act') return h + '<div class="a3d-tt-s">Activity light: it blinks faster the closer an entry is to the leader. This one runs at <b>' + fmtN(u.share * 100, 1) + '%</b> of the leader, one blink every ' + fmtN(2.6 - 2.0 * u.share, 1) + ' s.</div>';
    if (kind === 'err') return h + '<div class="a3d-tt-s">' + (u.errors > 0 ? 'Error light: <b>' + fmtN(u.errors) + '</b> responses were 4xx or 5xx' + fromRuns(u) + '.' : u.errors === 0 ? 'Error light off: no 4xx or 5xx responses' + fromRuns(u) + '.' : 'Error light: no error count for this view.') + '</div>';
    if (kind === 'mem') return h + '<div class="a3d-tt-s">' + (u.mem != null ? 'Memory gauge: <b>' + fmtMem(u.mem) + '</b>' + (u.runFrom === 'tests' ? ' (median across its tests)' : '') + '. The gauge reads on a log scale from ' + fmtMem(hall.mem[0]) + ' to ' + fmtMem(hall.mem[1]) + ', the section\'s range.' : 'Memory gauge: no memory figure for this view.') + '</div>';
    if (kind === 'fan') return h + '<div class="a3d-tt-s">' + (u.cpu != null ? 'Fans: <b>' + fmtN(u.cpu) + '% CPU</b>' + cores(u, u.cpu) + (u.runFrom === 'tests' ? ', the average across its tests' : '') + '. They spin at ' + Math.round((u.cpuN || 0) * 100) + '% of the busiest in the section.' : 'Fans idle: no CPU figure for this view.') + '</div>';
    if (kind === 'pips') return h + '<div class="a3d-tt-s">' + (u.completeness ? 'Completeness: ' + COMP.map(([k, n]) => (u.completeness[k] ? '<span class="a3d-tt-ok">' + n + '</span>' : '<span class="a3d-tt-no">no ' + n.toLowerCase() + '</span>')).join(', ') + '.' : 'Completeness pips off: not graded here.') + '</div>';
    if (kind === 'port') return h + '<div class="a3d-tt-s">Console port. ' + (mon && mon.u === u ? 'The crash cart is plugged in here.' : 'Click to roll the crash cart over and read its code.') + '</div>';
    const rc = u.rank <= 3 ? ' r' + u.rank : '';
    const meta = [corridor ? '<span style="color:' + esc(u.sec.color) + ';font-weight:650">' + esc(u.sec.label) + '</span>' : '', u.lang ? '<i style="background:' + esc(u.langColor) + '"></i>' + esc(u.lang) : '', esc(TYPE_NAMES[u.type] || ''), u.tuned ? 'Tuned' : '', u.engine && u.engine.toLowerCase() !== u.fw.toLowerCase() ? 'on ' + esc(u.engine) : '', u.fav ? '<span class="a3d-tt-fav">Locator on</span>' : '', u.cmp ? '<span style="color:' + esc(u.cmp.color) + ';font-weight:650">On the bench as ' + u.cmp.letter + '</span>' : '']
      .filter(Boolean).join('<span aria-hidden="true">·</span>');
    const facts = [['CPU', u.cpu != null ? fmtN(u.cpu) + '%' : null], ['Memory', u.mem != null ? fmtMem(u.mem) : null], ['p99', u.p99 != null ? fmtMs(u.p99) : null], ['Errors', u.errors != null ? fmtN(u.errors) : null]].filter(f => f[1] != null);
    return '<div class="a3d-tt-h"><span class="a3d-tt-r' + rc + '">#' + esc(u.rank) + '</span><span class="a3d-tt-n">' + esc(u.fw) + '</span></div>'
      + (meta ? '<div class="a3d-tt-m">' + meta + '</div>' : '')
      + (u.score ? '<div class="a3d-tt-s">' + esc(u.sec.metric) + ' <b>' + esc(u.score) + '</b>' + (u.share > 0 ? ' · ' + (u.share * 100).toFixed(u.share >= 0.995 ? 0 : 1) + '% of the leader' : '') + '</div>' : '')
      + pullLine(u)
      + (facts.length ? '<div class="a3d-tt-g">' + facts.map(([k, v]) => '<span>' + k + '</span><b>' + v + '</b>').join('') + '</div>' : '')
      + '<div class="a3d-tt-k">' + (u.cmp ? 'Click to read its card, Shift+click to put it back' : u === popped ? 'Click to slide it back in' : 'Click to slide it out, Shift+click to take it to the bench') + '</div>';
  }
  function ledFallback(u, i) {
    const t = u.sec.tests[i], l = u.leds[i];
    if (!t) return null;
    const rows = l ? [['Of the best', fmtN(clamp01(l.p) * 100, 1) + '%'], ['Throughput', num(l.rps) != null ? fmtRps(+l.rps) + ' req/s' : null], ['p99', num(l.p99ms) != null ? fmtMs(+l.p99ms) : null], ['CPU', num(l.cpu) != null ? fmtN(+l.cpu) + '%' : null], ['Memory', num(l.memMiB) != null ? fmtMem(+l.memMiB) : null], ['Bandwidth', num(l.bwMBs) != null ? fmtBw(+l.bwMBs) : null], ['Errors', num(l.errors) != null ? fmtN(+l.errors) : null]].filter(r => r[1] != null) : [];
    return '<div class="a3d-tt-h"><span class="a3d-tt-n">' + esc(t.label) + '</span></div><div class="a3d-tt-m">' + esc(u.fw) + (t.conns ? ' · ' + fmtN(t.conns) + ' connections' : '') + (l && l.best ? ' · <span class="a3d-tt-ok">best</span>' : '') + '</div>'
      + (rows.length ? '<div class="a3d-tt-g">' + rows.map(([k, v]) => '<span>' + k + '</span><b>' + v + '</b>').join('') + '</div>' : '<div class="a3d-tt-s">No result in this test.</div>');
  }
  function showTips(hit, x, y) {
    if (!hit) { hideTips(); return; }
    if (hit.text) {
      ledTipEl.classList.remove('on'); ledTipEl.dataset.k = '';
      if (tipEl.dataset.k !== hit.key) { tipEl.innerHTML = hit.text; tipEl.dataset.k = hit.key; }
      tipEl.classList.add('on'); placeTip(tipEl, x, y); return;
    }
    const { u, region } = hit;
    if (region.kind === 'led') {
      const k = u.sec.id + '|' + u.fw + '|' + region.i;
      if (ledTipEl.dataset.k !== k) {
        let h = null;
        try { h = o.ledTipHtml ? o.ledTipHtml(u.fw, region.i, sidOf(u)) : null; } catch (e) { console.error(e); }
        if (!h) h = ledFallback(u, region.i);
        ledTipEl.dataset.k = k;
        ledTipEl.innerHTML = h || '';
        ledTipEl.classList.toggle('on', !!h);
      }
      if (ledTipEl.classList.contains('on')) { tipEl.classList.remove('on'); tipEl.dataset.k = ''; placeTip(ledTipEl, x, y); return; }
    } else { ledTipEl.classList.remove('on'); ledTipEl.dataset.k = ''; }
    const k = u.sec.id + '|' + u.fw + '|' + region.kind + '|' + u.fav + '|' + (u === popped) + '|' + (u.cmp ? u.cmp.letter : '') + '|' + (chart ? chart.kind + chart.i : '');
    if (tipEl.dataset.k !== k) { tipEl.innerHTML = unitTip(u, region); tipEl.dataset.k = k; }
    tipEl.classList.add('on');
    placeTip(tipEl, x, y);
  }

  const ray = new THREE.Raycaster(), ndc = new THREE.Vector2();
  const nocMeshes = Object.values(noc).map(n => n.mesh);
  const extraPick = [];   // the cart, the bench: added by their own parts
  function regionOf(u, uv) {
    const L = u.sec.LY, nT = u.sec.nT;
    const px = uv.x * TW, py = (1 - uv.y) * TH;
    if (Math.hypot(px - L.locX, py - L.locY) < 14) return { kind: 'loc' };
    if (Math.hypot(px - L.actX, py - L.stY) < 7) return { kind: 'act' };
    if (Math.hypot(px - L.errX, py - L.stY) < 7) return { kind: 'err' };
    if (o.sourceUrl && px >= 977 && px < 990 && py >= 34 && py <= 58) return { kind: 'port' };
    if (px >= 996) return { kind: 'mem' };
    if (px >= L.pipX - 8 && px <= L.pipX + 19 && py >= L.pipY[0] - 9 && py <= L.pipY[1] + 9) return { kind: 'pips' };
    if (Math.hypot(px - L.fanX, py - L.cy) < L.fanR + 4) return { kind: 'fan' };
    if (nT > 0 && py >= L.eqY[0] - 6 && py <= L.eqY[1] + 6 && px >= L.eqX0 && px < L.eqX0 + nT * L.sp) return { kind: 'led', i: clamp(Math.floor((px - L.eqX0) / L.sp), 0, nT - 1) };
    return { kind: 'unit' };
  }
  function pick(x, y) {
    const r = cv.getBoundingClientRect();
    if (!r.width || !r.height) return null;
    ndc.set(((x - r.left) / r.width) * 2 - 1, -((y - r.top) / r.height) * 2 + 1);
    ray.setFromCamera(ndc, camera);
    const list = [farFaces, spy.proxy].concat(nocMeshes, pickRack, podiumPick, kiosks, signs, extraPick);
    for (const u of slid) list.push(u.plate, u.body);
    for (const kt of kits) if (kt.g.visible) { list.push(kt.chips, kt.board); if (kt.full) list.push(kt.lid); }
    const hits = ray.intersectObjects(list, false);
    if (!hits.length) return null;
    const h = hits[0], d = h.object.userData;
    if (d.npc) return { npc: true, key: 'npc', text: '<div class="a3d-tt-h"><span class="a3d-tt-n">' + SPY + '</span></div><div class="a3d-tt-k">Click to say hello</div>' };
    if (d.noc) {
      const n = noc[d.noc], cx = h.uv.x * 1280, cy = (1 - h.uv.y) * 720;
      const hh = n.hits.find(q => cx >= q.x && cx <= q.x + q.w && cy >= q.y && cy <= q.y + q.h);
      return hh ? { noc: d.noc, act: hh.act, text: '<div class="a3d-tt-s">' + esc(hh.tip) + '</div>', key: 'noc|' + d.noc + '|' + JSON.stringify(hh.act) } : { noc: d.noc };
    }
    if (d.part === 'pdu' || d.part === 'marquee') {
      const R = racks[d.rack];
      const text = d.part === 'pdu'
        ? '<div class="a3d-tt-h"><span class="a3d-tt-n">' + esc(rname(R)) + ' power strip</span></div><div class="a3d-tt-s">Load <b>' + Math.round(R.load * 100) + '%</b>: the rack\'s average share of the leader.</div><div class="a3d-tt-m">' + R.langs.map(l => '<i style="background:' + esc(l.color) + '"></i>' + esc(l.name) + ' ' + l.n).join('<span aria-hidden="true">·</span>') + '</div>'
        : '<div class="a3d-tt-h"><span class="a3d-tt-n">' + esc(rname(R)) + ' marquee</span></div><div class="a3d-tt-s">' + esc(d.msg.replace(/\s+•\s+$/, '').split(/\s+•\s+/).join(' · ')) + '</div>';
      return { text, key: d.part + R.gk };
    }
    if (d.part === 'sign' || d.part === 'kiosk') {
      const S = d.sec;
      return { act: { kind: 'sec', id: S.id }, key: 'sec|' + S.id, text: '<div class="a3d-tt-h"><span class="a3d-tt-n">' + esc(S.label) + '</span></div><div class="a3d-tt-s">' + esc(S.name || '') + '</div><div class="a3d-tt-m">' + plural(S.units.length, 'entry', 'entries') + ' · ' + plural(S.nT, 'test') + ' · ' + plural(S.nR, 'rack') + '</div><div class="a3d-tt-k">Click to walk in</div>' };
    }
    if (d.part === 'overall' || d.part === 'machine') return { key: d.part, text: '<div class="a3d-tt-s">' + (d.part === 'overall' ? 'The overall board: the top ten across every section.' : 'The test machine, and the sections in the order you meet them.') + '</div>' };
    if (d.cart) return { cart: true, key: 'cart', text: '<div class="a3d-tt-s">The crash cart. ' + (mon && mon.state === 'on' ? 'Click the screen to read it, Esc unplugs it.' : 'It rolls over when you plug a monitor into a unit.') + '</div>' };
    if (d.benchChip) return d.benchChip;
    if (h.object === farFaces && h.instanceId != null) { const u = all[h.instanceId]; return u ? { u, region: h.uv ? regionOf(u, h.uv) : { kind: 'unit' } } : null; }
    const u = d.u || (d.kit && d.kit.u);
    if (!u) return null;
    let region = { kind: 'unit' };
    if (d.part === 'chips' && h.instanceId != null) region = { kind: 'led', i: h.instanceId };
    return { u, region };
  }

  /* hi-res panel and display for the unit that is out */
  function hiRes(u, on) {
    if (on && !u.hi) {
      if (!u.near) grant(u);
      if (!u.near) return;
      const S = u.sec;
      const cf = canvas(TW * 2, TH * 2); drawFace(cf, u, S.LY, P);
      const cl = canvas(S.lcdPx[0] * 2, S.lcdPx[1] * 2); drawLcd(cl, u, P);
      u.hi = { tf: tex(cf), tl: tex(cl) };
      u.near.matFace.map = u.near.matFace.emissiveMap = u.hi.tf;
      u.near.matLcd.map = u.hi.tl;
    } else if (!on && u.hi) {
      if (u.near) { u.near.matFace.map = u.near.matFace.emissiveMap = u.near.tf; u.near.matLcd.map = u.near.tl; }
      for (const t of [u.hi.tf, u.hi.tl]) { freeImage(t); t.dispose(); bin.delete(t); }
      u.hi = null;
    }
    invalidate();
  }
  function redrawFace(u) {
    paintSlot(u); atlasT.needsUpdate = true;
    if (u.near) repaint(u.near.tf, faceW, faceH, c => drawFace(c, u, u.sec.LY, P));
    if (u.hi) repaint(u.hi.tf, TW * 2, TH * 2, c => drawFace(c, u, u.sec.LY, P));
    if (podiumSec === u.sec && u.rank <= 3) podiumDue = true;
  }

  /* slide out, slide back in */
  function updateLoc() {
    const u = cardU();
    if (!u) return;
    locBtn.setAttribute('aria-pressed', u.fav ? 'true' : 'false');
    locBtn.querySelector('span').textContent = u.fav ? 'Locator light on' : 'Locator light';
  }
  // the card on the right: a unit's, or the comparison's
  let cardMode = '', benchU = null;
  const cardU = () => (cardMode === 'unit' ? popped : cardMode === 'bench' ? benchU : null);
  function setCard(mode, u) {
    cardMode = mode;
    panel.classList.toggle('wide', mode === 'cmp' && cmp.length >= 3);
    const isUnit = mode === 'unit' || mode === 'bench';
    locBtn.hidden = !isUnit; pTitle.hidden = isUnit; putBtn.hidden = mode !== 'cmp'; pact.hidden = !isUnit;
    closeBtn.querySelector('span').textContent = mode === 'unit' ? 'Slide back in' : mode === 'bench' ? 'Back to the comparison' : 'Close';
    closeBtn.setAttribute('aria-label', mode === 'unit' ? 'Slide the unit back into the rack' : mode === 'bench' ? 'Back to the comparison' : 'Close the comparison');
    panel.setAttribute('aria-label', isUnit ? 'Unit details' : 'The comparison');
    if (isUnit) {
      let h = '';
      try { h = o.detailHtml ? o.detailHtml(u.fw, sidOf(u)) : ''; } catch (e) { console.error(e); }
      pbody.innerHTML = h || '';
      pbody.scrollTop = 0;
      updateLoc(); updateActs();
    }
    if (mode) { panel.classList.add('on'); panel.setAttribute('aria-hidden', 'false'); }
    else { panel.classList.remove('on'); panel.setAttribute('aria-hidden', 'true'); panel.classList.remove('wide'); }
  }
  function updateActs() {
    const u = cardU();
    if (!u) return;
    const on = !!u.cmp;
    cmpBtn.setAttribute('aria-pressed', String(on));
    cmpBtn.style.setProperty('--cc', on ? u.cmp.color : '');
    cmpBtn.querySelector('span').textContent = on ? 'On the bench as ' + u.cmp.letter + ', put it back' : cmp.length >= 4 ? 'Compare (the bench is full)' : 'Compare';
    cmpBtn.disabled = !on && cmp.length >= 4;
    if (monBtn) monBtn.querySelector('span').textContent = mon && mon.u === u ? 'Unplug the monitor' : 'Plug in a monitor';
  }
  function pop(u) {
    if (!u || popped === u) return;
    if (u.cmp) { focusBench(u); return; }
    if (corridor && u.sec !== cur) setSection(u.sec);
    if (mon && mon.u !== u) unplug(true);
    if (!popped) home = { pos: camera.position.clone(), target: controls.target.clone() };
    const prev = popped;
    popped = u;
    if (prev) slideBack(prev);
    aligned = -1; atOverview = false;
    hiRes(u, true);
    u.body.visible = false;
    if (chart) placeChartBody(u);
    slideTo(u, POP, 460, easeBack);
    if (kit0.tw) { tweens.delete(kit0.tw); kit0.tw = null; }
    dressKit(kit0, u);
    kit0.tw = tween(720, k => setKitOpen(kit0, k), easeInOut, () => { kit0.tw = null; }, reduced ? 0 : 380);
    shadow.userData.u = u; shadow.visible = true; shadow.material.opacity = 0.42 * clamp01(u.slide / POP);
    shadow.rotation.y = u.yaw;
    shadow.position.set(u.x0, u.y0 - UNIT_H / 2 - 0.0376, u.R.z + u.dir * (FACE_Z + 0.0006));
    setCard('unit', u);
    shiftTo(reserve());
    flyTo(popView(u), 900);
    live.textContent = u.fw + ' slid out of rack ' + rname(u.R) + ': rank ' + u.rank + (u.score ? ', ' + u.sec.metric.toLowerCase() + ' ' + u.score : '') + '.';
    nocDue('sel', 'hist');
    hideTips();
  }
  function slideBack(u) {
    slideTo(u, restSlide(u), 380, easeInOut, () => { if (popped !== u && !u.cmp && !(mon && mon.u === u)) hiRes(u, false); });
  }
  function unpop(restore, keepOut) {
    const u = popped;
    if (!u) return;
    if (mon && mon.u === u) unplug(true);
    popped = null;
    closeKit(kit0);
    if (!keepOut) slideBack(u);
    shadow.visible = false; shadow.userData.u = null;
    setCard('', null);
    shiftTo({ x: 0, y: 0 });
    if (restore !== false && home) flyTo(home, 760);
    home = null;
    if (!keepOut) live.textContent = u.fw + ' slid back into the rack.';
    nocDue('sel', 'hist');
    hideTips();
    if (panel.contains(document.activeElement)) cv.focus({ preventScroll: true });
  }
  function toggleFav(u) {
    let on = !u.fav;
    if (o.onFav) { try { const r = o.onFav(u.fw); if (typeof r === 'boolean') on = r; } catch (e) { console.error(e); } }
    // the same framework is the same favourite in every section
    for (const x of all) if (x.fw === u.fw) applyFav(x, on);
  }
  function applyFav(u, on) {
    on = !!on;
    if (u.fav === on) return;
    u.fav = on;
    redrawFace(u);
    ledsOf(u); ledAttrsDirty();
    favFx(u);
    if (cardU() === u) updateLoc();
    if (tipEl.classList.contains('on') && hovered === u) tipEl.dataset.k = '';
    live.textContent = u.fw + (on ? ': locator light on.' : ': locator light off.');
    invalidate();
  }

  /* lighting a set of units in the section: a language, a band of the histogram */
  function setFilter(f) {
    if (f && filter && f.kind === filter.kind && (f.kind === 'lang' ? f.name === filter.name : f.i === filter.i)) f = null;
    filter = f;
    const pred = !f ? null : f.kind === 'lang' ? (u => u.lang === f.name) : (u => Math.min(19, Math.floor(clamp01(u.share) * 20)) === f.i);
    let n = 0;
    for (const S of SECS) S.units.forEach((u, idx) => {
      const mine = S === cur, on = !pred || !mine || pred(u);
      if (pred && mine && on) n++;
      const dim = pred && mine && !on ? 1 : 0, lit = !!(pred && mine && on);
      if (u.dim !== dim) { u.dim = dim; faceGlow(u); ledsOf(u); if (chart) chartBodies.setColorAt(u.gi, chartColor(u, new THREE.Color())); }
      if (u.litUp !== lit) { u.litUp = lit; if (u !== popped && !u.cmp && !(chart && mine)) slideTo(u, restSlide(u), 320, easeOut, null, reduced ? 0 : (idx % perRack) * 4); }
    });
    ledAttrsDirty();
    if (chartBodies.instanceColor) chartBodies.instanceColor.needsUpdate = true;
    litBtn.hidden = !f;
    if (f) {
      const lang = f.kind === 'lang' ? cur.langs.find(l => l.name === f.name) : null;
      litBtn.querySelector('i').style.background = lang ? lang.color : rampCss(P.ramp, (f.i + 0.5) / 20);
      litBtn.querySelector('span').textContent = (lang ? lang.name : Math.round(f.i * 5) + '-' + Math.round(f.i * 5 + 5) + '% of the leader') + ' · ' + n + ' lit · clear';
      litBtn.setAttribute('aria-label', 'Clear the light on ' + (lang ? lang.name : 'that band') + ' (' + n + ' entries)');
      live.textContent = n + ' entr' + (n === 1 ? 'y' : 'ies') + ' lit up.';
    }
    nocDue('langs', 'hist');
    invalidate();
  }

  /* the drawer chart: every unit in the section slides out by a measure, its racks become a bar chart */
  function chartLabel() {
    if (!chart) return '';
    if (chart.kind === 'test') return cur.tests[chart.i] ? cur.tests[chart.i].label : 'a test';
    return { score: cur.metric.toLowerCase(), cpu: 'CPU', mem: 'memory', p99: 'p99 latency' }[chart.kind] || chart.kind;
  }
  function chartValue(u, c) {
    if (c.kind === 'score') return u.share;
    if (c.kind === 'test') { const l = u.leds[c.i]; const p = l ? num(l.p) : null; return p == null ? null : clamp01(p); }
    return { cpu: u.cpuN, mem: u.memN, p99: u.p99N }[c.kind];
  }
  function chartColor(u, col) {
    col.copy(u.chartV != null ? rampColor(P.ramp, u.chartV) : new THREE.Color(P.eqOff));
    return u.dim ? col.multiplyScalar(0.045) : col;   // linear: 0.045 reads as about a fifth
  }
  function syncPull() {
    const pullSel = segEl.querySelector('[data-pull-test]'), pullAll = segEl.querySelector('[data-pull-all]');
    for (const b of segEl.querySelectorAll('[data-pull]')) b.setAttribute('aria-pressed', String(chart ? b.dataset.pull === chart.kind : b.dataset.pull === 'off'));
    if (pullSel) { pullSel.value = chart && chart.kind === 'test' ? String(chart.i) : ''; pullSel.classList.toggle('on', !!(chart && chart.kind === 'test')); }
    if (pullAll) { pullAll.value = !chart ? 'off' : chart.kind === 'test' ? 't' + chart.i : chart.kind; pullAll.classList.toggle('on', !!chart); }
  }
  function setChart(c, quiet) {
    if (c && (c.kind === 'off' || (chart && c.kind === chart.kind && c.i === chart.i))) c = null;
    const was = chart;
    if (popped) unpop(false);
    chart = c;
    chartBodies.visible = !!chart;
    const col = new THREE.Color();
    cur.units.forEach((u, idx) => {
      if (u.cmp) return;
      const v = chart ? chartValue(u, chart) : null;
      u.chartV = v;
      u.chartS = chart && v != null ? 0.012 + v * (CHART_MAX - 0.012) : 0;
      if (chart) chartBodies.setColorAt(u.gi, chartColor(u, col));
      faceGlow(u);
      u.body.visible = false;
      slideTo(u, restSlide(u), 620, easeOut, () => { if (chart) placeChartBody(u); }, reduced ? 0 : idx * Math.max(1, 6 * 109 / Math.max(109, cur.units.length)));
      placeChartBody(u);
    });
    if (chartBodies.instanceColor) chartBodies.instanceColor.needsUpdate = true;
    syncPull();
    if (chart && !was && !quiet) { aligned = -1; atOverview = false; flyTo(chartView(), 1300); }
    live.textContent = chart ? 'Every drawer in ' + cur.label + ' pulled out by ' + chartLabel() + '.' : 'The drawers slid back in.';
    nocDue('view', 'tests');
    hideTips();
    invalidate();
  }

  /* ── the crash cart: a monitor and a keyboard on a trolley. It rolls up to a unit, a
     cable finds the console port on its front, the screen runs its POST and then shows
     the entry's code: its files, line numbers, highlighted, to scroll and select. ── */
  const cartG = new THREE.Group(); cartG.visible = false;
  const cartParts = [];
  const cartBox = (w, h, d, mat, x, y, z) => { const m = new THREE.Mesh(own(new THREE.BoxGeometry(w, h, d)), mat); m.position.set(x, y, z); m.userData = { cart: true }; cartG.add(m); cartParts.push(m); return m; };
  cartBox(0.56, 0.035, 0.46, M.cart, 0, 0.14, 0);
  cartBox(0.5, 0.02, 0.4, M.cartDark, 0, 0.5, 0);
  cartBox(0.3, 0.06, 0.22, M.cartDark, 0, 0.54, -0.02);
  for (const sx of [-1, 1]) cartBox(0.035, 0.86, 0.035, M.cart, sx * 0.25, 0.57, -0.19);
  cartBox(0.56, 0.025, 0.38, M.cart, 0, 0.96, 0.02);
  const kbT = tex(keepCv(keyboardTexture(P)));
  const kb = new THREE.Mesh(own(new THREE.BoxGeometry(0.44, 0.016, 0.15)), [M.cartDark, M.cartDark, std(0xffffff, 0.7, 0.2, { map: kbT }), M.cartDark, M.cartDark, M.cartDark]);
  kb.position.set(0, 0.981, 0.09); kb.rotation.x = 0.06; kb.userData = { cart: true }; cartG.add(kb); cartParts.push(kb);
  cartBox(0.045, 0.3, 0.045, M.cart, 0, 1.12, -0.16);
  for (const [sx, sz] of [[-1, -1], [1, -1], [-1, 1], [1, 1]]) {
    const w = new THREE.Mesh(own(new THREE.CylinderGeometry(0.034, 0.034, 0.028, 16)), M.rubber);
    w.rotation.z = Math.PI / 2; w.position.set(sx * 0.23, 0.036, sz * 0.18); cartG.add(w);
    cartBox(0.03, 0.07, 0.03, M.cartDark, sx * 0.23, 0.1, sz * 0.18);
  }
  const scrG = new THREE.Group(); scrG.position.set(0, 1.31, -0.13); scrG.rotation.x = -0.1;
  const scrHouse = new THREE.Mesh(own(new THREE.BoxGeometry(SCR_W + 0.034, SCR_H + 0.034, 0.03)), M.monitor);
  scrHouse.position.z = -0.016; scrHouse.userData = { cart: true };
  const scrCv = canvas(1024, 640);
  const scrT = tex(scrCv, { keep: true });
  const scrMesh = new THREE.Mesh(own(new THREE.PlaneGeometry(SCR_W, SCR_H)), display(basic(0xffffff, { map: scrT, toneMapped: false })));
  scrMesh.userData = { cart: true, screen: true };
  const scrLed = new THREE.Mesh(own(new THREE.PlaneGeometry(0.008, 0.004)), basic(new THREE.Color(P.ledG).multiplyScalar(1.4)));
  scrLed.position.set(SCR_W / 2 - 0.01, -SCR_H / 2 - 0.009, 0.0005);
  scrG.add(scrHouse, scrMesh, scrLed); cartG.add(scrG); cartParts.push(scrHouse, scrMesh);
  scene.add(cartG);
  extraPick.push(...cartParts);
  const cableMat = std(dark ? 0x4f9be0 : 0x3a86d4, 0.42, 0.05, { emissive: dark ? 0x0c2a48 : 0x000000 });   // a console cable is light blue
  let cable = null;
  const plug = new THREE.Mesh(own(new THREE.BoxGeometry(0.009, 0.016, 0.024)), std(0x2a3038, 0.4, 0.5));
  plug.visible = false; scene.add(plug);
  let cartTw = null, cableTw = null, bootTimer = 0, scrPaintAt = 0, scrDue = false;
  const monState = { mode: 'off' };
  function paintScreen() { paintMonitor(scrCv, monState); scrT.needsUpdate = true; scrDue = false; invalidate(); }
  paintScreen();

  // beside the unit, out in the aisle (or in front of the bench), turned to whoever stands in front of it
  const _f = new THREE.Vector3(), _rt = new THREE.Vector3();
  function cartSpot(u) {
    const p = u.group.position, f = _f.set(Math.sin(u.yaw), 0, Math.cos(u.yaw)), r = _rt.set(Math.cos(u.yaw), 0, -Math.sin(u.yaw));
    const out = u.cmp ? 0.66 : 0.46, side = 0.66;
    const x = p.x + f.x * out + r.x * side, z = p.z + f.z * out + r.z * side;
    const dx = f.x * 1.05 - r.x * 0.41, dz = f.z * 1.05 - r.z * 0.41;
    return { x, z, yaw: Math.atan2(dx, dz), fx: r.x * 2.6, fz: r.z * 2.6 };
  }
  function monView() {
    scrG.updateWorldMatrix(true, true);
    const C = new THREE.Vector3(), N = new THREE.Vector3(0, 0, 1), q = new THREE.Quaternion();
    scrMesh.getWorldPosition(C); scrMesh.getWorldQuaternion(q); N.applyQuaternion(q);
    const W = vw(), H = vh(), t = Math.tan(FOV * DEG / 2), a = W / H;
    const d = Math.max((SCR_H / 2) / (t * (small ? 0.5 : 0.62)), (SCR_W / 2) / (t * a * 0.84));
    return { pos: C.clone().addScaledVector(N, d), target: C };
  }
  // the cable: from the back of the monitor, down past the shelf, sagging, up into the port
  function buildCable(u) {
    if (cable) { scene.remove(cable); cable.geometry.dispose(); cable = null; }
    cartG.updateWorldMatrix(true, true); u.group.updateWorldMatrix(true, false);
    const a = new THREE.Vector3(0.12, 1.16, -0.17).applyMatrix4(cartG.matrixWorld);
    const b = new THREE.Vector3(0.26, 0.86, -0.2).applyMatrix4(cartG.matrixWorld);
    const port = new THREE.Vector3(PORT_X, PORT_Y, 0.002).applyMatrix4(u.group.matrixWorld);
    const f = new THREE.Vector3(Math.sin(u.yaw), 0, Math.cos(u.yaw));
    const d = port.clone().addScaledVector(f, 0.12), e = port.clone().addScaledVector(f, 0.012);
    const mid = b.clone().lerp(d, 0.5); mid.y = Math.min(b.y, d.y) - 0.22;
    const curve = new THREE.CatmullRomCurve3([a, b, mid, d, e], false, 'centripetal');
    const geo = new THREE.TubeGeometry(curve, 72, 0.0055, 8, false);
    cable = new THREE.Mesh(geo, cableMat); cable.frustumCulled = false;
    cable.userData = { curve, total: geo.index.count };
    geo.setDrawRange(0, 0);
    scene.add(cable);
  }
  function growCable(k) {
    if (!cable) return;
    const segs = Math.round(72 * k), c = cable.userData.curve;
    cable.geometry.setDrawRange(0, segs * 8 * 6);
    const t = clamp01(k), pt = c.getPointAt(t), tg = c.getTangentAt(Math.min(0.999, t));
    plug.visible = k > 0.02;
    plug.position.copy(pt); plug.lookAt(pt.clone().add(tg));
  }
  const MON_HELP = 'https://github.com/MDA2AV/HttpArena/tree/main/frameworks';
  const bundleCache = new Map();
  const EXT_LANG = { rs: 'rust', go: 'go', cs: 'csharp', java: 'java', kt: 'kotlin', scala: 'scala', js: 'js', mjs: 'js', ts: 'ts', py: 'python', rb: 'ruby', php: 'php', ex: 'elixir', exs: 'elixir', erl: 'erlang', zig: 'zig', c: 'c', h: 'c', cc: 'cpp', cpp: 'cpp', hpp: 'cpp', swift: 'swift', dart: 'dart', hs: 'haskell', ml: 'ocaml', fs: 'fsharp', clj: 'clojure', cr: 'crystal', nim: 'nim', d: 'd', jl: 'julia', lua: 'lua', pl: 'perl', v: 'v', mojo: 'mojo', toml: 'toml', yaml: 'yaml', yml: 'yaml', json: 'json', xml: 'xml', csproj: 'xml', html: 'html', md: 'markdown', sh: 'shell', gradle: 'gradle', cmake: 'cmake' };
  const langOfPath = p => { const b = p.split('/').pop().toLowerCase(); if (b.startsWith('dockerfile')) return 'docker'; if (b === 'makefile') return 'make'; if (b === 'cmakelists.txt') return 'cmake'; return EXT_LANG[b.split('.').pop()] || 'text'; };
  function loadBundle(u) {
    let url = null;
    try { url = o.sourceUrl ? o.sourceUrl(u.fw, sidOf(u)) : null; } catch (e) { console.error(e); }
    if (!url) return Promise.resolve({ err: 'none' });
    url = String(url);
    if (!bundleCache.has(url)) {
      bundleCache.set(url, fetch(url, { credentials: 'same-origin' })
        .then(r => (r.status === 404 ? { err: '404' } : r.ok ? r.json().then(b => ({ b })) : { err: 'http' }))
        .catch(() => { bundleCache.delete(url); return { err: 'net' }; }));
    }
    return bundleCache.get(url);
  }
  function normBundle(b, u) {
    b = b && typeof b === 'object' ? b : {};
    const files = (Array.isArray(b.files) ? b.files : []).filter(f => f && f.path != null && typeof f.text === 'string')
      .map(f => ({ path: String(f.path), lang: f.lang ? String(f.lang) : langOfPath(String(f.path)), bytes: num(f.bytes) != null ? +f.bytes : f.text.length, text: f.text }));
    const omitted = (Array.isArray(b.omitted) ? b.omitted : []).filter(f => f && f.path != null).map(f => ({ path: String(f.path), why: f.why ? String(f.why) : '', bytes: num(f.bytes) }));
    return { fw: b.fw != null ? String(b.fw) : u.fw, repo: b.repo ? String(b.repo) : '', files, omitted };
  }
  const repoFor = u => { try { return o.repoUrl ? String(o.repoUrl(u.fw, sidOf(u)) || '') : ''; } catch (e) { return ''; } };
  const fileUrl = (repo, path) => (repo ? repo.replace(/\/+$/, '').replace('/tree/', '/blob/') + '/' + path.split('/').map(encodeURIComponent).join('/') : '');
  const dots = (label, n) => label + ' ' + '.'.repeat(Math.max(2, n - label.length)) + ' ';
  function postLines(u) {
    return [
      ['HttpArena crash cart · console 2.4', ''],
      [dots('Port', 16), 'linked to ' + rname(u.R) + ', U' + (perRack - u.slot)],
      [dots('Unit', 16), u.fw + (u.lang ? '  ·  ' + u.lang : '') + (u.engine && u.engine.toLowerCase() !== u.fw.toLowerCase() ? '  ·  on ' + u.engine : '')],
      [dots('Rank', 16), '#' + u.rank + ' of ' + u.sec.units.length + (corridor ? ' in ' + u.sec.label : '') + (u.score ? '  ·  ' + u.score : '')],
      [dots('Memory', 16), u.mem != null ? fmtMem(u.mem) + ' in use' : 'not measured'],
      [dots('Implementation', 16), 'fetching…', '#ffd04a'],
    ];
  }
  // the console over the screen: its files, one open
  const mon$ = s => monEl.querySelector(s);
  const monName = mon$('.a3d-mon-h b'), monSub = mon$('.a3d-mon-h span'), monGh = mon$('.a3d-mon-h a'), monFiles = mon$('.a3d-mon-f');
  const monCode = mon$('.a3d-mon-c'), monGut = mon$('.a3d-gut'), monPre = mon$('.a3d-code code');
  if (small) monEl.classList.add('sheet');
  function monMsg(title, html, text) {
    monState.mode = 'msg'; monState.title = title; monState.text = text;
    monEl.classList.add('msg');
    monFiles.innerHTML = ''; monGut.textContent = '';
    monPre.innerHTML = '';
    monCode.innerHTML = '<div class="a3d-mon-msg"><b>' + esc(title) + '</b>' + html + '</div>';
    paintScreen();
  }
  function setFile(i) {
    const m = mon;
    if (!m || !m.bundle || !m.bundle.files.length) return;
    const fs = m.bundle.files;
    i = (i + fs.length) % fs.length;
    m.fi = i;
    const f = fs[i];
    m.lines = highlight(f.text, f.lang);
    monEl.classList.remove('msg');
    if (!monCode.contains(monPre)) { monCode.innerHTML = ''; monCode.append(monGut, monPre.parentNode); }
    monGut.textContent = m.lines.map((_, k) => k + 1).join('\n');
    monPre.innerHTML = hlHtml(m.lines);
    monCode.scrollTop = 0; monCode.scrollLeft = 0; m.top = 0;
    monSub.textContent = f.path + ' · ' + f.lang + ' · ' + fmtBytes(f.bytes) + ' · file ' + (i + 1) + ' of ' + fs.length;
    const href = fileUrl(m.bundle.repo, f.path);
    monGh.hidden = !href; if (href) monGh.href = href;
    monFiles.querySelectorAll('button').forEach((b, k) => { b.setAttribute('aria-selected', String(k === i)); if (k === i) b.scrollIntoView({ block: 'nearest' }); });
    Object.assign(monState, { mode: 'code', fw: m.u.fw, sub: monSub.textContent, files: fs, fi: i, lines: m.lines, top: 0 });
    paintScreen();
  }
  function showBundle() {
    const m = mon;
    if (!m) return;
    const r = m.res;
    monName.textContent = m.u.fw;
    if (!r || r.err || !r.b) {
      const repo = repoFor(m.u) || MON_HELP;
      const what = r && r.err === '404' ? 'There is no source bundle for ' + m.u.fw + ' on this page.' : r && r.err === 'none' ? 'This page does not serve source bundles.' : 'The source bundle for ' + m.u.fw + ' could not be loaded.';
      monSub.textContent = 'no implementation loaded';
      monGh.hidden = false; monGh.href = repo;
      monMsg('No implementation to show', '<p>' + esc(what) + ' Its implementation lives in the HttpArena repository.</p><p><a href="' + esc(repo) + '" target="_blank" rel="noopener">Browse it on GitHub</a></p>', what + ' Its implementation lives in the HttpArena repository on GitHub.');
      return;
    }
    m.bundle = normBundle(r.b, m.u);
    const fs = m.bundle.files;
    if (!fs.length) { monGh.hidden = !m.bundle.repo; if (m.bundle.repo) monGh.href = m.bundle.repo; monMsg('An empty bundle', '<p>The bundle lists no files.</p>', 'The bundle lists no files.'); return; }
    monFiles.innerHTML = fs.map((f, k) => '<button type="button" role="tab" data-fi="' + k + '" aria-selected="false" title="' + esc(f.path) + '"><span>' + esc(f.path) + '</span><small>' + esc(fmtBytes(f.bytes)) + '</small></button>').join('')
      + (m.bundle.omitted.length ? '<div class="om"><b>Not shown</b>' + m.bundle.omitted.map(f => esc(f.path) + (f.why ? ', ' + esc(f.why) : '') + (f.bytes != null ? ', ' + esc(fmtBytes(f.bytes)) : '')).join('<br>') + '</div>' : '');
    setFile(0);
  }
  function boot() {
    const m = mon;
    if (!m) return;
    m.state = 'boot';
    Object.assign(monState, { mode: 'post', post: postLines(m.u), postN: 0, cursor: true });
    const step = () => {
      if (mon !== m) return;
      if (m.res && monState.post[5][1] === 'fetching…') {
        const r = m.res;
        monState.post[5] = [dots('Implementation', 16), r.b ? plural(Array.isArray(r.b.files) ? r.b.files.length : 0, 'file') + ', ' + fmtBytes(sum((r.b.files || []).map(f => +f.bytes || (f.text || '').length))) : 'none found', r.b ? '#7dfbd8' : '#ff8a5b'];
      }
      if (monState.postN < monState.post.length) { monState.postN++; paintScreen(); bootTimer = setTimeout(step, reduced ? 0 : 150); return; }
      if (!m.res) { monState.cursor = !monState.cursor; paintScreen(); bootTimer = setTimeout(step, 260); return; }
      bootTimer = setTimeout(() => { if (mon !== m) return; m.state = 'on'; showBundle(); placeMon(true); invalidate(); }, reduced ? 0 : 420);
    };
    step();
  }
  function plugIn(u) {
    if (!o.sourceUrl || !u) return;
    if (mon && mon.u === u) return;
    if (mon) unplug(true);
    if (cartTw) { tweens.delete(cartTw); cartTw = null; }
    if (cableTw) { tweens.delete(cableTw); cableTw = null; }
    const m = mon = { u, state: 'in', fi: 0, top: 0, lines: [], res: null, bundle: null };
    grant(u); hiRes(u, true);
    loadBundle(u).then(r => { if (mon === m) { m.res = r; invalidate(); } });
    const sp = cartSpot(u);
    cartG.visible = true; cartG.rotation.y = sp.yaw;
    cartG.position.set(sp.x, 0, sp.z);
    Object.assign(monState, { mode: 'off' }); paintScreen();
    monName.textContent = u.fw; monSub.textContent = 'booting…'; monGh.hidden = true;
    setCard('', null);
    shiftTo({ x: 0, y: 0 });
    const view = monView();
    cartG.position.set(sp.x + sp.fx, 0, sp.z + sp.fz);
    cartTw = tween(900, k => { cartG.position.set(sp.x + sp.fx * (1 - k), 0, sp.z + sp.fz * (1 - k)); }, easeOut, () => {
      cartTw = null;
      if (mon !== m) return;
      buildCable(u);
      cableTw = tween(560, growCable, easeInOut, () => { cableTw = null; if (mon === m) boot(); });
    });
    flyTo(view, 1250);
    live.textContent = 'The crash cart rolls over to ' + u.fw + '.';
    updateActs();
    invalidate();
  }
  function unplug(instant) {
    const m = mon;
    if (!m) return;
    mon = null;
    clearTimeout(bootTimer);
    monEl.classList.remove('on'); monEl.hidden = true;
    if (cableTw) { tweens.delete(cableTw); cableTw = null; }
    if (cartTw) { tweens.delete(cartTw); cartTw = null; }
    const u = m.u;
    const away = () => { cartG.visible = false; plug.visible = false; if (cable) { scene.remove(cable); cable.geometry.dispose(); cable = null; } Object.assign(monState, { mode: 'off' }); paintScreen(); };
    if (instant || reduced) away();
    else {
      const sp = cartSpot(u), x0 = cartG.position.x, z0 = cartG.position.z;
      cableTw = tween(320, k => growCable(1 - k), easeIn, () => {
        cableTw = null;
        if (cable) { scene.remove(cable); cable.geometry.dispose(); cable = null; }
        plug.visible = false;
        cartTw = tween(760, k => cartG.position.set(x0 + sp.fx * k, 0, z0 + sp.fz * k), easeIn, () => { cartTw = null; if (!mon) away(); });
      });
    }
    if (!instant) {
      // back to the unit's card, out of its rack or on the bench
      if (popped === u) { setCard('unit', u); shiftTo(reserve()); flyTo(popView(u), 900); }
      else if (u.cmp) { if (benchU === u) { setCard('bench', u); shiftTo(reserve()); flyTo(benchCloseView(u), 900); } else openCompare(); }
      live.textContent = 'The monitor is unplugged from ' + u.fw + '.';
    }
    if (popped !== u && !u.cmp) hiRes(u, false);
    updateActs();
    invalidate();
  }
  // the console follows the screen: a homography from the console's box to the screen's corners
  const _cn = [new THREE.Vector3(), new THREE.Vector3(), new THREE.Vector3(), new THREE.Vector3()];
  const _sc = new THREE.Vector3(), _sn = new THREE.Vector3(), _sq = new THREE.Quaternion();
  function quadMatrix(w, h, p) {
    const [x0, y0] = p[0], [x1, y1] = p[1], [x2, y2] = p[2], [x3, y3] = p[3];
    const dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3, dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3;
    const den = dx1 * dy2 - dx2 * dy1;
    const g = Math.abs(den) > 1e-12 ? (dx3 * dy2 - dx2 * dy3) / den : 0, hh = Math.abs(den) > 1e-12 ? (dx1 * dy3 - dx3 * dy1) / den : 0;
    const a = x1 - x0 + g * x1, b = x3 - x0 + hh * x3, d = y1 - y0 + g * y1, e = y3 - y0 + hh * y3;
    return 'matrix3d(' + [a / w, d / w, 0, g / w, b / h, e / h, 0, hh / h, 0, 0, 1, 0, x0, y0, 0, 1].map(v => +v.toPrecision(12)).join(',') + ')';
  }
  let monShown = false;
  function placeMon(force) {
    const m = mon;
    const want = !!(m && m.state === 'on');
    if (!want) { if (monShown || !monEl.hidden) { monEl.classList.remove('on'); monEl.hidden = true; monShown = false; } return; }
    if (small) { if (!monShown) { monEl.hidden = false; monEl.style.transform = ''; monEl.classList.add('on'); monShown = true; } return; }
    scrMesh.updateWorldMatrix(true, false);
    scrMesh.getWorldPosition(_sc); scrMesh.getWorldQuaternion(_sq); _sn.set(0, 0, 1).applyQuaternion(_sq);
    const toCam = camera.position.clone().sub(_sc), dist = toCam.length();
    const facing = toCam.normalize().dot(_sn);
    const r = cv.getBoundingClientRect(), rr = root.getBoundingClientRect();
    const pts = [];
    let ok = facing > 0.62;
    [[-1, 1], [1, 1], [1, -1], [-1, -1]].forEach(([sx, sy], k) => {
      const v = _cn[k].set(sx * SCR_W / 2, sy * SCR_H / 2, 0).applyMatrix4(scrMesh.matrixWorld).project(camera);
      if (v.z > 1 || v.z < -1) ok = false;
      pts.push([r.left - rr.left + (v.x + 1) / 2 * r.width, r.top - rr.top + (1 - v.y) / 2 * r.height]);
    });
    const wpx = Math.hypot(pts[1][0] - pts[0][0], pts[1][1] - pts[0][1]);
    if (wpx < 420 || dist > 3) ok = false;
    if (ok) {
      monEl.hidden = false;
      monEl.style.transform = quadMatrix(MON_W, MON_H, pts);
      if (!monShown || force) { monEl.classList.add('on'); monShown = true; }
    } else if (monShown) { monEl.classList.remove('on'); monShown = false; }
  }
  function monScrolled() {
    if (!mon || monState.mode !== 'code') return;
    const top = monCode.scrollTop / 21;
    if (Math.abs(top - monState.top) < 0.5) return;
    monState.top = top;
    const now = performance.now();
    if (now - scrPaintAt > 90) { scrPaintAt = now; paintScreen(); } else if (!scrDue) { scrDue = true; setTimeout(() => { if (scrDue) { scrPaintAt = performance.now(); paintScreen(); } }, 100); }
  }
  monCode.addEventListener('scroll', monScrolled, { passive: true });
  monFiles.addEventListener('click', e => { const b = e.target.closest('[data-fi]'); if (b) { setFile(+b.dataset.fi); monCode.focus({ preventScroll: true }); } });
  function monKey(e) {
    const m = mon;
    if (!m) return false;
    const k = e.key;
    if (k === 'Escape') { unplug(); return true; }
    if (m.state !== 'on' || !m.bundle) return k === 'Tab' || k === 'ArrowLeft' || k === 'ArrowRight' || k === 'ArrowUp' || k === 'ArrowDown';
    if (k === 'ArrowRight' || (k === 'Tab' && !e.shiftKey)) { setFile(m.fi + 1); return true; }
    if (k === 'ArrowLeft' || (k === 'Tab' && e.shiftKey)) { setFile(m.fi - 1); return true; }
    const page = Math.max(1, Math.floor(monCode.clientHeight / 21) - 2) * 21;
    if (k === 'ArrowDown') { monCode.scrollTop += 21 * 3; return true; }
    if (k === 'ArrowUp') { monCode.scrollTop -= 21 * 3; return true; }
    if (k === 'PageDown' || k === ' ') { monCode.scrollTop += page; return true; }
    if (k === 'PageUp') { monCode.scrollTop -= page; return true; }
    if (k === 'Home') { monCode.scrollTop = 0; return true; }
    if (k === 'End') { monCode.scrollTop = monCode.scrollHeight; return true; }
    return false;
  }

  /* ── the comparison bench: up to four units out of their racks, side by side, lids
     off; one strength pentagon over them, an outline in each one's colour; a board of
     chips in front, the shared tests' chips grouped so their heights compare. ── */
  const cmp = [];
  const LETTERS = 'ABCD', SLOT_DX = 0.56;
  const benchPt = (x, y, z) => new THREE.Vector3(x, y, z).applyMatrix4(BENCH.m);
  const benchF = new THREE.Vector3(Math.sin(BENCH.yaw), 0, Math.cos(BENCH.yaw));
  // the shared pentagon over the bench
  const bhPx = small ? 512 : 768;
  const bhT = tex(canvas(4, 4));
  const bhMat = own(new THREE.ShaderMaterial({ uniforms: { tHolo: { value: bhT }, uTime: T, uAlpha: { value: 0 } }, vertexShader: HOLO_VS, fragmentShader: HOLO_FS, transparent: true, depthWrite: false, side: THREE.DoubleSide }));
  const benchHolo = new THREE.Mesh(own(new THREE.PlaneGeometry(0.62, 0.62)), bhMat);
  benchHolo.position.copy(benchPt(0, BENCH_Y + 0.86, -0.52)); benchHolo.rotation.order = 'YXZ'; benchHolo.rotation.set(-0.32, BENCH.yaw, 0); benchHolo.renderOrder = 6; benchHolo.visible = false;
  scene.add(benchHolo);
  // the chip board along the front of the bench: a group of chips per shared test
  const cbL = BENCH.L - 0.24, cbD = 0.24;
  const cbT = tex(canvas(4, 4));
  const chipBoard = new THREE.Mesh(own(new THREE.PlaneGeometry(cbL, cbD)), std(0xffffff, 0.55, 0.25, { map: cbT, emissiveMap: cbT, emissive: 0xffffff, emissiveIntensity: dark ? 0.32 : 0.06 }));
  chipBoard.rotation.set(-Math.PI / 2, 0, 0); chipBoard.rotation.y = 0;
  const cbG = new THREE.Group(); cbG.position.copy(benchPt(0, BENCH_Y + 0.002, 0.355)); cbG.rotation.y = BENCH.yaw;
  chipBoard.rotation.x = -Math.PI / 2; cbG.add(chipBoard);
  const cbChips = new THREE.InstancedMesh(chipGeo, chipMat, 4 * Math.max(1, maxNT));
  cbChips.count = 0; cbChips.frustumCulled = false; cbChips.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
  for (let i = 0; i < cbChips.instanceMatrix.count; i++) cbChips.setColorAt(i, WHITE);
  cbG.add(cbChips); cbG.visible = false;
  scene.add(cbG);
  chipBoard.userData = { benchBoard: true }; cbChips.userData = { benchChips: true };
  extraPick.push(chipBoard, cbChips);
  let cbTests = [];   // [{ S, t, label, x, vals: [p per unit] }]
  // a unit on the bench wears its letter: an outline round its front, a flag on its ear
  const outlineGeo = own(new THREE.PlaneGeometry(PANEL_W + 0.006, UNIT_H + 0.006));
  const outlineT = tex(keepCv((() => { const c = canvas(512, 64), x = c.getContext('2d'); x.clearRect(0, 0, 512, 64); x.strokeStyle = '#fff'; x.lineWidth = 7; rrect(x, 4, 4, 504, 56, 6); x.stroke(); return c; })()), { linear: true });
  const flagGeo = own(new THREE.PlaneGeometry(0.04, 0.04)), pinGeo = own(new THREE.BoxGeometry(0.0025, 0.03, 0.0025));
  const tagTs = P.cmp.map((c, i) => tex(keepCv(tagTexture(c, LETTERS[i]))));
  function wearTag(e) {
    const u = e.u, col = new THREE.Color(e.color);
    const ol = new THREE.Mesh(outlineGeo, basic(col.clone().multiplyScalar(dark ? 1.5 : 1), { alphaMap: outlineT, transparent: true, depthWrite: false, toneMapped: false }));
    ol.position.z = 0.0008; ol.renderOrder = 4;
    const flag = new THREE.Group(); flag.position.set(-PANEL_W / 2 + 0.03, UNIT_H / 2, 0.004);
    const pin = new THREE.Mesh(pinGeo, M.rail); pin.position.y = 0.015;
    const card = new THREE.Mesh(flagGeo, basic(0xffffff, { map: tagTs[e.L], toneMapped: false, side: THREE.DoubleSide })); card.position.set(0.021, 0.03 + 0.012, 0);
    flag.add(pin, card); flag.visible = false;
    u.group.add(ol, flag);
    e.tag = [ol, flag]; e.flag = flag;
  }
  function dropTag(e) { if (!e.tag) return; for (const m of e.tag) { e.u.group.remove(m); m.traverse(x => { if (x.material && x.material !== M.rail && x.material.map !== tagTs[e.L]) x.material.dispose(); }); } e.tag = null; e.flag = null; }
  function benchSlot(i, n) {
    return { pos: benchPt((i - (n - 1) / 2) * SLOT_DX, BENCH_Y + UNIT_H * 0.475 + 0.002, 0.2), yaw: BENCH.yaw };
  }
  const lerpYaw = (a, b, k) => { let d = ((b - a + Math.PI) % (2 * Math.PI) + 2 * Math.PI) % (2 * Math.PI) - Math.PI; return a + d * k; };
  // a flight: out of where it is, along the aisle above the heads, down onto its place
  function flight(u, to, yaw1, dur, done, delay, home) {
    if (u.ftw) { tweens.delete(u.ftw); u.ftw = null; }
    const p0 = u.group.position.clone(), y0 = u.yaw;
    const f0 = new THREE.Vector3(Math.sin(y0), 0, Math.cos(y0)), f1 = new THREE.Vector3(Math.sin(yaw1), 0, Math.cos(yaw1));
    const pts = [p0, p0.clone().addScaledVector(f0, 0.5).setY(p0.y + 0.06)];
    const far = p0.distanceTo(to) > 2.4;
    if (far) pts.push(new THREE.Vector3((p0.x + to.x) / 2, 2.3, corridor ? (Math.abs(p0.x - to.x) > 3 ? ZC : (p0.z + to.z) / 2) : (p0.z + to.z) / 2));
    pts.push(to.clone().addScaledVector(f1, 0.5).setY(to.y + (home ? 0.06 : 0.35)), to.clone());
    const curve = new THREE.CatmullRomCurve3(pts, false, 'centripetal');
    const T0 = dur || clamp(700 + curve.getLength() * 90, 900, 2300);
    u.ftw = tween(T0, k => {
      curve.getPointAt(k, u.group.position);
      u.yaw = lerpYaw(y0, yaw1, clamp01((k - 0.15) / 0.7));
      u.group.rotation.y = u.yaw;
      const e = u.cmp; if (e && e.flag) e.flag.visible = home ? k < 0.85 : k > 0.12;
      placeUnit(u);
      lodDirty = true;
    }, easeInOut, () => { u.ftw = null; if (done) done(); }, delay);
    if (!u.ftw && done) { /* reduced motion: done already ran */ }
  }
  function layoutBench(dur) {
    const n = cmp.length;
    cmp.forEach((e, i) => {
      const s = benchSlot(i, n);
      e.slot = s;
      if (e.state === 'bench') {
        const from = e.u.group.position.clone();
        if (from.distanceTo(s.pos) < 1e-4) return;
        if (e.u.ftw) { tweens.delete(e.u.ftw); e.u.ftw = null; }
        e.u.ftw = tween(dur || 420, k => { e.u.group.position.lerpVectors(from, s.pos, k); placeUnit(e.u); }, easeInOut, () => { e.u.ftw = null; });
      }
    });
    paintBench();
  }
  function shared() {
    // a test is shared when at least two of the frameworks on the bench have a result in it
    const fws = cmp.map(e => e.u.fw), out = [];
    for (const S of SECS) {
      const us = fws.map(fw => S.byFw.get(fw) || null);
      if (us.filter(Boolean).length < 2) continue;
      for (const t of S.tests) {
        const ls = us.map(u => (u && u.leds[t.i] && num(u.leds[t.i].p) != null ? u.leds[t.i] : null));
        if (ls.filter(Boolean).length >= 2) out.push({ S, t, us, ls });
      }
    }
    return out;
  }
  function paintBench() {
    const n = cmp.length;
    benchHolo.visible = n > 0; benchSign.visible = n === 0;
    bhMat.uniforms.uAlpha.value = n > 0 ? 1 : 0;
    if (n) repaint(bhT, bhPx, bhPx, c => drawHoloCompare(c, cmp.map(e => ({ u: e.u, color: e.color, letter: e.letter })), P));
    // the chip board: the shared tests of the first unit's section, or of the section most share
    const sh = shared();
    let lead = n ? cmp[0].u.sec : null;
    if (lead && !sh.some(x => x.S === lead)) { const cnt = new Map(); for (const x of sh) cnt.set(x.S, (cnt.get(x.S) || 0) + 1); lead = [...cnt.entries()].sort((a, b) => b[1] - a[1])[0]; lead = lead ? lead[0] : null; }
    const list = lead ? sh.filter(x => x.S === lead) : [];
    cbG.visible = n > 0;
    const gW = list.length ? Math.min(0.2, (cbL - 0.08) / list.length) : 0, cw = Math.min(0.026, gW * 0.8 / Math.max(1, n)), x0 = -((list.length - 1) * gW) / 2;
    cbTests = list.map((x, k) => ({ S: x.S, t: x.t, x: x0 + k * gW, ls: x.ls }));
    let ci = 0;
    const col = new THREE.Color();
    for (const g of cbTests) {
      g.ls.forEach((l, j) => {
        if (j >= n) return;
        const p = l ? clamp01(+l.p) : null, h = p == null ? 0.002 : 0.006 + p * 0.07;
        const x = g.x + (j - (n - 1) / 2) * cw * 1.25;
        cbChips.setMatrixAt(ci, _m4.makeScale(cw, h, cw).setPosition(x, 0.0012, -0.012));
        col.set(cmp[j].color); if (p == null) col.multiplyScalar(0.2); else if (l.best) col.lerp(WHITE, 0.35);
        cbChips.setColorAt(ci, col);
        ci++;
      });
    }
    cbChips.count = ci; cbChips.instanceMatrix.needsUpdate = true; if (cbChips.instanceColor) cbChips.instanceColor.needsUpdate = true;
    const W = 2048, H = Math.round(2048 * cbD / cbL);
    repaint(cbT, W, H, c => {
      const x = c.getContext('2d');
      x.fillStyle = P.pcb[0]; x.fillRect(0, 0, W, H);
      x.strokeStyle = P.pcb[1]; x.lineWidth = 3; for (let i = 0; i < 7; i++) { x.beginPath(); x.moveTo(0, 30 + i * 28); x.lineTo(W, 30 + i * 28); x.globalAlpha = 0.35; x.stroke(); }
      x.globalAlpha = 1;
      x.fillStyle = P.pcb[2]; x.textAlign = 'center';
      if (!cbTests.length) { x.font = '600 30px ' + FONT_SANS; x.fillText(cmp.length < 2 ? 'Bring a second unit to compare their tests here' : 'No test in common', W / 2, H - 24); }
      for (const g of cbTests) {
        const px = (g.x / cbL + 0.5) * W;
        const f = fit(x, g.t.label, '600', FONT_SANS, 26, 15, Math.max(40, (W / Math.max(1, cbTests.length)) - 10));
        x.font = '600 ' + f.px + 'px ' + FONT_SANS; x.fillText(f.text, px, H - 22);
      }
    });
    invalidate();
  }
  function trayHtml() {
    return cmp.map(e => '<li style="--cc:' + e.color + '"><span class="a3d-let">' + e.letter + '</span>' + esc(e.u.fw) + (corridor ? ' <small style="color:var(--a3-muted);font-weight:500">' + esc(e.u.sec.label) + '</small>' : '') + '</li>').join('');
  }
  function updateTray() {
    const n = cmp.length;
    trayEl.hidden = !n || cardMode === 'cmp' || cardMode === 'bench';
    trayEl.querySelector('ul').innerHTML = trayHtml();
    benchChip.querySelector('.a3d-dots').innerHTML = cmp.map(e => '<i style="--cc:' + e.color + '"></i>').join('');
    benchChip.setAttribute('aria-label', n ? 'Go to the comparison bench, ' + n + ' unit' + (n === 1 ? '' : 's') + ' on it' : 'Go to the comparison bench');
    updateActs();
    if (cardMode === 'cmp') renderCompare();
  }
  function addCompare(u) {
    if (u.cmp || cmp.length >= 4) { if (cmp.length >= 4) toast('The bench holds four. Put one back first.'); return; }
    if (mon && mon.u === u) unplug(true);
    if (popped === u) unpop(false, true);
    if (u.tw) { tweens.delete(u.tw); u.tw = null; }
    const used = new Set(cmp.map(e => e.L));
    const L = [0, 1, 2, 3].find(i => !used.has(i));
    const e = { u, L, letter: LETTERS[L], color: P.cmp[L], state: 'going', kit: null };
    cmp.push(e); cmp.sort((a, b) => a.L - b.L);
    u.cmp = e;
    u.litUp = false;
    setSlide(u, u.slide);
    grant(u); hiRes(u, true);
    let kit = kits.find(k => !k.full && !k.u);
    if (!kit) { kit = makeKit(false); kits.push(kit); }
    e.kit = kit;
    dressKit(kit, u); setKitOpen(kit, 0.25);
    wearTag(e);
    const s = benchSlot(cmp.indexOf(e), cmp.length);
    layoutBench();
    flight(u, s.pos, s.yaw, 0, () => {
      e.state = 'bench'; layoutBench(260);
      if (kit.tw) tweens.delete(kit.tw);
      kit.tw = tween(620, k => setKitOpen(kit, 0.25 + 0.75 * k), easeOut, () => { kit.tw = null; });
    });
    live.textContent = u.fw + ' goes to the comparison bench as ' + e.letter + '.';
    toast(u.fw + ' is on its way to the bench as ' + e.letter + (cmp.length >= 2 ? ' · Compare them from the bench' : ''));
    updateTray();
    nocDue('sel');
    invalidate();
  }
  function removeCompare(u, delay) {
    const e = u.cmp;
    if (!e || e.state === 'home') return;
    if (mon && mon.u === u) unplug(true);
    if (benchU === u) { benchU = null; if (cardMode === 'bench') setCard('', null); }
    e.state = 'home';
    const i = cmp.indexOf(e); if (i >= 0) cmp.splice(i, 1);
    const dest = new THREE.Vector3(u.x0, u.y0, u.z0);
    flight(u, dest, u.yaw0, 0, () => {
      u.yaw = u.yaw0; u.group.rotation.y = u.yaw;
      dropTag(e);
      closeKit(e.kit);
      u.cmp = null;
      u.group.position.set(u.x0, u.y0, u.z0);
      setSlide(u, 0);
      slideTo(u, restSlide(u), 200, easeOut);
      if (popped !== u) hiRes(u, false);
      if (chart && u.sec === cur) { u.chartV = chartValue(u, chart); u.chartS = u.chartV != null ? 0.012 + u.chartV * (CHART_MAX - 0.012) : 0; chartBodies.setColorAt(u.gi, chartColor(u, new THREE.Color())); faceGlow(u); slideTo(u, restSlide(u), 300, easeOut); }
      lodDirty = true;
      invalidate();
    }, delay, true);
    layoutBench();
    updateTray();
    if (cardMode === 'cmp' && !cmp.length) { setCard('', null); shiftTo({ x: 0, y: 0 }); }
    live.textContent = u.fw + ' goes back to rack ' + rname(u.R) + '.';
    invalidate();
  }
  function toggleCompare(u) { if (u.cmp) removeCompare(u); else addCompare(u); }
  function putAllBack() {
    if (!cmp.length) return;
    const list = cmp.slice();
    list.forEach((e, k) => removeCompare(e.u, k * 140));
    if (cardMode === 'cmp' || cardMode === 'bench') { setCard('', null); shiftTo({ x: 0, y: 0 }); }
    toast(list.length === 1 ? list[0].u.fw + ' goes back to its rack' : 'All ' + list.length + ' go back to their racks');
    updateTray();
  }
  function benchView() {
    const n = Math.max(2, cmp.length), hw = (n - 1) / 2 * SLOT_DX + 0.26;
    const bw = cbTests.length ? Math.max(hw, Math.abs(cbTests[0].x) + 0.1) : hw;
    const pts = [benchPt(-0.31, BENCH_Y + 1.17, -0.52), benchPt(0.31, BENCH_Y + 1.17, -0.52), benchPt(-bw, BENCH_Y, 0.48), benchPt(bw, BENCH_Y, 0.48), benchPt(-hw, BENCH_Y, 0.2), benchPt(hw, BENCH_Y, 0.2)];
    const target = benchPt(0, BENCH_Y + 0.42, -0.1), dir = benchPt(0, 0.5, 0.866).sub(benchPt(0, 0, 0)).normalize();   // under the lamps, not up among them
    return fitView(target, dir, pts, 1.0, 6, cmp.length && cardMode !== 'bench' ? reserve() : { x: 0, y: 0 });
  }
  function benchCloseView(u) {
    const W = vw(), H = vh(), S = reserve();
    const t = Math.tan(FOV * DEG / 2);
    const tx = t * (W - S.x) / H, ty = t * (H - S.y - topRes()) / H;
    const d = Math.max(0.42, (PANEL_W * 0.6) / (0.78 * tx), 0.22 / (0.86 * ty));
    const p = u.group.position, c = Math.cos(u.yaw), s = Math.sin(u.yaw), lz = -0.18;
    const target = V(p.x + s * lz, p.y + 0.06, p.z + c * lz), yaw = u.yaw + 0.16, el = 0.68;
    return { pos: target.clone().add(V(Math.sin(yaw) * Math.cos(el), Math.sin(el), Math.cos(yaw) * Math.cos(el)).multiplyScalar(d)), target };
  }
  function openCompare() {
    if (popped) unpop(false);
    if (mon) unplug(true);
    benchU = null;
    endTour();
    aligned = -1; atOverview = false;
    if (!cmp.length) {
      setCard('', null); shiftTo({ x: 0, y: 0 });
      flyTo(benchView(), 1300);
      toast('The bench is empty: Shift+click a unit, or press Compare on its card');
      return;
    }
    setCard('cmp', null);
    renderCompare();
    shiftTo(reserve());
    flyTo(benchView(), 1300);
    updateTray();
  }
  function focusBench(u) {
    if (popped) unpop(false);
    benchU = u;
    setCard('bench', u);
    shiftTo(reserve());
    flyTo(benchCloseView(u), 900);
    updateTray();
  }
  // the comparison's card: a column per unit, the best in each row marked
  function renderCompare() {
    const n = cmp.length;
    pTitle.textContent = 'On the bench · ' + plural(n, 'unit');
    panel.classList.toggle('wide', n >= 3);
    if (!n) { pbody.innerHTML = ''; return; }
    const fws = cmp.map(e => e.u.fw);
    const cell = (v, best, na) => '<div class="v' + (best ? ' best' : '') + (na ? ' na' : '') + '"' + (best ? ' aria-label="' + esc(v) + ', best"' : '') + '>' + esc(v) + '</div>';
    const row = (label, vals, fmt, better, sub) => {
      const nums = vals.map(v => (v == null || isNaN(v) ? null : +v)), have = nums.filter(v => v != null);
      const bestV = have.length >= 2 && better ? (better === 'max' ? Math.max(...have) : Math.min(...have)) : null;
      if (!have.length) return '';
      return '<div class="lb">' + esc(label) + (sub ? '<small>' + esc(sub) + '</small>' : '') + '</div>' + nums.map(v => cell(v == null ? 'none' : fmt(v), bestV != null && v === bestV && have.some(x => x !== bestV), v == null)).join('');
    };
    let h = '<div class="a3d-cmp-top">';
    if (n >= 2) {
      const href = '/compare/all/#' + encodeURIComponent(fws[0]) + '-vs-' + encodeURIComponent(fws[1]);
      h += '<a href="' + esc(href) + '">Open the head-to-head: ' + esc(fws[0]) + ' vs ' + esc(fws[1]) + '</a>';
    } else h += '<span>Bring up to three more: Shift+click a unit, or press Compare on its card.</span>';
    h += '</div><div class="a3d-cg" style="--n:' + n + '"><div class="hd" aria-hidden="true"></div>'
      + cmp.map((e, i) => '<div class="hd" style="--cc:' + e.color + '"><span class="a3d-let">' + e.letter + '</span><b>' + esc(e.u.fw) + '</b><small>' + esc((corridor ? e.u.sec.label + ' ' : '') + '#' + e.u.rank) + (e.u.lang ? ' · ' + esc(e.u.lang) : '') + '</small><button type="button" data-cmp-rm="' + i + '" aria-label="Put ' + esc(e.u.fw) + ' back in its rack">Put back</button></div>').join('');
    // score and rank, in every section any of them is in
    h += '<div class="gp">Score and rank<small>higher is better</small></div>';
    for (const S of SECS) {
      const us = fws.map(fw => S.byFw.get(fw) || null);
      if (!us.some(Boolean)) continue;
      const sc = us.map(u => (u ? scoreNum(u.score) : null));
      const have = sc.filter(v => v != null), best = have.length >= 2 ? Math.max(...have) : null;
      h += '<div class="lb">' + esc(corridor ? S.label : S.metric) + (corridor ? '<small>' + esc(S.metric) + '</small>' : '') + '</div>'
        + us.map((u, i) => (u ? cell((u.score || '–') + ' · #' + u.rank, best != null && sc[i] === best && have.some(x => x !== best), false) : cell('not in it', false, true))).join('');
    }
    // the shared tests: throughput, CPU, memory, p99, errors
    const sh = shared();
    if (sh.length) {
      h += '<div class="gp">Shared tests<small>lower is better for CPU, memory, p99 and errors</small></div>';
      for (const x of sh) {
        h += '<div class="gp" style="font-size:13px;padding-top:12px">' + esc((corridor ? x.S.label + ' · ' : '') + x.t.label) + (x.t.conns ? '<small>' + fmtN(x.t.conns) + ' connections</small>' : '') + '</div>';
        const g = k => x.ls.map(l => (l && num(l[k]) != null ? +l[k] : null));
        const rps = g('rps');
        h += rps.some(v => v != null) ? row('Requests/s', rps, fmtRps, 'max') : row('Of the best', x.ls.map(l => (l ? clamp01(+l.p) * 100 : null)), v => fmtN(v, 1) + '%', 'max');
        h += row('CPU', g('cpu'), v => fmtN(v) + '%', 'min') + row('Memory', g('memMiB'), fmtMem, 'min') + row('p99', g('p99ms'), fmtMs, 'min') + row('Errors', g('errors'), v => fmtN(v), 'min');
      }
    } else if (n >= 2) h += '<div class="gp">Shared tests<small>none: no test has a result from two of them</small></div>';
    // what they are, not only how fast
    h += '<div class="gp">The entry</div>';
    h += row('Completeness', cmp.map(e => (e.u.completeness ? COMP.filter(([k]) => e.u.completeness[k]).length : null)), v => v + ' of 4', 'max');
    h += row('Spec', cmp.map(e => e.u.spec), v => fmtN(v, v % 1 ? 1 : 0) + '%', 'max');
    h += row('Resilience', cmp.map(e => e.u.resil), v => fmtN(v, v % 1 ? 1 : 0) + '%', 'max');
    for (const [k, name] of STRENGTH) h += row(name, cmp.map(e => (e.u.strength ? num(e.u.strength[k]) : null)), v => fmtN(v), 'max', 'strength, of 100');
    h += '</div><p class="a3d-cmp-note">Each column is a framework as it stands in the section it came from; the score rows look it up in every section. The best in a row is marked.</p>';
    pbody.innerHTML = h;
  }
  pbody.addEventListener('click', e => { const b = e.target.closest('[data-cmp-rm]'); if (b && cmp[+b.dataset.cmpRm]) removeCompare(cmp[+b.dataset.cmpRm].u); });

  /* find a framework, in every section */
  let findSel = 0, findList = [];
  function renderFind() {
    const q = findIn.value.trim().toLowerCase();
    if (!q) { findRes.classList.remove('on'); findList = []; return; }
    findList = all.filter(u => u.fw.toLowerCase().includes(q))
      .sort((a, b) => (a.fw.toLowerCase().indexOf(q) - b.fw.toLowerCase().indexOf(q)) || (a.fw.length - b.fw.length) || a.fw.localeCompare(b.fw) || ((b.sec === cur) - (a.sec === cur)) || a.sec.k - b.sec.k)
      .slice(0, corridor ? 12 : 8);
    findSel = 0;
    findRes.innerHTML = findList.length
      ? findList.map((u, i) => '<li role="option" data-key="' + esc(u.sec.id + '|' + u.fw) + '"' + (i === 0 ? ' class="sel" aria-selected="true"' : '') + '><i style="background:' + esc(u.langColor) + '"></i><b>' + esc(u.fw) + '</b><small>'
        + (corridor ? '<span style="color:' + esc(u.sec.color) + '">' + esc(u.sec.label) + '</span> #' + esc(u.rank) : '#' + esc(u.rank) + ' · R' + (u.rack + 1)) + (u.cmp ? ' · bench ' + u.cmp.letter : '') + '</small></li>').join('')
      : '<li class="none">No framework matches that</li>';
    findRes.classList.add('on');
  }
  function moveFind(d) {
    if (!findList.length) return;
    findSel = (findSel + d + findList.length) % findList.length;
    findRes.querySelectorAll('li').forEach((li, i) => { li.classList.toggle('sel', i === findSel); li.setAttribute('aria-selected', String(i === findSel)); });
  }
  function chooseFind(key) {
    const u = byKey.get(key);
    findIn.value = ''; findRes.classList.remove('on'); findList = [];
    findIn.blur();
    if (u) { endTour(); pop(u); }
  }

  /* moving along: the racks of the section you are in, the sections, the ends */
  function setSection(S) {
    if (!S || S === cur) return;
    if (chart) setChart(null, true);
    if (filter) setFilter(null);
    cur = S;
    segEl.innerHTML = pullHtml(S); syncPull();
    secEls.forEach(c => { const on = c.dataset.sec === S.id; c.classList.toggle('on', on); c.setAttribute('aria-current', on ? 'true' : 'false'); });
    if (subEl) subEl.textContent = secLine(S);
    for (const id in noc) noc[id].due = true;
    podiumDue = true;
    hudRack = -2;
    live.textContent = S.label + (S.name ? ': ' + S.name : '') + ', ' + plural(S.units.length, 'entry', 'entries') + '.';
    invalidate();
  }
  const secAt = x => { let s = null; for (const S of SECS) if (x >= S.x0 - 0.2) s = S; return s; };
  function nearestRack() {
    let best = 0, bd = Infinity;
    cur.racks.forEach((R, k) => { const d = Math.abs(R.x - controls.target.x) + Math.abs(R.z - controls.target.z) * 0.35; if (d < bd) { bd = d; best = k; } });
    return best;
  }
  const inCur = () => controls.target.x >= cur.x0 - 0.2 && controls.target.x <= cur.x1 + 0.3;
  function navIdx(dir) {
    const n = cur.racks.length;
    if (atOverview || !inCur()) return dir > 0 ? 0 : -1;
    const k = (aligned >= 0 ? aligned : nearestRack()) + dir;
    return k >= 0 && k < n ? k : -1;
  }
  function leaveCards() { if (popped) unpop(false); if (mon) unplug(true); if (cardMode) { benchU = null; setCard('', null); shiftTo({ x: 0, y: 0 }); } updateTray(); }
  function goRack(k) {
    if (k < 0 || k >= cur.racks.length) return;
    leaveCards();
    aligned = k; atOverview = false;
    flyTo(rackView(cur.racks[k]));
    updateHud();
  }
  function goSection(S) {
    if (!S) return;
    leaveCards();
    setSection(S);
    aligned = -1; atOverview = false;
    flyTo(sectionView(S), 1500);
  }
  function goWall() {
    leaveCards();
    aligned = -1; atOverview = false;
    flyTo(wallView(), 1500);
  }
  function resetView() {
    leaveCards();
    aligned = -1; atOverview = true;
    flyTo(overview(), 1200);
  }
  const _ahead = new THREE.Vector3();
  let hudRack = -2, hudPrev = null, hudNext = null, hudWall = null, hudEnt = null, hudBench = null;
  function updateHud() {
    const tx = controls.target.x;
    // walking into a section makes it the one the wall, the podium and the tools speak for
    if (corridor && !camTw && !cardMode && !mon) {
      camera.getWorldDirection(_ahead); _ahead.y = 0; if (_ahead.lengthSq() > 1e-6) _ahead.normalize();
      const ax = camera.position.x + _ahead.x * 3, S = secAt(ax);
      if (S && S !== cur && camera.position.x < rowX1 - 0.4 && ax < rowX1 + 0.6) setSection(S);
    }
    let k = -1;
    if (!atOverview && inCur()) k = nearestRack();
    const atWall = tx > rowX1 + (corridor ? 0.9 : 1.4), atEnt = corridor && tx < SECS[0].x0 - 0.2 && cardMode !== 'cmp';
    if (atWall) k = -1;
    if (k !== hudRack) {
      hudRack = k;
      chipEls.forEach((c, i) => { c.classList.toggle('on', i === k); c.setAttribute('aria-current', i === k ? 'true' : 'false'); });
      if (whereEl) whereEl.textContent = k >= 0 ? 'R' + (k + 1) + ' of ' + cur.racks.length : '';
    }
    if (atWall !== hudWall) { hudWall = atWall; wallChip.classList.toggle('on', atWall); }
    if (entChip && atEnt !== hudEnt) { hudEnt = atEnt; entChip.classList.toggle('on', atEnt); }
    const atB = cardMode === 'cmp' || cardMode === 'bench';
    if (atB !== hudBench) { hudBench = atB; benchChip.classList.toggle('on', atB); updateTray(); }
    const p = navIdx(-1) < 0, n = navIdx(1) < 0;
    if (p !== hudPrev) { hudPrev = p; btn.prev.disabled = p; }
    if (n !== hudNext) { hudNext = n; btn.next.disabled = n; }
  }
  const _t0 = new THREE.Vector3(), _c0 = new THREE.Vector3();
  // in the hall but not through its glass, its roof or a row of cabinets; in the foyer, under its ceiling
  const inBlock = x => blocks.some(b => x > b[0] - PITCH / 2 - 0.15 && x < b[1] + PITCH / 2 + 0.15);
  const CAM_TOP = 4.6;   // up over the rows to see the hall, below the ducts and the roof's steel
  function clampView() {
    const t = controls.target, c = camera.position;
    _t0.copy(t); _c0.copy(c);
    c.x = clamp(c.x, endL + 0.25, WALL_X - 0.3);
    if (corridor && c.x < HX0 + 0.25) { c.z = clamp(c.z, FZ0 + 0.25, FZ1 - 0.25); c.y = clamp(c.y, 0.1, FH - 0.22); }
    else {
      c.z = clamp(c.z, HZ0 + 0.4, HZ1 - 0.4); c.y = clamp(c.y, 0.1, CAM_TOP);
      if (corridor && (c.z < FZ0 + 0.25 || c.z > FZ1 - 0.25 || c.y > FH - 0.22)) c.x = Math.max(c.x, HX0 + 0.3);
      if (c.y < RACK_H + 0.3 && inBlock(c.x)) for (const r of rowsZ) {
        const [z0, z1] = rspan(r);
        if (c.z > z0 - 0.15 && c.z < z1 + 0.15) { c.z = c.z - z0 < z1 - c.z ? z0 - 0.15 : z1 + 0.15; break; }
      }
    }
    t.x = clamp(t.x, endL + 0.3, WALL_X - 0.02); t.y = clamp(t.y, 0.12, HH - 1.0); t.z = clamp(t.z, HZ0 + 0.3, HZ1 - 0.3);
    if (!t.equals(_t0) || !c.equals(_c0)) camera.lookAt(t);
  }

  const keys = new Set();
  const MOVE = { ArrowLeft: 'l', KeyA: 'l', ArrowRight: 'r', KeyD: 'r', ArrowUp: 'f', KeyW: 'f', ArrowDown: 'b', KeyS: 'b', KeyQ: 'd', KeyE: 'u' };
  const fwd = new THREE.Vector3(), side = new THREE.Vector3(), mv = new THREE.Vector3(), UP = new THREE.Vector3(0, 1, 0);
  // a brisk walk (a sprint on Shift), eased in over a fraction of a second so a tap still nudges
  let walkHeld = 0;
  function walk(dt, fast) {
    camera.getWorldDirection(fwd); fwd.y = 0;
    if (fwd.lengthSq() < 1e-6) fwd.set(0, 0, -1);
    fwd.normalize(); side.crossVectors(fwd, UP).normalize();
    mv.set(0, 0, 0);
    for (const k of keys) {
      const a = MOVE[k];
      if (a === 'l') mv.sub(side); else if (a === 'r') mv.add(side); else if (a === 'f') mv.add(fwd);
      else if (a === 'b') mv.sub(fwd); else if (a === 'u') mv.y += 1; else if (a === 'd') mv.y -= 1;
    }
    if (mv.lengthSq() === 0) { walkHeld = 0; return false; }
    walkHeld += dt;
    mv.normalize().multiplyScalar((fast ? 7.5 : corridor ? 3.6 : 2.6) * Math.min(1, 0.3 + walkHeld * 2.4) * dt);
    mv.y *= 0.45;   // up and down at an easier pace: the ceiling is close
    camera.position.add(mv); controls.target.add(mv);
    return true;
  }

  /* the operations wall's screens repaint when what they show changes; far from them, one a frame */
  const selU = () => popped || benchU || hovered || null;
  const nocData = () => {
    const s = selU();
    return { units: cur.units, metric: cur.metric, leader: cur.hall.leader, sel: s && s.sec === cur ? s : null, bin: filter && filter.kind === 'bin' ? filter.i : null,
      view: corridor ? cur.label + (cur.name ? ' · ' + cur.name : '') : world.view ? String(world.view) : o.title || 'The aisle',
      round: world.round ? String(world.round) : '', racks: cur.nR, tests: cur.nT, langs: cur.langs, lit: filter && filter.kind === 'lang' ? filter.name : null, leaderU: cur.units[0] || null,
      pull: chart ? chartLabel() : '', family: cur.family, chart: chart && chart.kind === 'test' ? chart.i : null, machine };
  };
  let nocLast = 0;
  function nocDue(...ids) { for (const id of ids) noc[id].due = true; invalidate(); }
  function paintNoc(id) {
    const n = noc[id], ctx = n.cv.getContext('2d');
    ctx.setTransform(NOC_W / 1280, 0, 0, NOC_W / 1280, 0, 0);
    const pc = { width: 1280, height: 720, getContext: () => ctx }, d = nocData();
    n.hits = (id === 'hist' ? nocHist(pc, NC, P, d) : id === 'langs' ? nocLangs(pc, NC, d) : id === 'tests' ? nocTests(pc, NC, Object.assign({}, d, { tests: cur.tests })) : null) || [];
    if (id === 'view') {
      nocView(pc, NC, d);
      if (corridor) {
        // the wall can show any section: a strip of them along the bottom of its middle screen
        ctx.fillStyle = NC.bg; ctx.fillRect(4, 566, 1272, 150);
        ctx.fillStyle = NC.muted; ctx.font = '500 28px ' + FONT_SANS; ctx.textAlign = 'left';
        ctx.fillText(d.pull ? 'Drawers pulled out by ' + d.pull : 'Showing ' + cur.label + '. Click a section to show it here.', 48, 604);
        const cw = (1280 - 96 - (SECS.length - 1) * 12) / SECS.length;
        SECS.forEach((S, i) => {
          const x = 48 + i * (cw + 12), y = 628, on = S === cur;
          ctx.fillStyle = on ? S.color : NC.card; rrect(ctx, x, y, cw, 62, 10); ctx.fill();
          ctx.strokeStyle = on ? S.color : NC.line; ctx.lineWidth = 2; ctx.stroke();
          const f = fit(ctx, S.label, '700', FONT_LABEL, 30, 16, cw - 20);
          ctx.fillStyle = on ? '#0b0f14' : NC.text; ctx.font = '700 ' + f.px + 'px ' + FONT_LABEL; ctx.textAlign = 'center';
          ctx.fillText(f.text, x + cw / 2, centreY(ctx, f.text, y + 31));
          n.hits.push({ x, y, w: cw, h: 62, act: { kind: 'wallsec', id: S.id }, tip: 'Show ' + S.label + (S.name ? ', ' + S.name : '') + ' on the wall' });
        });
        ctx.textAlign = 'left';
      }
    } else if (id === 'machine') nocMachine(pc, NC, d); else if (id === 'sel') nocSel(pc, NC, P, d);
    n.t.needsUpdate = true; n.due = false;
  }
  function nocTick(now) {
    let pending = false, painted = 0;
    const near = camera.position.x > WALL_X - 9;
    for (const id in noc) {
      if (!noc[id].due) continue;
      if ((!near && painted) || ((id === 'sel' || id === 'hist') && now - nocLast < 140 && nocLast)) { pending = true; continue; }
      paintNoc(id); painted++;
      if (id === 'sel' || id === 'hist') nocLast = now;
    }
    if (podiumDue && (camera.position.x > WALL_X - 10 || !corridor)) skinPodium(cur);
    return pending;
  }

  /* the tour: a short walk past the notable units of the section you are in */
  let tour = null, tourTimer = 0;
  function buildTour() {
    const s = [], us = cur.units, S = cur;
    s.push({ view: corridor ? () => sectionView(S) : overview, title: corridor ? S.label + (S.name ? ': ' + S.name : '') : world.view ? String(world.view) : o.title || 'The aisle', text: plural(us.length, 'entry', 'entries') + ' in ' + plural(S.nR, 'rack') + ', best first. Every light, fan and gauge is a measurement: point at one to read it.' });
    if (us[0]) s.push({ u: us[0], title: 'The leader', text: us[0].fw + ' leads with ' + us[0].score + (us[0].lang ? ', written in ' + us[0].lang : '') + '. Its lid is off: a chip per test, a CPU that glows with its load, a stick of memory per step of its footprint.' });
    for (const l of S.langs.slice(0, 3)) if (l.best !== us[0]) s.push({ u: l.best, title: 'Best in ' + l.name, text: l.best.fw + ' is the best of the ' + l.n + ' ' + l.name + ' entr' + (l.n === 1 ? 'y' : 'ies') + ', at #' + l.best.rank + '.' });
    const lo = k => us.filter(u => u[k] != null && !u.cmp).sort((a, b) => a[k] - b[k] || a.rank - b.rank)[0];
    const fast = lo('p99'), lean = lo('mem');
    if (fast) s.push({ u: fast, title: 'The fastest p99', text: fast.fw + ' answers 99% of its requests within ' + fmtMs(fast.p99) + (fast.runFrom === 'tests' ? ' (its median across tests)' : '') + '.' });
    if (lean && lean !== fast) s.push({ u: lean, title: 'The leanest', text: lean.fw + ' gets by on ' + fmtMem(lean.mem) + ' of memory: one stick in its open chassis.' });
    if (us.length >= 3) s.push({ view: podiumView, title: 'The podium', text: 'The top three in front of the wall: ' + us.slice(0, 3).map(u => u.fw).join(', ') + '. Each block carries its unit in miniature, its own panel on its front.' });
    s.push({ wall: true, title: 'The operations wall', text: (corridor ? S.label + ' at a glance. ' : 'The hall at a glance. ') + 'Click a language or a bar to light its units, or a test to pull every drawer out by it.' });
    return s.filter(st => !st.u || !st.u.cmp);
  }
  function showStop() {
    clearTimeout(tourTimer);
    if (!tour) return;
    const st = tour.stops[tour.i];
    capEl.querySelector('b').textContent = st.title;
    capEl.querySelector('.a3d-cap-t').textContent = st.text;
    capEl.querySelector('.a3d-row span').textContent = (tour.i + 1) + ' of ' + tour.stops.length;
    capEl.querySelector('[data-act="tour-next"]').textContent = tour.i + 1 < tour.stops.length ? 'Next' : 'Finish';
    capEl.hidden = false;
    tour.busy = true;
    if (st.u) pop(st.u);
    else { if (popped) unpop(false); if (st.wall) { aligned = -1; atOverview = false; flyTo(wallView(), 1500); } else { atOverview = st.view === overview; aligned = -1; flyTo(st.view(), 1300); } }
    tour.busy = false;
    if (motion) tourTimer = setTimeout(() => nextStop(), 9000);
  }
  function startTour() { endTour(); leaveCards(); tour = { stops: buildTour(), i: 0 }; showStop(); }
  function nextStop() { if (!tour) return; tour.i++; if (tour.i >= tour.stops.length) { endTour(); resetView(); return; } showStop(); }
  function endTour() { clearTimeout(tourTimer); tourTimer = 0; if (!tour) return; tour = null; capEl.hidden = true; }

  /* a visitor: a woman in a dark belted trench coat and sunglasses, a visitor's badge on a lanyard.
     She walks the aisles, photographs a unit, plugs a USB stick into a section's leader, reads a kiosk;
     come close and she is suddenly very interested in her phone, or elsewhere. She keeps to the aisles
     and out of the foreground of a view you fly to. With Motion off she waits at the reception desk. */
  const SPY = 'Chinese spy', SPY_R = 0.26;
  const SPY_LINES = ['Just checking the air conditioning.', 'Lovely p99. Mind if I take a picture?', 'I’m only here for the source code. Kidding. Mostly.',
    'Visitor badge, see? Completely authorised.', 'Is that the leader up there? Asking for a friend.', 'Don’t mind me, I’m auditing the cable management.',
    'These racks run warm. All that throughput, I suppose.', 'I never saw this benchmark, and you never saw me.', 'Does this USB stick look suspicious to you?',
    'Just counting the requests per second.', 'The memory gauges in here are very informative.'];
  const spy = (() => {
    const sm = {
      coat: std(dark ? 0x2b3039 : 0x2a2f37, 0.68, 0, { side: THREE.DoubleSide }), lapel: std(dark ? 0x323843 : 0x30363f, 0.6, 0), knit: std(0x15171b, 0.85, 0), skin: std(0xd8ab90, 0.55, 0),
      hair: std(0x18120f, 0.42, 0), lens: std(0x040506, 0.08, 0.3), shoe: std(0x0b0c0e, 0.28, 0.1), lip: std(0xa66a6c, 0.5, 0), strap: std(0xc23a2b, 0.6, 0),
    };
    const badgeT = tex(keepCv((() => {
      const c = canvas(128, 192), x = c.getContext('2d');
      x.fillStyle = '#fbfbf8'; x.fillRect(0, 0, 128, 192); x.fillStyle = '#c23a2b'; x.fillRect(0, 0, 128, 52);
      x.fillStyle = '#fff'; x.font = '700 30px ' + FONT_SANS; x.textAlign = 'center'; x.fillText('Visitor', 64, 37);
      x.fillStyle = '#c9ced3'; x.fillRect(34, 66, 60, 70); x.fillStyle = '#8a929a'; x.fillRect(22, 150, 84, 9); x.fillRect(32, 166, 64, 8);
      return c;
    })()));
    sm.badge = std(0xffffff, 0.5, 0, { map: badgeT }); sm.buckle = M.rail;
    const root = new THREE.Group(), lists = new Map();
    // geometry by bone and material, merged into one mesh each
    const put = (bone, mk, geo, m) => { const k = bone.uuid + mk; if (!lists.has(k)) lists.set(k, { bone, mk, l: [] }); lists.get(k).l.push({ g: geo, m: m || new THREE.Matrix4() }); };
    const M4 = (x, y, z, rx = 0, ry = 0, rz = 0, sx = 1, sy = 1, sz = 1) => new THREE.Matrix4().compose(new THREE.Vector3(x, y, z), new THREE.Quaternion().setFromEuler(new THREE.Euler(rx, ry, rz)), new THREE.Vector3(sx, sy, sz));
    const ell = (bone, mk, rx, ry, rz, x, y, z, a = 0) => put(bone, mk, new THREE.SphereGeometry(1, 18, 12), M4(x, y, z, a, 0, 0, rx, ry, rz));
    // a limb from its joint down: round at both ends, tapering
    const limb = (bone, mk, r0, r1, len, sz) => {
      const pts = [];
      for (let i = 0; i <= 5; i++) { const a = i / 5 * Math.PI / 2; pts.push(new THREE.Vector2(Math.max(1e-4, r1 * Math.sin(a)), -len - r1 * Math.cos(a))); }
      for (let i = 0; i <= 5; i++) { const a = i / 5 * Math.PI / 2; pts.push(new THREE.Vector2(Math.max(1e-4, r0 * Math.cos(a)), r0 * Math.sin(a))); }
      put(bone, mk, new THREE.LatheGeometry(pts, 14), M4(0, 0, 0, 0, 0, 0, 1, 1, sz || 1));
    };
    const lathe = (bone, mk, pts, x, y, z, sz, p0, pl) => put(bone, mk, new THREE.LatheGeometry(pts.map(([r, h]) => new THREE.Vector2(r, h)), 20, p0 || 0, pl || Math.PI * 2), M4(x, y, z, 0, 0, 0, 1, 1, sz));
    const bone = (par, x, y, z) => { const b = new THREE.Group(); b.position.set(x, y, z); par.add(b); return b; };
    const pelvis = bone(root, 0, 0.95, 0), spine = bone(pelvis, 0, 0.09, 0), neck = bone(spine, 0, 0.4, 0), head = bone(neck, 0, 0.06, 0.005);
    const leg = [], arm = [];
    for (const sd of [1, -1]) {   // her left (+x), then her right
      const hip = bone(pelvis, sd * 0.085, -0.05, 0), knee = bone(hip, 0, -0.41, 0), ankle = bone(knee, 0, -0.415, 0);
      limb(hip, 'knit', 0.07, 0.05, 0.41, 0.95); limb(knee, 'knit', 0.048, 0.033, 0.415);
      ell(ankle, 'shoe', 0.04, 0.032, 0.115, 0, -0.04, 0.045); put(ankle, 'shoe', new THREE.BoxGeometry(0.045, 0.05, 0.035), M4(0, -0.05, -0.045));
      leg.push({ hip, knee, ankle });
      const sh = bone(spine, sd * 0.163, 0.335, 0), el = bone(sh, 0, -0.275, 0), hand = bone(el, 0, -0.245, 0);
      limb(sh, 'coat', 0.046, 0.042, 0.275); limb(el, 'coat', 0.042, 0.036, 0.235);
      ell(hand, 'skin', 0.021, 0.068, 0.034, 0, -0.058, 0.004);
      arm.push({ sh, el, hand });
    }
    // the coat: bodice, skirt to the knee, collar, belt and buckle; the knit at the neck
    lathe(spine, 'coat', [[0.128, -0.01], [0.137, 0.05], [0.151, 0.12], [0.162, 0.2], [0.163, 0.26], [0.165, 0.31], [0.158, 0.35], [0.13, 0.385], [0.08, 0.405], [0.056, 0.41]], 0, 0, 0, 0.64);
    lathe(pelvis, 'coat', [[0.214, -0.47], [0.197, -0.32], [0.184, -0.18], [0.172, -0.06], [0.15, 0.03], [0.132, 0.1]], 0, 0, 0, 0.78);
    lathe(spine, 'coat', [[0.07, 0.36], [0.1, 0.405], [0.092, 0.45]], 0, 0, 0.004, 0.8);
    put(spine, 'lens', new THREE.CylinderGeometry(0.14, 0.14, 0.04, 24, 1, true), M4(0, 0.005, 0, 0, 0, 0, 1, 1, 0.67));   // the belt
    put(spine, 'buckle', new THREE.BoxGeometry(0.045, 0.036, 0.01), M4(0, 0.005, 0.096));
    for (const sd of [-1, 1]) {
      put(spine, 'lapel', new THREE.BoxGeometry(0.05, 0.2, 0.006), M4(sd * 0.04, 0.27, 0.099, -0.18, 0, sd * 0.32));   // the lapels, a V to the belt
      for (const y of [0.1, 0.17]) put(spine, 'lens', new THREE.SphereGeometry(0.008, 8, 6), M4(sd * 0.05, y, 0.1));   // buttons, double-breasted
    }
    lathe(neck, 'knit', [[0.06, -0.03], [0.056, 0.02], [0.051, 0.06], [0.047, 0.088], [0.04, 0.092]], 0, 0, 0.004, 1.05);   // a high roll neck
    // the head: a face, sunglasses, a dark bob with a fringe
    put(head, 'skin', new THREE.LatheGeometry([[0.001, 0], [0.026, 0.006], [0.044, 0.024], [0.057, 0.05], [0.066, 0.08], [0.072, 0.11], [0.074, 0.14], [0.07, 0.17], [0.057, 0.193], [0.034, 0.206], [0.001, 0.211]].map(([r, h]) => new THREE.Vector2(r, h)), 22), M4(0, 0, 0, 0, 0, 0, 0.9, 1, 1.14));
    ell(head, 'skin', 0.0068, 0.015, 0.009, 0, 0.08, 0.077, -0.3); ell(head, 'lip', 0.0135, 0.0042, 0.005, 0, 0.043, 0.0715);
    for (const sd of [-1, 1]) { ell(head, 'lens', 0.026, 0.017, 0.006, sd * 0.029, 0.112, 0.085); put(head, 'lens', new THREE.BoxGeometry(0.004, 0.004, 0.09), M4(sd * 0.062, 0.115, 0.04)); }
    put(head, 'lens', new THREE.BoxGeometry(0.012, 0.004, 0.004), M4(0, 0.115, 0.089));
    lathe(head, 'hair', [[0.077, -0.012], [0.084, 0.02], [0.088, 0.06], [0.09, 0.11], [0.089, 0.15], [0.081, 0.18], [0.067, 0.203], [0.043, 0.219], [0.002, 0.227]], 0, 0, -0.004, 1.12, 1.02, Math.PI * 2 - 2.04);
    lathe(head, 'hair', [[0.087, 0.13], [0.086, 0.155], [0.079, 0.18], [0.065, 0.204], [0.041, 0.22], [0.002, 0.227]], 0, 0, -0.004, 1.12, -1.08, 2.16);
    // the lanyard and its badge
    for (const sd of [-1, 1]) { const a = new THREE.Vector3(sd * 0.05, 0.38, 0.065), b = new THREE.Vector3(0, 0.19, 0.112), m = a.clone().add(b).multiplyScalar(0.5); put(spine, 'strap', new THREE.BoxGeometry(0.009, a.distanceTo(b), 0.002), M4(m.x, m.y, m.z, -Math.atan2(b.z - a.z, a.y - b.y), 0, Math.atan2(b.x - a.x, a.y - b.y))); }
    put(spine, 'badge', new THREE.PlaneGeometry(0.052, 0.078), M4(0, 0.145, 0.116, -0.12));
    for (const { bone: b, mk, l } of lists.values()) { const me = new THREE.Mesh(own(mergeParts(l)), sm[mk]); b.add(me); }
    // what she holds: a small camera (right hand), a phone (left), a USB stick
    const camG = bone(arm[1].hand, 0, -0.085, 0.035), phoneG = bone(arm[0].hand, 0, -0.09, 0.03), usbG = bone(arm[1].hand, 0, -0.12, 0.02);
    camG.add(new THREE.Mesh(own(new THREE.BoxGeometry(0.105, 0.064, 0.05)), M.bezel), new THREE.Mesh(own(new THREE.CylinderGeometry(0.024, 0.024, 0.04, 16).rotateX(Math.PI / 2).translate(0, 0, -0.04)), M.dome));
    phoneG.add(new THREE.Mesh(own(new THREE.BoxGeometry(0.07, 0.14, 0.008)), M.bezel), new THREE.Mesh(own(new THREE.PlaneGeometry(0.062, 0.128).translate(0, 0, 0.0045)), basic(new THREE.Color(0.55, 0.75, 1).multiplyScalar(1.3))));
    usbG.add(new THREE.Mesh(own(new THREE.BoxGeometry(0.014, 0.034, 0.007)), M.rail));
    camG.visible = phoneG.visible = usbG.visible = false;
    phoneG.rotation.set(-0.3, 0, 0);
    // a soft shadow under her; a proxy the pointer finds her by; a flash for the camera
    const shadow = new THREE.Mesh(own(new THREE.PlaneGeometry(0.75, 0.75)), basic(0x000000, { alphaMap: glowT, transparent: true, opacity: dark ? 0.5 : 0.32, depthWrite: false }));
    shadow.rotation.x = -Math.PI / 2; shadow.position.y = 0.004; shadow.renderOrder = 1;
    const proxy = new THREE.Mesh(own(new THREE.CylinderGeometry(0.27, 0.27, 1.74, 8)), M.wire);
    proxy.position.y = 0.87; proxy.visible = false; proxy.userData = { npc: true };
    root.add(shadow, proxy);
    const flash = new THREE.Sprite(own(new THREE.SpriteMaterial({ map: glowT, color: new THREE.Color(1, 1, 1).multiplyScalar(12), blending: THREE.AdditiveBlending, depthWrite: false, transparent: true })));
    flash.scale.setScalar(0.08); flash.visible = false;
    const stick = new THREE.Group(), stickLed = new THREE.Mesh(own(new THREE.BoxGeometry(0.004, 0.004, 0.004)), basic(new THREE.Color(P.ledB).multiplyScalar(4)));
    stick.add(new THREE.Mesh(own(new THREE.BoxGeometry(0.012, 0.007, 0.03)), M.rail), stickLed); stickLed.position.set(0, 0, 0.016);
    scene.add(root, flash);

    /* where she may go: a lane down the corridor, the foyer, the cross aisles at the bays and the open
       cold aisle behind the racks; spots to stop at. Every leg is checked clear of what stands. */
    // the kiosks and the lobby boards stand in the way too
    const kio = new Map(), _bb = new THREE.Box3();
    for (const scr of kiosks) {
      const g = scr.parent; _bb.setFromObject(g);
      OBS.push([_bb.min.x, _bb.min.z, _bb.max.x, _bb.max.z]);
      if (scr.userData.sec) kio.set(scr.userData.sec, g);
    }
    const blockedAt = (x, z, r) => OBS.some(b => x > b[0] - r && x < b[2] + r && z > b[1] - r && z < b[3] + r);
    const clearLeg = (a, b) => { const n = Math.ceil(Math.hypot(b.x - a.x, b.z - a.z) / 0.08); for (let i = 0; i <= n; i++) if (blockedAt(a.x + (b.x - a.x) * i / n, a.z + (b.z - a.z) * i / n, SPY_R + 0.03)) return false; return true; };
    const nodes = [], spots = [];
    const node = (x, z) => { const nd = { x, z, nb: [], i: nodes.length }; nodes.push(nd); return nd; };
    const link = (a, b) => { if (a && b && a !== b && clearLeg(a, b)) { a.nb.push(b); b.nb.push(a); } };
    const LZ = 1.9, lane = [];
    const xs = new Set([WALL_X - 1.6]);
    if (corridor) { xs.add(-4.4); xs.add(-2.9); xs.add(-1.2); }
    else xs.add(Math.max(rowX0 - 0.6, endL + 1.8));
    // where she reads a kiosk: before its screen, a step back
    const readAt = new Map();
    for (const [S, g] of kio) { const ry = g.rotation.y, x = g.position.x + Math.sin(ry) * 0.85, z = g.position.z + Math.cos(ry) * 0.85; readAt.set(S, { x, z, yaw: Math.atan2(-Math.sin(ry), -Math.cos(ry)) }); xs.add(x); }
    for (const S of SECS) { if (corridor) xs.add(S.x0 + 0.9); for (const R of S.racks) xs.add(R.x); if (S.racks[0]) xs.add(S.racks[0].x + PORT_X - 0.16); }
    for (const x of [...xs].sort((a, b) => a - b)) lane.push(node(x, LZ));
    for (let i = 1; i < lane.length; i++) link(lane[i - 1], lane[i]);
    const laneAt = x => lane.reduce((b, n) => (Math.abs(n.x - x) < Math.abs(b.x - x) ? n : b), lane[0]);
    const spot = (kind, x, z, yaw, at, extra) => { const nd = node(x, z); link(at, nd); if (nd.nb.length) spots.push(Object.assign({ kind, nd, yaw }, extra || {})); return nd; };
    let home;
    if (corridor) {
      const f2 = node(-4.4, 2.6); link(laneAt(-4.4), f2);
      home = spot('desk', -5.05, FZ1 - 1.36, 0, f2);
    } else home = spot('wait', lane[0].x, LZ, Math.PI / 2, lane[0]);
    for (const S of SECS) {
      for (const R of S.racks) spot('photo', R.x, 1.02, Math.PI, laneAt(R.x), { R });
      // the leader's console port, in reach of her right hand
      if (S.racks[0]) { const ux = S.racks[0].x + PORT_X - 0.16; spot('usb', ux, 0.31, Math.PI, laneAt(ux), { S, R: S.racks[0] }); }
      const ra = readAt.get(S);
      if (ra) spot('read', ra.x, ra.z, ra.yaw, laneAt(ra.x));
      if (!corridor) continue;
      // through the bay, across the hot aisle, into the open cold aisle and along it
      if (visitA) {
        const za = (visitA[0] + visitA[1]) / 2, bay = laneAt(S.x0 + 0.9), h = node(S.x0 + 0.9, -RACK_D - HOT / 2), c = node(S.x0 + 0.9, za);
        link(bay, h); link(h, c); S.spyC = c;
        const blk = blocks.find(b => b[0] > S.x0 && b[0] < S.x1);
        if (blk) for (let x = blk[0] + PITCH; x < blk[1] - 0.01; x += 2 * PITCH) spot('photo', x, za, Math.PI, c);
      }
    }
    if (corridor && visitA) for (let i = 1; i < SECS.length; i++) link(SECS[i - 1].spyC, SECS[i].spyC);
    const reach = new Set(); { const st = [lane[0]]; while (st.length) { const n = st.pop(); if (reach.has(n)) continue; reach.add(n); st.push(...n.nb); } }
    const goals = spots.filter(s => reach.has(s.nd));
    const route = (from, to, avoid) => {
      const prev = new Map([[from, null]]), q = [from];
      while (q.length) { const n = q.shift(); if (n === to) break; for (const m of n.nb) if (!prev.has(m) && !(avoid && m !== to && avoid(m))) { prev.set(m, n); q.push(m); } }
      if (!prev.has(to)) return null;
      const out = []; for (let n = to; n; n = prev.get(n)) out.unshift(n);
      return out;
    };
    // the node to set off from: the nearest one a straight walk from here reaches
    const startNode = (x, z) => {
      const here = { x, z }, ns = nodes.filter(n => reach.has(n)).sort((a, b) => Math.hypot(a.x - x, a.z - z) - Math.hypot(b.x - x, b.z - z));
      return ns.find(n => clearLeg(here, n)) || ns[0];
    };

    /* the state: where she is, where she goes, what she does there */
    const st = { x: home.x, z: home.z, yaw: 0, v: 0, vmax: 1.2, path: [], goal: null, act: 'idle', t: 0, dur: 0, phase: 0, look: 0, lookT: 0, cool: 0, wait: 0, flashT: -1, usb: null, ts: 1, idle: true, fresh: true, shot: null };
    const rnd = rng((Math.random() * 4294967296) >>> 0);
    const close = (x, z, d) => camera.position.y < 2.7 && Math.hypot(camera.position.x - x, camera.position.z - z) < d;
    // in the foreground of a view: in its frame, nearer than what it looks at
    const _f = new THREE.Vector3(), _d = new THREE.Vector3(), _rgt = new THREE.Vector3();
    const inShot = (vw0, x, z) => {
      if (!vw0) return false;
      _f.copy(vw0.target).sub(vw0.pos); const dist = _f.length(); _f.normalize();
      _d.set(x - vw0.pos.x, 1.0 - vw0.pos.y, z - vw0.pos.z);
      const along = _d.dot(_f);
      if (along < 0.15 || along > dist * 0.95) return false;
      _rgt.crossVectors(_f, UP).normalize();
      const tv = Math.tan(FOV * DEG / 2), th = tv * vw() / vh();
      return Math.abs(_d.dot(_rgt)) < along * th + SPY_R && Math.abs(_d.y) < along * tv + 0.9;
    };
    const avoidShot = n => inShot(st.shot, n.x, n.z);
    const goTo = (target, brisk, then, avoid) => {
      const from = startNode(st.x, st.z), p = route(from, target.nd || target, avoid);
      if (!p) return false;
      st.path = (Math.hypot(from.x - st.x, from.z - st.z) < 0.05 ? p.slice(1) : p).map(n => ({ x: n.x, z: n.z }));
      st.goal = target.nd ? target : null; st.vmax = brisk ? 1.75 : 1.2; st.act = 'walk'; st.then = then || null; st.t = 0; st.at = null;
      return true;
    };
    const _pv = new THREE.Vector3();
    const choose = () => {
      // somewhere to go: not where the camera stands, not in the view it was flown to; rather
      // somewhere in sight, a little way off
      const cand = goals.filter(s => !close(s.nd.x, s.nd.z, 2.6) && !inShot(st.shot, s.nd.x, s.nd.z) && Math.hypot(s.nd.x - st.x, s.nd.z - st.z) > 1.5 && okSpot(s));
      if (!cand.length) return false;
      const w = cand.map(s => {
        const k = ({ photo: 3, usb: 1.4, read: 1.6, desk: 0.4, wait: 0.4 })[s.kind] || 1, d = Math.hypot(s.nd.x - camera.position.x, s.nd.z - camera.position.z);
        _pv.set(s.nd.x, 1.1, s.nd.z).project(camera);
        return k * (_pv.z < 1 && Math.abs(_pv.x) < 0.9 && Math.abs(_pv.y) < 0.9 && d > 2.6 && d < 16 ? 3 : 1);
      }), tot = w.reduce((a, b) => a + b, 0);
      for (let tries = 0; tries < 4; tries++) {
        let r = rnd() * tot, i = 0;
        while (r > w[i] && i < w.length - 1) r -= w[i++];
        if (goTo(cand[i], false, null, avoidShot)) return true;
      }
      return false;
    };
    // a rack someone is busy at: a unit out, on the bench, the crash cart at it
    const cartAt = R => cartG.visible && Math.abs(cartG.position.x - R.x) < 1.3 && cartG.position.z < 2.2;
    const rackBusy = R => cartAt(R) || (mon && mon.u && mon.u.R === R) || R.us.some(v => v === popped || v.cmp || v.slide > 0.04);
    const okSpot = s => !s.R || (s.kind === 'usb' ? !rackBusy(s.R) && !!s.S.units[0] : !cartAt(s.R));
    const leave = brisk => {
      // walk off, away from the camera (not past it) and out of the view
      const c = camera.position, opts = nodes.filter(n => reach.has(n) && Math.hypot(n.x - c.x, n.z - c.z) > 4.5 && !inShot(st.shot, n.x, n.z) && (n.x - c.x) * (st.x - c.x) + (n.z - c.z) * (st.z - c.z) > 0);
      opts.sort((a, b) => Math.hypot(a.x - st.x, a.z - st.z) - Math.hypot(b.x - st.x, b.z - st.z));
      for (const n of opts.slice(0, 6)) if (goTo(n, brisk)) return true;
      return false;
    };
    // a unit pulled out, the monitor plugged in: she drifts over for a look, from a few steps off
    const peek = u => {
      const ux = u.x0, uz = u.z0 + u.dir * 0.45, c = camera.position;
      const opts = lane.filter(n => reach.has(n) && Math.abs(n.x - ux) > 1.3 && Math.abs(n.x - ux) < 3.6 && Math.hypot(n.x - c.x, n.z - c.z) > 2.4 && !inShot(st.shot, n.x, n.z));
      opts.sort((a, b) => Math.hypot(a.x - st.x, a.z - st.z) - Math.hypot(b.x - st.x, b.z - st.z));
      for (const n of opts.slice(0, 3)) if (goTo(n, false, () => { begin('peek', 3.5 + rnd() * 2.5); st.yaw0 = Math.atan2(ux - st.x, uz - st.z); }, avoidShot)) return true;
      return false;
    };
    const stopProps = () => {
      camG.visible = phoneG.visible = usbG.visible = false; flash.visible = false; st.flashT = -1;
      if (st.usb) { st.usb.group.remove(stick); st.usb = null; }
    };
    const begin = (act, dur) => { stopProps(); st.act = act; st.t = 0; st.dur = dur; st.path = []; st.v = 0; st.at = null; };
    const _pp = new THREE.Vector3();
    const arrive = () => {
      const g = st.goal; st.goal = null;
      if (st.then) { const f = st.then; st.then = null; f(); return; }
      if (!g) { begin(rnd() < 0.5 ? 'glance' : 'phone', 2.5 + rnd() * 1.5); return; }
      st.yaw0 = g.yaw;
      if (g.kind === 'photo' && okSpot(g)) { begin('photo', 3.4); st.at = g; camG.visible = true; }
      else if (g.kind === 'usb' && okSpot(g)) {
        begin('usb', 4.8); st.at = g; usbG.visible = true;
        const u = st.usb = g.S.units[0]; stick.position.set(PORT_X, PORT_Y, 0.017); stick.rotation.set(0, 0, 0);
        // her right arm to the port: a two-bone reach in the plane she faces
        u.group.localToWorld(_pp.set(PORT_X, PORT_Y, 0.017));
        const f = Math.max(0.05, (st.z - _pp.z) * -Math.cos(g.yaw) + (st.x - _pp.x) * -Math.sin(g.yaw)), dy = _pp.y - 1.405;
        const L1 = 0.275, L2 = 0.33, d = clamp(Math.hypot(f, dy), 0.25, L1 + L2 - 0.002), at = Math.atan2(f, -dy);
        const a = Math.acos(clamp((L1 * L1 + d * d - L2 * L2) / (2 * L1 * d), -1, 1)), b = Math.PI - Math.acos(clamp((L1 * L1 + L2 * L2 - d * d) / (2 * L1 * L2), -1, 1));
        st.ik = [-(at - a), -b, clamp(dy, -0.5, 0.6)];
      } else if (g.kind === 'read') begin('read', 4 + rnd() * 2);
      else begin('phone', 3 + rnd() * 2);
    };
    const wrap = a => ((a + Math.PI) % (2 * Math.PI) + 2 * Math.PI) % (2 * Math.PI) - Math.PI, toward = (a, b, k) => a + wrap(b - a) * Math.min(1, k);

    /* one step of her life: dt seconds */
    function step(dt) {
      st.idle = false;
      st.cool = Math.max(0, st.cool - dt);
      st.lookT -= dt;
      const c = camera.position;
      // the camera close by: act casual (once in a while)
      if (st.cool <= 0 && close(st.x, st.z, 1.9)) { st.cool = 7; stopProps(); if (rnd() < 0.5 || !leave(true)) begin('phone', 3 + rnd() * 1.5); }
      // flown to a view she stands in the foreground of: out of it
      if (st.shot && st.cool < 5 && inShot(st.shot, st.x, st.z)) { st.cool = 6; stopProps(); leave(true); }
      // someone busy at the rack she is at: she steps away
      if (st.at && !okSpot(st.at)) { stopProps(); st.at = null; st.yaw0 = null; if (!leave(false)) begin('glance', 2); }
      // a unit out or the monitor in: worth a look
      const tgt = popped || (mon && mon.u) || null;
      if (tgt !== st.seen) { st.seen = tgt; if (tgt && !tgt.cmp && st.act !== 'usb' && rnd() < 0.7 && peek(tgt)) st.cool = Math.max(st.cool, 3); }
      if (st.act === 'walk') {
        const p = st.path[0];
        if (!p) { st.v = 0; arrive(); return; }
        // the camera in the way: wait, glance round; then go another way
        const ahead = st.path.slice(0, 2);
        let blocked = false;
        if (c.y < 2.5) { let ax = st.x, az = st.z; for (const q of ahead) { const lx = q.x - ax, lz = q.z - az, l2 = lx * lx + lz * lz || 1; const t2 = clamp(((c.x - ax) * lx + (c.z - az) * lz) / l2, 0, 1); if (Math.hypot(ax + lx * t2 - c.x, az + lz * t2 - c.z) < 0.75 && Math.hypot(c.x - st.x, c.z - st.z) < 2.2) blocked = true; ax = q.x; az = q.z; } }
        if (blocked) { st.wait += dt; st.v = Math.max(0, st.v - dt * 4); if (st.wait > 2.2) { st.wait = 0; if (!leave(true)) begin('glance', 2); } }
        else { st.wait = 0; st.v = Math.min(st.vmax, st.v + dt * 2.2); }
        const dx = p.x - st.x, dz = p.z - st.z, d = Math.hypot(dx, dz), want = Math.atan2(dx, dz);
        st.yaw = toward(st.yaw, want, dt * 5);
        const mv = Math.min(d, st.v * dt * (Math.abs(wrap(want - st.yaw)) > 1.2 ? 0.25 : 1));
        if (d > 1e-4) { st.x += dx / d * mv; st.z += dz / d * mv; }
        st.phase += mv / 0.68 * Math.PI;
        if (d - mv < 0.02) st.path.shift();
        if (st.lookT < 0) { st.look = rnd() < 0.35 ? (rnd() - 0.5) * 1.6 : 0; st.lookT = 1.2 + rnd() * 3; }
      } else {
        st.t += dt;
        st.v = Math.max(0, st.v - dt * 3);
        if (st.yaw0 != null) st.yaw = toward(st.yaw, st.yaw0, dt * 4);
        if (st.act === 'photo') { const f = st.t - 1.2; st.flashT = (f > 0 && f < 0.09) || (f > 0.9 && f < 0.99) ? 1 : -1; }
        if (st.act === 'usb' && st.t > 0.9 && st.usb && !stick.parent) { st.usb.group.add(stick); usbG.visible = false; }
        if (st.act === 'usb' && st.t > st.dur - 0.8 && stick.parent) { stick.parent.remove(stick); usbG.visible = true; }
        if (st.t >= st.dur) { stopProps(); st.yaw0 = null; if (!choose()) begin('glance', 2); }
      }
    }
    // the pose: targets from what she does and her stride, eased into
    const J = {}, Jt = {};
    const names = ['py', 'pyaw', 'sx', 'sy', 'hx', 'hy', 'hipL', 'hipR', 'kneeL', 'kneeR', 'ankL', 'ankR', 'shLx', 'shRx', 'shLz', 'shRz', 'elL', 'elR'];
    for (const n of names) J[n] = Jt[n] = 0;
    function pose(dt, snap) {
      const a = clamp(st.v / 1.2, 0, 1.35), s = Math.sin(st.phase), co = Math.cos(st.phase), tm = T.value + st.t;
      for (const n of names) Jt[n] = 0;
      Jt.hipL = -0.44 * a * s; Jt.hipR = 0.44 * a * s;
      Jt.kneeL = 0.06 + 0.72 * a * Math.max(0, co); Jt.kneeR = 0.06 + 0.72 * a * Math.max(0, -co);
      Jt.ankL = -0.35 * (Jt.hipL + Jt.kneeL) - 0.12 * a * Math.max(0, -co); Jt.ankR = -0.35 * (Jt.hipR + Jt.kneeR) - 0.12 * a * Math.max(0, co);
      Jt.py = 0.014 * a * Math.cos(2 * st.phase) - 0.01 * a; Jt.pyaw = 0.08 * a * s; Jt.sy = -0.06 * a * s; Jt.sx = 0.05 * a;
      Jt.shLx = 0.34 * a * s; Jt.shRx = -0.34 * a * s; Jt.shLz = 0.09; Jt.shRz = -0.09; Jt.elL = -0.22 - 0.12 * a; Jt.elR = -0.22 - 0.12 * a;
      Jt.hy = st.act === 'walk' ? st.look : 0;
      const act = st.act;
      if (act === 'photo') { Object.assign(Jt, { shRx: -1.42, shRz: 0.42, elR: -1.75, shLx: -1.25, shLz: -0.5, elL: -1.9, hx: 0.05 }); }
      else if (act === 'usb') {
        const up = clamp(st.t / 0.7, 0, 1) * (st.t > st.dur - 0.6 ? clamp((st.dur - st.t) / 0.6, 0, 1) : 1), ik = st.ik || [-2.5, -0.1, 0.5], toe = clamp(ik[2] * 0.9, 0, 0.35);
        Jt.shRx = ik[0] * up; Jt.elR = ik[1] * up - 0.2 * (1 - up); Jt.shRz = 0.06 * up; Jt.hx = -0.5 * clamp(ik[2] * 2, 0, 1) * up; Jt.sx = -0.04 * up;
        Jt.shLx = 0.1; Jt.elL = -0.25;
        st.toe = toe * up;
      }
      else if (act === 'peek') { Object.assign(Jt, { sx: 0.1, hx: 0.08, shLz: 0.1, shRz: -0.1, elL: -0.5, elR: -0.5 }); Jt.hy = 0.12 * Math.sin(tm * 0.9); }
      else if (act === 'phone' || act === 'idle' || act === 'desk') { Object.assign(Jt, { shLx: -0.5, shLz: -0.18, elL: -1.55, hx: 0.42, hy: 0.06 }); phoneG.visible = true; }
      else if (act === 'read') { Object.assign(Jt, { hx: 0.12, shLz: 0.12, shRz: -0.12, elL: -0.35, elR: -0.35 }); Jt.hy = 0.08 * Math.sin(tm * 0.7); }
      else if (act === 'glance') { Jt.hy = 0.85 * Math.sin(tm * 1.6); Jt.sy = 0.25 * Math.sin(tm * 1.6); }
      if (act !== 'walk') { Jt.py += 0.004 * Math.sin(tm * 1.9); Jt.kneeL = 0.06; Jt.kneeR = 0.14; Jt.hipR = 0.06; Jt.ankR = -0.05; }   // her weight on one foot
      if (act === 'usb') { const k = st.toe || 0; Jt.py += 0.1 * k; Jt.ankL = Jt.ankR = 0.9 * k; Jt.kneeL = Jt.kneeR = 0.02; Jt.hipR = 0; }   // on her toes
      const k = snap ? 1 : 1 - Math.exp(-dt * 9);
      for (const n of names) J[n] += (Jt[n] - J[n]) * k;
      pelvis.position.y = 0.95 + J.py; pelvis.rotation.y = J.pyaw;
      spine.rotation.set(J.sx, J.sy, 0); neck.rotation.set(0, J.hy * 0.3, 0); head.rotation.set(J.hx, J.hy * 0.7, 0);
      leg[0].hip.rotation.x = J.hipL; leg[1].hip.rotation.x = J.hipR; leg[0].knee.rotation.x = J.kneeL; leg[1].knee.rotation.x = J.kneeR;
      leg[0].ankle.rotation.x = J.ankL; leg[1].ankle.rotation.x = J.ankR;
      arm[0].sh.rotation.set(J.shLx, 0, J.shLz); arm[1].sh.rotation.set(J.shRx, 0, J.shRz); arm[0].el.rotation.x = J.elL; arm[1].el.rotation.x = J.elR;
      root.position.set(st.x, 0, st.z); root.rotation.y = st.yaw;
      if (act !== 'phone' && act !== 'idle' && act !== 'desk') phoneG.visible = false;
      flash.visible = st.flashT > 0;
      if (flash.visible) camG.localToWorld(flash.position.set(0, 0, -0.07));
      if (st.usb) stickLed.visible = Math.sin(T.value * 18) > 0;
    }
    function idle() {
      stopProps(); st.path = []; st.goal = null; st.then = null;
      st.x = home.x; st.z = home.z; st.yaw = st.yaw0 = 0; st.v = 0; st.act = 'idle'; st.idle = true; st.t = 0;
      pose(0, true);
    }
    idle();
    return {
      proxy,
      set shot(v) { st.shot = v; },
      tick(dt, moving) {
        if (!moving) { if (!st.idle) idle(); return; }
        if (st.idle) {
          st.idle = false; st.act = 'phone'; st.t = 0; st.dur = 0.8;
          // the room opened with things moving: she is already at work, somewhere in the hall behind the racks
          if (st.fresh) {
            const far = goals.filter(g => g.kind === 'photo' && g.nd.z < -1.2), list = far.length ? far : goals.filter(g => g.kind === 'photo' && Math.hypot(g.nd.x - camera.position.x, g.nd.z - camera.position.z) > 8);
            const g = list.length ? list[Math.floor(rnd() * list.length)] : null;
            if (g) { st.x = g.nd.x; st.z = g.nd.z; st.yaw = st.yaw0 = g.yaw; st.dur = 0.8 + rnd() * 1.2; }
          }
        }
        st.fresh = false;
        const all = Math.min(dt, 0.5) * st.ts;
        for (let left = all; left > 1e-6; left -= 1 / 30) step(Math.min(left, 1 / 30));
        if (all > 0) pose(all);
      },
      simulate(sec, every) {
        const out = [];
        let acc = 0;
        for (let t = 0; t < sec; t += 1 / 30) { step(1 / 30); acc += 1 / 30; if (acc >= every) { acc = 0; out.push([+st.x.toFixed(3), +st.z.toFixed(3)]); } }
        pose(0, true);
        return out;
      },
      state() { return { name: SPY, x: +st.x.toFixed(3), z: +st.z.toFixed(3), yaw: +st.yaw.toFixed(3), act: st.act, goal: st.goal ? st.goal.kind : null, t: +st.t.toFixed(2), flash: flash.visible, idle: st.idle, moving: st.v > 0.05, speed: +st.v.toFixed(2) }; },
      head: () => root.localToWorld(new THREE.Vector3(0, 1.84, 0)),
      setTs(v) { st.ts = Math.max(0, Math.min(20, v)); },
      focus() { const p = new THREE.Vector3(st.x, 1.2, st.z), f = new THREE.Vector3(Math.sin(st.yaw), 0, Math.cos(st.yaw)); return { target: p, pos: p.clone().addScaledVector(f, 2.4).add(V(0.6, 0.35, 0)) }; },
    };
  })();
  // what she says, when clicked: in a bubble over her head, and to the screen reader
  const bubble = document.createElement('div');
  bubble.className = 'a3d-bubble a3d-glass'; bubble.setAttribute('aria-hidden', 'true');
  root.appendChild(bubble);
  let bubbleT = 0, lastLine = -1;
  spyRef = spy;
  function spySay() {
    let i = Math.floor(Math.random() * SPY_LINES.length);
    if (i === lastLine) i = (i + 1) % SPY_LINES.length;
    lastLine = i;
    bubble.innerHTML = '<b>' + SPY + '</b>' + esc(SPY_LINES[i]);
    bubble.classList.add('on'); placeBubble();
    live.textContent = SPY + ' says: ' + SPY_LINES[i];
    clearTimeout(bubbleT); bubbleT = setTimeout(() => bubble.classList.remove('on'), 5200);
    invalidate();
    return SPY_LINES[i];
  }
  const _hb = new THREE.Vector3();
  function placeBubble() {
    if (!bubble.classList.contains('on')) return;
    _hb.copy(spy.head()).project(camera);
    if (_hb.z > 1 || Math.abs(_hb.x) > 1.1 || Math.abs(_hb.y) > 1.1) { bubble.style.visibility = 'hidden'; return; }
    bubble.style.visibility = '';
    const r = cv.getBoundingClientRect(), rr = root.getBoundingClientRect();
    const x = r.left - rr.left + (_hb.x + 1) / 2 * r.width, y = r.top - rr.top + (1 - _hb.y) / 2 * r.height;
    const top = topBar.getBoundingClientRect().bottom - rr.top + 8;   // never over the bar at the top
    bubble.style.transform = 'translate3d(' + Math.round(clamp(x - bubble.offsetWidth / 2, 8, rr.width - bubble.offsetWidth - 8)) + 'px,' + Math.round(Math.max(top, y - bubble.offsetHeight - 12)) + 'px,0)';
  }
  let spyT = 0;

  /* motion: fans, blinking lights, marquees, the beams - only while the room is open and seen */
  let motion = !reduced && prefs.motion !== false;
  function setMotion(on) {
    motion = !!on;
    motionBtn.setAttribute('aria-pressed', String(motion));
    motionBtn.title = motion ? 'Motion is on: fans, lights and marquees move. Click to hold them still.' : 'Motion is off. Click to set the fans, lights and marquees moving.';
    prefs.motion = motion; savePrefs();
    if (!motion) { clearTimeout(tourTimer); }
    invalidate();
  }
  motionBtn.setAttribute('aria-pressed', String(motion));
  const _cw = new THREE.Vector3();
  function tick(now) {
    sky.position.x = camera.position.x; sky.position.z = camera.position.z;   // the sky keeps its distance
    spy.tick(Math.max(0, T.value - spyT), motion); spyT = T.value;
    for (const p of podium) {
      p.mini.rotation.y = motion ? -Math.PI / 2 + Math.sin(T.value * 0.45 + p.phase) * 0.9 : -Math.PI / 2;
      p.mini.position.y = p.base + (motion ? Math.sin(T.value * 1.3 + p.phase) * 0.008 : 0);
    }
    for (const m of mqs) m.mesh.material.uniforms.uShift.value = motion ? Math.floor(T.value * m.speed) % (m.w + MQ_COLS) : MQ_COLS;
    for (const kt of kits) {
      const u = kt.u;
      if (!kt.g.visible || !u) continue;
      const f = 1.5 + 16 * (u.rpsN || 0), on = u.rps ? (motion ? (Math.sin(T.value * f * 6.283 + u.gi) + Math.sin(T.value * f * 4.1) > 0 ? 1 : 0.15) : 1) : 0.1;
      kt.nicLed[0].material.color.copy(cA).multiplyScalar(on * (dark ? 1.4 : 1));
      if (kt.full && kt.holo.visible) { kt.holo.getWorldPosition(_cw); kt.holo.rotation.y = Math.atan2(camera.position.x - _cw.x, camera.position.z - _cw.z) - u.yaw; }
    }
    scrLed.visible = !!mon;
    return nocTick(now);
  }

  /* the loop: on demand while still; with motion on, the room's own motion at ~30 fps */
  // a slow machine finds out in the first seconds of motion: first no far rows and no occlusion, then no bloom, then fewer pixels
  const probe = { n: 0, slow: 0, done: reduced, steps: 0 };
  function lighten() {
    if (hallFar.visible) { hallFar.visible = false; if (post) post.setAO(false); }
    else if (post && post.ao) post.setAO(false);
    else if (post && post.bloom) post.setBloom(false);
    else {
      renderer.setPixelRatio(Math.max(1, renderer.getPixelRatio() * 0.7));
      renderer.setSize(vw(), vh(), false);
      if (post) post.setSize();
    }
    probe.steps++;
  }
  function invalidate() { dirty = true; if (!raf && !disposed) raf = requestAnimationFrame(frame); }
  function frame(now) {
    raf = 0;
    if (disposed) return;
    const dt = lastT ? Math.min(0.05, (now - lastT) / 1000) : 1 / 60;
    if (!probe.done && lastT && ++probe.n > 10) {
      if (now - lastT > 26) probe.slow++;
      if (probe.n >= 70) {
        if (probe.slow > 36) lighten();
        // after a step down, look again; past three steps there is nothing left to give
        if (probe.slow > 36 && probe.steps < 3) { probe.n = 0; probe.slow = 0; } else probe.done = true;
      }
    }
    lastT = now;
    const ambient = motion && !document.hidden;
    if (ambient) T.value += dt;
    let more = runTweens(now);
    if (!keys.size) walkHeld = 0;
    if (keys.size) { if (walk(dt, shiftKey)) { stopCam(); aligned = -1; atOverview = false; spy.shot = null; } more = true; }
    if (controls.update()) more = true;
    clampView();
    const must = dirty || more;
    dirty = false;
    if (!must && ambient && now - lastDraw < 31) { raf = requestAnimationFrame(frame); return; }
    camera.updateMatrixWorld();
    updateHud();
    if (lodTick()) more = true;
    if (tick(now)) more = true;
    if (post) post.render(scene, camera); else renderer.render(scene, camera);
    placeMon(); placeBubble();
    renders++; lastDraw = now;
    if (more || ambient) { if (!raf) raf = requestAnimationFrame(frame); } else lastT = 0;
  }
  controls.addEventListener('change', invalidate);
  controls.addEventListener('start', () => { stopCam(); aligned = -1; atOverview = false; hideTips(); endTour(); spy.shot = null; });
  const onVis = () => { if (!document.hidden) invalidate(); };
  document.addEventListener('visibilitychange', onVis);

  /* input */
  let down = null, pendingMove = null, moveRaf = 0;
  function onDown(e) {
    down = { x: e.clientX, y: e.clientY, t: performance.now(), b: e.button, moved: false, shift: e.shiftKey };
    hideTips();
    if (findRes.classList.contains('on')) { findRes.classList.remove('on'); findIn.blur(); }
    invalidate();
  }
  function onMove(e) {
    if (down) {
      if (!down.moved && Math.hypot(e.clientX - down.x, e.clientY - down.y) > 5) { down.moved = true; cv.classList.add('drag'); setHover(null); }
      return;
    }
    if (e.pointerType === 'touch') return;
    pendingMove = { x: e.clientX, y: e.clientY };
    if (!moveRaf) moveRaf = requestAnimationFrame(() => {
      moveRaf = 0;
      if (disposed || !pendingMove || down) return;
      const hit = pick(pendingMove.x, pendingMove.y);
      setHover(hit && hit.u ? hit.u : null);
      cv.classList.toggle('hot', !!(hit && (hit.u || hit.act || hit.cart || hit.bench || hit.npc)));
      showTips(hit && (hit.u || hit.text) ? hit : null, pendingMove.x, pendingMove.y);
    });
  }
  function onUp(e) {
    const d = down;
    down = null;
    cv.classList.remove('drag');
    if (!d || d.moved || d.b !== 0 || performance.now() - d.t > 700) return;
    const hit = pick(e.clientX, e.clientY);
    if (!hit) return;
    if (hit.npc) { hideTips(); spySay(); return; }   // she never pulls a unit out
    if (hit.act) {
      endTour();
      if (hit.act.kind === 'lang' || hit.act.kind === 'bin') setFilter(hit.act);
      else if (hit.act.kind === 'test') setChart({ kind: 'test', i: hit.act.i });
      else if (hit.act.kind === 'sec') goSection(secById.get(hit.act.id));
      else if (hit.act.kind === 'wallsec') setSection(secById.get(hit.act.id));
      else if (hit.act.kind === 'bench') openCompare();
      hideTips();
      return;
    }
    if (hit.cart) { if (mon && mon.state === 'on') { placeMon(true); monCode.focus({ preventScroll: true }); } return; }
    if (!hit.u) return;
    const u = hit.u;
    if (hit.region.kind === 'loc') { toggleFav(u); showTips(hit, e.clientX, e.clientY); return; }
    endTour();
    if (d.shift || e.shiftKey) { toggleCompare(u); hideTips(); return; }
    if (hit.region.kind === 'port' && o.sourceUrl) { if (!u.cmp && popped !== u) pop(u); plugIn(u); return; }
    if (popped === u) unpop(); else pop(u);
  }
  function onLeave() { if (!down) { setHover(null); hideTips(); } }
  function onWheel() { hideTips(); }
  function onKey(e) {
    if (disposed) return;
    shiftKey = e.shiftKey;   // Shift pressed mid-walk breaks into a sprint at once
    const tg = e.target;
    if (mon && tg !== findIn && !(e.ctrlKey || e.metaKey || e.altKey) && !(tg instanceof Node && panel.contains(tg))) {
      if (monKey(e)) { e.preventDefault(); e.stopImmediatePropagation(); return; }
    }
    if (e.key === 'Tab' && root.contains(document.activeElement)) {
      // keep Tab in the room: from the last control round to the first, and back
      const f = Array.from(root.querySelectorAll('button,a[href],input,select,textarea,[tabindex]:not([tabindex="-1"])'))
        .filter(el => !el.disabled && el.offsetParent !== null && getComputedStyle(el).visibility !== 'hidden');
      if (f.length) {
        const i = f.indexOf(document.activeElement);
        if (e.shiftKey && i <= 0) { e.preventDefault(); f[f.length - 1].focus(); }
        else if (!e.shiftKey && i === f.length - 1) { e.preventDefault(); f[0].focus(); }
      }
      return;
    }
    if (tg === findIn) {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); e.stopImmediatePropagation(); moveFind(e.key === 'ArrowDown' ? 1 : -1); return; }
      if (e.key === 'Enter') { e.preventDefault(); e.stopImmediatePropagation(); if (findList[findSel]) chooseFind(findList[findSel].sec.id + '|' + findList[findSel].fw); return; }
      if (e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); if (findIn.value) { findIn.value = ''; renderFind(); } else findIn.blur(); return; }
      return;
    }
    if (e.key === 'Escape') {
      e.preventDefault(); e.stopImmediatePropagation();
      if (tour) { endTour(); return; }
      if (popped) unpop();
      else if (cardMode === 'bench') openCompare();
      else if (cmp.length) putAllBack();
      else if (cardMode) { setCard('', null); shiftTo({ x: 0, y: 0 }); }
      else if (!keysEl.hidden) toggleKeys(false); else closeSelf();
      return;
    }
    if (tg && (tg.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(tg.tagName || ''))) return;
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === ']' || e.key === 'PageDown') { e.preventDefault(); e.stopImmediatePropagation(); endTour(); goRack(navIdx(1)); return; }
    if (e.key === '[' || e.key === 'PageUp') { e.preventDefault(); e.stopImmediatePropagation(); endTour(); goRack(navIdx(-1)); return; }
    if (e.key === 'Home') { e.preventDefault(); e.stopImmediatePropagation(); endTour(); resetView(); return; }
    if (e.key === '/') { e.preventDefault(); e.stopImmediatePropagation(); findIn.focus(); return; }
    if (corridor && /^[0-9]$/.test(e.key) && !(tg instanceof Node && panel.contains(tg))) {
      e.preventDefault(); e.stopImmediatePropagation(); endTour();
      if (e.key === '0') resetView(); else if (SECS[+e.key - 1]) goSection(SECS[+e.key - 1]);
      return;
    }
    if (MOVE[e.code]) {
      if (tg instanceof Node && (panel.contains(tg) || monEl.contains(tg))) return;   // let the card scroll
      e.preventDefault(); e.stopImmediatePropagation();
      shiftKey = e.shiftKey;
      if (!keys.has(e.code)) { keys.add(e.code); hideTips(); endTour(); }
      invalidate();
    }
  }
  function onKeyUp(e) { if (keys.delete(e.code)) e.stopImmediatePropagation(); shiftKey = e.shiftKey; }
  function onBlur() { keys.clear(); }
  function toggleKeys(on) {
    keysEl.hidden = !on; keysBtn.setAttribute('aria-expanded', String(on));
    if (!on) { prefs.keysSeen = true; savePrefs(); }
  }
  function onClick(e) {
    const a = e.target.closest('[data-act],[data-rack],[data-close],[data-pull],[data-sec]');
    if (!a || !root.contains(a) || monEl.contains(a) && !a.hasAttribute('data-act')) return;
    if (a.hasAttribute('data-close')) {
      e.preventDefault();
      if (cardMode === 'unit') unpop(); else if (cardMode === 'bench') openCompare(); else { setCard('', null); shiftTo({ x: 0, y: 0 }); updateTray(); }
      return;
    }
    if (a.hasAttribute('data-rack')) { endTour(); goRack(+a.getAttribute('data-rack')); return; }
    if (a.hasAttribute('data-sec')) { endTour(); goSection(secById.get(a.getAttribute('data-sec'))); return; }
    if (a.hasAttribute('data-pull') && a.tagName === 'BUTTON') { endTour(); setChart({ kind: a.dataset.pull }); return; }
    const act = a.getAttribute('data-act');
    if (act === 'prev') { endTour(); goRack(navIdx(-1)); }
    else if (act === 'next') { endTour(); goRack(navIdx(1)); }
    else if (act === 'reset' || act === 'entrance') { endTour(); resetView(); }
    else if (act === 'wall') { endTour(); goWall(); }
    else if (act === 'bench') { endTour(); openCompare(); }
    else if (act === 'putback') putAllBack();
    else if (act === 'cmp') { const u = cardU(); if (u) { toggleCompare(u); if (!u.cmp && cardMode === 'bench') openCompare(); } }
    else if (act === 'mon') { const u = cardU(); if (u) { if (mon && mon.u === u) unplug(); else plugIn(u); } }
    else if (act === 'unplug') unplug();
    else if (act === 'close') closeSelf();
    else if (act === 'motion') setMotion(!motion);
    else if (act === 'tour') { if (tour) endTour(); else startTour(); }
    else if (act === 'tour-next') nextStop();
    else if (act === 'tour-stop') endTour();
    else if (act === 'unlit') setFilter(null);
    else if (act === 'keys') toggleKeys(keysEl.hidden);
    else if (act === 'keys-hide') toggleKeys(false);
  }
  locBtn.addEventListener('click', () => { const u = cardU(); if (u) toggleFav(u); });
  segEl.addEventListener('change', e => {
    const t = e.target;
    endTour();
    if (t.matches('[data-pull-test]')) { if (t.value === '') { if (chart && chart.kind === 'test') setChart(null); } else setChart({ kind: 'test', i: +t.value }); t.blur(); }
    else if (t.matches('[data-pull-all]')) { const v = t.value; setChart(v === 'off' ? null : v[0] === 't' && !isNaN(+v.slice(1)) ? { kind: 'test', i: +v.slice(1) } : { kind: v }); t.blur(); }
  });
  findIn.addEventListener('input', renderFind);
  findIn.addEventListener('focus', () => { if (findIn.value) renderFind(); });
  findRes.addEventListener('pointerdown', e => e.preventDefault());
  findRes.addEventListener('click', e => { const li = e.target.closest('li[data-key]'); if (li) chooseFind(li.dataset.key); });
  cv.addEventListener('pointerdown', onDown);
  cv.addEventListener('pointermove', onMove);
  cv.addEventListener('pointerup', onUp);
  cv.addEventListener('pointercancel', () => { down = null; cv.classList.remove('drag'); });
  cv.addEventListener('pointerleave', onLeave);
  cv.addEventListener('wheel', onWheel, { passive: true });
  root.addEventListener('click', onClick);
  // the page behind does not scroll under the room; the card, the matches and the console scroll on their own
  root.addEventListener('wheel', e => { if (!pbody.contains(e.target) && !findRes.contains(e.target) && !monEl.contains(e.target)) e.preventDefault(); }, { passive: false });
  window.addEventListener('keydown', onKey, true);
  window.addEventListener('keyup', onKeyUp, true);
  window.addEventListener('blur', onBlur);
  const ro = new ResizeObserver(() => {
    if (disposed) return;
    renderer.setSize(vw(), vh(), false);
    if (post) post.setSize();
    if (cardMode) { const S = reserve(); if (!shiftTw) { shift.x = S.x; shift.y = S.y; } }
    applyView();
    lodDirty = true;
    invalidate();
  });
  ro.observe(host);
  cv.addEventListener('webglcontextlost', e => {
    if (disposed) return;
    e.preventDefault();
    msgEl.className = 'a3d-msg';
    msgEl.style.display = '';
    msgEl.textContent = 'The 3D view lost its graphics context. Close it and open it again.';
  });

  /* close */
  function dispose() {
    if (disposed) return;
    disposed = true;
    cancelAnimationFrame(raf); cancelAnimationFrame(moveRaf); raf = moveRaf = 0;
    clearTimeout(tourTimer); clearTimeout(bootTimer); clearTimeout(toastTimer); if (spyRef) clearTimeout(bubbleT);
    tweens.clear();
    window.removeEventListener('keydown', onKey, true);
    window.removeEventListener('keyup', onKeyUp, true);
    window.removeEventListener('blur', onBlur);
    document.removeEventListener('visibilitychange', onVis);
    ro.disconnect();
    controls.dispose();
    for (const kt of kits) if (!kt.g.parent) scene.add(kt.g);
    for (const e of nearPool) if (!e.u) scene.add(e.face, e.lcd);
    scene.traverse(ob => {
      if (ob.geometry) bin.add(ob.geometry);
      const ms = Array.isArray(ob.material) ? ob.material : ob.material ? [ob.material] : [];
      for (const m of ms) {
        bin.add(m);
        for (const k of Object.keys(m)) { const v = m[k]; if (v && v.isTexture) bin.add(v); }
        if (m.uniforms) for (const k in m.uniforms) { const v = m.uniforms[k] && m.uniforms[k].value; if (v && v.isTexture) bin.add(v); }
      }
    });
    for (const u of all) { if (u.hi) { bin.add(u.hi.tf); bin.add(u.hi.tl); } if (u.fx) for (const m of u.fx) bin.add(m.material); }
    const texList = Array.from(bin).filter(x => x.isTexture);
    for (const x of bin) { try { x.dispose(); } catch (e) { /* already gone */ } }
    bin.clear();
    if (envRT) envRT.dispose();
    if (post) { post.dispose(); post = null; }
    scene.environment = null;
    renderer.renderLists.dispose();
    renderer.dispose();
    try { renderer.forceContextLoss(); } catch (e) { /* fine */ }
    for (const c of canvases) { c.width = c.height = 0; }
    canvases.length = 0;
    for (const x of texList) { const c = x.image; if (c && c.getContext) { c.width = c.height = 0; } }
    for (const id in noc) noc[id].cv.width = noc[id].cv.height = 0;
    scrCv.width = scrCv.height = 0;
    root.remove();
    host.classList.remove(...addedCls);
    if (!hadRole) { host.removeAttribute('role'); host.removeAttribute('aria-modal'); host.removeAttribute('aria-label'); }
  }
  function closeSelf() {
    if (disposed) return;
    dispose();
    try { if (o.onClose) o.onClose(); } catch (e) { console.error(e); }
  }

  /* first light: shaders built for what will appear later too, so its first showing does not stall */
  for (const id in noc) paintNoc(id);
  applyView();
  const ov = overview();
  if (reduced) { camera.position.copy(ov.pos); controls.target.copy(ov.target); }
  else {
    camera.position.copy(ov.pos).add(corridor ? V(-0.35, 0.3, 0.25) : V(-0.55, 0.45, 0.6));
    controls.target.copy(ov.target).add(V(-0.25, 0.1, 0));
  }
  clampView();
  controls.update();
  {
    const warm = makeNear(), wg = new THREE.Group();
    wg.position.set(midX, -5, ZC);
    wg.add(warm.face, warm.lcd, kit0.g);
    kit0.g.visible = true; cartG.visible = true; benchHolo.visible = true; cbG.visible = true;
    const cg = cartG.position.y; cartG.position.y = -5;
    scene.add(wg);
    if (post) post.warm(scene, camera); else renderer.compile(scene, camera);
    scene.remove(wg); wg.remove(kit0.g); kit0.g.visible = false; cartG.visible = false; cartG.position.y = cg; benchHolo.visible = false; cbG.visible = false;
    nearPool.push(warm);
  }
  invalidate();
  msgEl.classList.add('off');
  setTimeout(() => { if (!disposed && !msgEl.classList.contains('err')) msgEl.style.display = 'none'; }, 350);
  if (!reduced) flyTo(ov, 1500);
  try { cv.focus({ preventScroll: true }); } catch (e) { /* fine */ }
  if (corridor) secEls.forEach(c => { const on = c.dataset.sec === cur.id; c.classList.toggle('on', on); c.setAttribute('aria-current', on ? 'true' : 'false'); });

  const handle = {
    close() { dispose(); },
    setFav(fw, on) { if (disposed) return; for (const u of all) if (u.fw === String(fw)) applyFav(u, on); },
    focus(fw) { const u = unitOf(String(fw)); if (u && !disposed) { endTour(); pop(u); } },
  };
  // for tests: where things are on screen, a camera to look through, and the room's state
  const texBytes = () => {
    let b = 0, n = 0;
    const seen = new Set();
    const addT = t => { if (!t || seen.has(t)) return; seen.add(t); n++; const px = t.userData && t.userData.px ? t.userData.px : (t.image && t.image.width ? t.image.width * t.image.height : 0); b += px * 4 * (t.generateMipmaps === false ? 1 : 4 / 3); };
    for (const x of bin) if (x.isTexture) addT(x);
    const rt = post ? post.bytes() : 0;
    const v = renderer.getDrawingBufferSize(new THREE.Vector2()), ca = renderer.getContext().getContextAttributes();
    const fb = v.x * v.y * (4 + (ca.depth ? 4 : 0)) * (ca.antialias ? 4 : 1);
    let geo = 0;
    const gs = new Set();
    scene.traverse(ob => { if (ob.geometry && !gs.has(ob.geometry)) { gs.add(ob.geometry); for (const k in ob.geometry.attributes) geo += ob.geometry.attributes[k].array.byteLength; if (ob.geometry.index) geo += ob.geometry.index.array.byteLength; } if (ob.isInstancedMesh) { geo += ob.instanceMatrix.array.byteLength; if (ob.instanceColor) geo += ob.instanceColor.array.byteLength; } });
    const top = [...seen].map(t => [t.userData && t.userData.size || (t.image ? t.image.width + 'x' + t.image.height : '?'), t.userData && t.userData.px ? t.userData.px : 0]).sort((a, b) => b[1] - a[1]);
    const bySize = {}; for (const [s] of top) bySize[s] = (bySize[s] || 0) + 1;
    return { bySize, textures: n, textureMB: +(b / 1048576).toFixed(1), targetsMB: +(rt / 1048576).toFixed(1), framebufferMB: +(fb / 1048576).toFixed(1), geometryMB: +(geo / 1048576).toFixed(1), atlas: atlasW + 'x' + atlasH, nearPool: nearPool.length, nearInUse: nearPool.filter(e => e.u).length, units: all.length, lodPaints };
  };
  Object.defineProperty(handle, '_debug', {
    enumerable: false,
    value: {
      screenOf(fw, part, sid) {
        const u = unitOf(String(fw), sid); if (!u) return null;
        const r = cv.getBoundingClientRect(), S = u.sec, L = S.LY;
        const lx = part === 'loc' ? pxX(L.locX) : part === 'fan' ? S.fanX : part === 'mem' ? pxX(1005) : part === 'act' ? pxX(L.actX) : part === 'port' ? PORT_X : typeof part === 'number' ? S.eqX[part] : 0;
        const ly = part === 'loc' ? pxY(L.locY) : part === 'act' ? pxY(L.stY) : part === 'port' ? PORT_Y : typeof part === 'number' ? S.eqCy : 0;
        const v = V(lx, ly, 0.0002);
        u.group.updateWorldMatrix(true, false);
        u.group.localToWorld(v); v.project(camera);
        return { x: r.left + (v.x + 1) / 2 * r.width, y: r.top + (1 - v.y) / 2 * r.height };
      },
      screenOfWall(id, cx, cy) {
        const n = noc[id]; if (!n) return null;
        const r = cv.getBoundingClientRect();
        const v = V((cx / 1280 - 0.5) * 1.3, (0.5 - cy / 720) * 1.3 * 9 / 16, 0);
        n.mesh.localToWorld(v); v.project(camera);
        return { x: r.left + (v.x + 1) / 2 * r.width, y: r.top + (1 - v.y) / 2 * r.height };
      },
      view(p, t) { stopCam(); atOverview = false; camera.position.set(p[0], p[1], p[2]); controls.target.set(t[0], t[1], t[2]); controls.update(); invalidate(); },
      cam() { return { p: camera.position.toArray().map(v => +v.toFixed(3)), t: controls.target.toArray().map(v => +v.toFixed(3)) }; },
      chart(kind, i) { setChart(kind ? { kind, i } : null); },
      filter(name) { setFilter(name ? { kind: 'lang', name } : null); },
      wall() { goWall(); },
      tour() { startTour(); },
      motion(on) { setMotion(on); },
      section(id) { goSection(secById.get(String(id))); },
      rack(k) { goRack(k); },
      pop(fw, sid) { const u = unitOf(String(fw), sid); if (u) pop(u); return !!u; },
      sections() { return SECS.map(S => ({ id: S.id, label: S.label, n: S.units.length, racks: S.nR, x0: +S.x0.toFixed(2), x1: +S.x1.toFixed(2) })); },
      plug(fw, sid) { const u = unitOf(String(fw), sid); if (!u) return false; if (!u.cmp && popped !== u) pop(u); plugIn(u); return true; },
      unplug() { unplug(); },
      monitor() { return mon ? { fw: mon.u.fw, state: mon.state, file: mon.bundle && mon.bundle.files[mon.fi] ? mon.bundle.files[mon.fi].path : null, files: mon.bundle ? mon.bundle.files.length : 0, shown: monShown } : null; },
      file(i) { setFile(i); },
      compare(fw, sid) { const u = unitOf(String(fw), sid); if (u) addCompare(u); return !!u; },
      bench() { openCompare(); },
      putBack() { putAllBack(); },
      compared() { return cmp.map(e => ({ letter: e.letter, fw: e.u.fw, sec: e.u.sec.id, state: e.state })); },
      mem() { return texBytes(); },
      // the visitor's state; o: timeScale, simulate (seconds, sampled every o.sample), say, focus
      npc(o) {
        if (o && o.timeScale != null) spy.setTs(+o.timeScale);
        if (o && o.simulate) return spy.simulate(+o.simulate, +o.sample || 0.2);
        if (o && o.say) spySay();
        if (o && o.focus) flyTo(spy.focus(), 500);
        const r = cv.getBoundingClientRect(), sp = (v) => { v.project(camera); return { x: Math.round(r.left + (v.x + 1) / 2 * r.width), y: Math.round(r.top + (1 - v.y) / 2 * r.height), on: v.z < 1 && Math.abs(v.x) < 1 && Math.abs(v.y) < 1 }; };
        const s0 = spy.state();
        return Object.assign(s0, { motion, bubble: bubble.classList.contains('on') ? bubble.textContent : null, head: sp(spy.head()), body: sp(V(s0.x, 1.1, s0.z)) });
      },
      npcObstacles() { return { r: SPY_R, boxes: OBS.map(b => b.map(v => +v.toFixed(3))), hall: [HX0, HZ0, HX1, HZ1], foyer: corridor ? [endL, FZ0, HX0, FZ1] : null }; },
      what(x, y) {
        const r = cv.getBoundingClientRect(); ndc.set(((x - r.left) / r.width) * 2 - 1, -((y - r.top) / r.height) * 2 + 1); ray.setFromCamera(ndc, camera);
        const hits = ray.intersectObjects(scene.children, true).slice(0, 4);
        return hits.map(h => { const m = h.object.material, mm = Array.isArray(m) ? m[0] : m; return { type: h.object.type, mat: mm && mm.type, color: mm && mm.color && mm.color.getHexString(), map: !!(mm && mm.map), em: mm && mm.emissive && mm.emissive.getHexString(), d: +h.distance.toFixed(2), p: h.point.toArray().map(v => +v.toFixed(2)), geo: h.object.geometry && h.object.geometry.type, ud: Object.keys(h.object.userData || {}).join(',') }; });
      },
      fx(set) {
        if (set && post) {
          if ('ao' in set) post.setAO(set.ao);
          if ('bloom' in set) post.setBloom(set.bloom);
        }
        if (set && set.lighten) lighten();
        if (set) invalidate();
        return { post: !!post, ao: !!(post && post.ao), bloom: !!(post && post.bloom), samples: post ? post.samples : 0, pixelRatio: renderer.getPixelRatio(), lightened: probe.steps }; },
      stats() { return { renders, popped: popped && popped.fw, hovered: hovered && hovered.fw, aligned, tweens: tweens.size, chart: chart && chart.kind, filter: filter && (filter.name || filter.i), motion, sec: cur.id, card: cardMode, info: post ? post.calls : renderer.info.render.calls, triangles: post ? post.triangles : renderer.info.render.triangles, textures: renderer.info.memory.textures, geometries: renderer.info.memory.geometries, near: nearPool.filter(e => e.u).length, lodPaints, pending: lodWant.length }; },
    },
  });
  return handle;
}
