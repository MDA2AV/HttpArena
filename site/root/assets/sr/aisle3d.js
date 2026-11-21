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

     open(opts) -> Promise<{ close(), setFav(fw, on), focus(fw) }>

   close() disposes everything and does not call onClose (the page asked for
   it); the module calls onClose only when it closed itself. With Motion off it
   draws only while something moves; with Motion on it runs the room's ambient
   motion at a capped rate while the tab is visible. */
import * as THREE from '../vendor/three/three.module.min.js';
import { OrbitControls } from '../vendor/three/OrbitControls.js';

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
  exposure: 1.0, envK: 0.6, bg: 0x07090c, fogD: 0.06,
  hemi: [0x9fb6cf, 0x040506, 0.55], dir: [0xdde9f6, 0.75], spot: [0xd8e9ff, 26], spots: 4,
  floor: '#1a1f24', speck: ['#232930', '#101417'], seam: '#030405', seamHi: '#2f373f', perfHole: '#020304', perfRing: '#343c45', floorRough: 0.36,
  wall: 0x0b0e11, ceil: 0x090b0e, wallWash: 0x1b2836,
  frame: 0x15181c, frameRough: 0.46, frameMetal: 0.5, inner: 0x07080a, plinth: 0x08090b,
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
  lamp: 0xe9f3ff, lampK: 2.6, fixture: 0x1a1d21, tray: 0x2a2f35,
  door: '#111418', doorFrame: '#191c21', doorBack: '#040506', doorKit: ['#262b31', '#2f353c', '#1d2126'], rear: '#0c0e11', rearHole: '#2a3a4c', rearLit: 0.55,
  favAdd: true, favK: 0.42, favPipeK: 3.6, mirrorK: 1.0,
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
  noc: { bg: '#090d12', card: '#0e141b', line: '#1f2a36', text: '#eef3f7', muted: '#8c99a7', accent: '#62c4ff', grid: 'rgba(98,196,255,0.06)', bar: '#3dff8f', sel: 'rgba(98,196,255,0.16)' },
};
const LIGHT = {
  exposure: 1.0, envK: 0.42, bg: 0xdde2e7, fogD: 0.035,
  hemi: [0xffffff, 0xb9c1c9, 0.95], dir: [0xffffff, 1.25], spot: [0xffffff, 5], spots: 2,
  floor: '#dfe3e7', speck: ['#eceff2', '#c9d0d6'], seam: '#9aa3ac', seamHi: '#f6f7f8', perfHole: '#6f7a85', perfRing: '#f2f4f6', floorRough: 0.55,
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
  lamp: 0xffffff, lampK: 1.6, fixture: 0xc9cfd5, tray: 0x9aa3ac,
  door: '#363c43', doorFrame: '#30363c', doorBack: '#0d0f12', doorKit: ['#4a525b', '#58616a', '#3f464e'], rear: '#2a3036', rearHole: '#aab4be', rearLit: 0.25,
  favAdd: false, favK: 0.2, favPipeK: 1.6, mirrorK: 0.3,
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
.a3d-msg{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;padding:24px;text-align:center;font-size:14px;color:var(--a3-muted);z-index:7;pointer-events:none;transition:opacity .3s ease}
.a3d-msg.off{opacity:0}
.a3d-msg.err{pointer-events:auto;background:var(--a3-bg)}
.a3d-live{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);clip-path:inset(50%);white-space:nowrap}
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
  // the seams between tiles, with a bevel
  ctx.fillStyle = P.seam; ctx.fillRect(0, 0, S, 2); ctx.fillRect(0, S - 2, S, 2); ctx.fillRect(0, 0, 2, S); ctx.fillRect(S - 2, 0, 2, S);
  ctx.fillStyle = P.seamHi; ctx.fillRect(2, 2, S - 4, 1.2); ctx.fillRect(2, 2, 1.2, S - 4);
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

function doorTexture(P, seed, dark) {
  // a perforated door; the equipment behind shows through the mesh, and its LEDs
  const W = 512, H = 1700, cv = canvas(W, H), ctx = cv.getContext('2d');
  const r = rng(seed);
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
  // the door's sheet, holes punched through it
  const sheet = canvas(W, H), sc = sheet.getContext('2d');
  sc.fillStyle = P.door; sc.fillRect(0, 0, W, H);
  sc.globalCompositeOperation = 'destination-out';
  const pitch = 7.2, hr = 2.7;
  for (let j = 0, yy = 60; yy < H - 60; j++, yy += pitch * 0.866) {
    for (let xx = 34 + (j % 2) * pitch / 2; xx < W - 34; xx += pitch) { circle(sc, xx, yy, hr); sc.fill(); }
  }
  sc.globalCompositeOperation = 'source-over';
  ctx.drawImage(sheet, 0, 0);
  sheet.width = sheet.height = 0;
  // LEDs read through the mesh as points of light
  for (const d of dots) { ctx.globalAlpha = 0.45 + 0.55 * d.lv; ctx.fillStyle = d.c; circle(ctx, d.x, d.y, 2.3); ctx.fill(); }
  ctx.globalAlpha = 1;
  // the frame, the handle and a small label
  ctx.strokeStyle = P.doorFrame; ctx.lineWidth = 56; ctx.strokeRect(0, 0, W, H);
  ctx.strokeStyle = dark ? 'rgba(255,255,255,.07)' : 'rgba(255,255,255,.16)'; ctx.lineWidth = 2; ctx.strokeRect(29, 29, W - 58, H - 58);
  ctx.fillStyle = dark ? '#2a3036' : '#59626b'; rrect(ctx, W - 22, H * 0.44, 12, 190, 5); ctx.fill();
  ctx.fillStyle = dark ? '#0a0c0e' : '#1d2126'; circle(ctx, W - 16, H * 0.44 + 210, 6); ctx.fill();
  ctx.fillStyle = dark ? '#1c2025' : '#e9edf0'; rrect(ctx, W / 2 - 70, 8, 140, 18, 3); ctx.fill();
  return { cv, leds: glows.map(l => ({ x: (l.x / W - 0.5), y: (0.5 - l.y / H), color: l.color, level: l.level })) };
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
  const metric = world.metric ? String(world.metric) : 'Score';
  const tests = (Array.isArray(o.tests) ? o.tests : []).map((t, i) => {
    t = t || {};
    return { i, id: t.id != null ? String(t.id) : 't' + i, label: t.label != null ? String(t.label) : t.id != null ? String(t.id) : 'Test ' + (i + 1), category: t.category ? String(t.category) : '', conns: num(t.conns) };
  });
  const nT = tests.length;
  const perRack = Math.max(1, Math.floor(+o.perRack) || 42);
  const LY = layout(nT);
  const agg = (run, runs, k, how) => {
    if (run && num(run[k]) != null) return num(run[k]);
    const v = [];
    for (const l of runs) { const x = num(l[k]); if (x != null) v.push(x); }
    return v.length ? how(v) : null;
  };
  const units = (Array.isArray(o.units) ? o.units : []).map((s, i) => {
    s = s || {};
    const leds = Array.isArray(s.leds) ? s.leds : [];
    const run = s.run && typeof s.run === 'object' ? s.run : null;
    const runs = leds.filter(l => l && typeof l === 'object');
    const comp = s.completeness && typeof s.completeness === 'object' ? s.completeness : null;
    return {
      i, fw: String(s.fw), rank: s.rank != null ? s.rank : i + 1, lang: s.lang ? String(s.lang) : '',
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
  const byFw = new Map(units.map(u => [u.fw, u]));
  const nR = Math.max(1, Math.ceil(units.length / perRack));
  // the hall's ranges, so a fan or a gauge reads against its neighbours
  const vals = k => units.map(u => u[k]).filter(v => v != null && v > 0);
  const hall = {};
  for (const k of ['cpu', 'mem', 'rps', 'p99']) { const v = vals(k); hall[k] = v.length ? [Math.min(...v), Math.max(...v)] : null; }
  hall.cores = machine ? num(machine.cores) : null;
  hall.leader = units.length ? scoreNum(units[0].score) : null;
  const logN = (v, r) => (v == null || !r ? null : r[1] > r[0] ? clamp01(Math.log(Math.max(v, r[0]) / r[0]) / Math.log(r[1] / r[0])) : 0.5);
  const linN = (v, r) => (v == null || !r ? null : clamp01(v / r[1]));
  for (const u of units) { u.cpuN = linN(u.cpu, hall.cpu); u.memN = logN(u.mem, hall.mem); u.rpsN = linN(u.rps, hall.rps); u.p99N = logN(u.p99, hall.p99); }
  const has = { cpu: !!hall.cpu, mem: !!hall.mem, p99: !!hall.p99, rps: !!hall.rps };
  const unitsTop = BASE_Y + perRack * U, RACK_H = unitsTop + TOP_H;
  const X0 = -((nR - 1) * PITCH) / 2;
  const rackX = k => X0 + k * PITCH;
  const rowX0 = rackX(0) - PITCH / 2, rowX1 = rackX(nR - 1) + PITCH / 2;
  const midX = (rowX0 + rowX1) / 2, endL = rowX0 - 2 * PITCH - 1.4, endR = rowX1 + 2 * PITCH + 1.4;
  // the racks' own stats, for their marquees, power strips and floor
  const langOf = list => {
    const m = new Map();
    for (const u of list) { if (!u.lang) continue; const e = m.get(u.lang) || { name: u.lang, n: 0, color: u.langColor, best: u, shares: [] }; e.n++; e.shares.push(u.share); m.set(u.lang, e); }
    return [...m.values()].map(e => Object.assign(e, { avg: mean(e.shares) })).sort((a, b) => b.n - a.n || a.best.rank - b.best.rank);
  };
  const racks = Array.from({ length: nR }, (_, k) => {
    const us = units.filter(u => u.rack === k), sc = us.map(u => scoreNum(u.score)).filter(v => v != null);
    return { k, us, from: k * perRack + 1, to: Math.min(units.length, (k + 1) * perRack), best: us[0] || null, median: sc.length ? median(sc) : null,
      langs: langOf(us), tuned: us.filter(u => u.tuned).length, load: us.length ? mean(us.map(u => u.share)) : 0, rps: sum(us.map(u => u.rps || 0)) };
  });
  const hallLangs = langOf(units);
  for (const t of tests) {
    let best = null;
    for (const u of units) { const l = u.leds[t.i]; if (l && l.best) { best = u; break; } }
    if (!best) { let bp = -1; for (const u of units) { const l = u.leds[t.i]; if (l && num(l.p) != null && +l.p > bp) { bp = +l.p; best = u; } } }
    t.best = best ? 'best ' + best.fw : '';
  }
  const family = nT > 0 && tests.every(t => !t.category && t.conns == null) && !units.some(u => u.leds.some(l => l && num(l.rps) != null));

  const bin = new Set();
  const own = x => { bin.add(x); return x; };
  const canvases = [];
  const keepCv = c => { canvases.push(c); return c; };
  let disposed = false;

  const vw = () => host.clientWidth || window.innerWidth || 1;
  const vh = () => host.clientHeight || window.innerHeight || 1;
  const small = vw() <= 760;

  /* the HUD */
  const root = document.createElement('div');
  root.className = 'a3d';
  const chipHtml = Array.from({ length: nR }, (_, k) => {
    const a = racks[k].from, b = racks[k].to;
    return '<button type="button" class="a3d-btn a3d-chip" data-rack="' + k + '" aria-label="Go to rack R' + (k + 1) + ', units ' + a + ' to ' + b + '">R' + (k + 1)
      + (b >= a ? '<small>#' + a + (b > a ? '–' + b : '') + '</small>' : '') + '</button>';
  }).join('');
  const pulls = PULL.filter(([k]) => k === 'off' || k === 'score' || has[k]).map(([k, l]) => '<button type="button" data-pull="' + k + '" aria-pressed="' + (k === 'off') + '">' + l + '</button>').join('');
  const testOpts = nT ? '<select data-pull-test class="a3d-hide-s" aria-label="Pull out by a test"><option value="">A test…</option>' + tests.map(t => '<option value="' + t.i + '">' + esc(t.label) + '</option>').join('') + '</select>' : '';
  // on a phone one select holds every measure
  const allOpts = '<select data-pull-all class="a3d-show-s" aria-label="Pull the drawers out by">' + PULL.filter(([k]) => k === 'off' || k === 'score' || has[k]).map(([k, l]) => '<option value="' + k + '">' + (k === 'off' ? 'Pull out by…' : l) + '</option>').join('')
    + tests.map(t => '<option value="t' + t.i + '">' + esc(t.label) + '</option>').join('') + '</select>';
  root.innerHTML = '<style>' + CSS + '</style>'
    + '<canvas class="a3d-cv" tabindex="0" aria-label="The racks in 3D. Drag to look around, scroll to zoom."></canvas>'
    + '<div class="a3d-top"><div class="a3d-title a3d-glass"><b>' + esc(o.title || 'The aisle') + '</b>' + (o.subtitle ? '<span>' + esc(o.subtitle) + '</span>' : '') + '</div>'
    + '<div class="a3d-nav a3d-glass" role="toolbar" aria-label="Aisle navigation">'
    + '<button type="button" class="a3d-btn" data-act="prev" aria-label="Previous rack" title="Previous rack ([ or PageUp)">' + ICON.prev + '<span class="a3d-bt">Previous rack</span></button>'
    + '<div class="a3d-chips">' + chipHtml + '<button type="button" class="a3d-btn a3d-chip" data-act="wall" aria-label="Go to the operations wall" title="The operations wall at the end of the aisle">' + ICON.wall + '<span class="a3d-bt">Wall</span></button></div>'
    + '<button type="button" class="a3d-btn" data-act="next" aria-label="Next rack" title="Next rack (] or PageDown)"><span class="a3d-bt">Next rack</span>' + ICON.next + '</button>'
    + '<span class="a3d-sep" aria-hidden="true"></span>'
    + '<button type="button" class="a3d-btn" data-act="reset" aria-label="Reset view" title="Reset view (Home)">' + ICON.reset + '<span class="a3d-bt">Reset view</span></button>'
    + '<button type="button" class="a3d-btn" data-act="close" aria-label="Close the 3D aisle (Esc)">' + ICON.close + '<span class="a3d-bt">Close (Esc)</span></button>'
    + '</div></div>'
    + '<div class="a3d-bar a3d-glass" role="toolbar" aria-label="Aisle tools">'
    + '<div class="a3d-find">' + ICON.find + '<input type="search" placeholder="' + (vw() <= 760 ? 'Find' : 'Find a framework') + '" aria-label="Find a framework" autocomplete="off" spellcheck="false"><ul class="a3d-res a3d-glass" role="listbox" aria-label="Matches"></ul></div>'
    + '<div class="a3d-seg" role="group" aria-label="Pull the drawers out by"><span>Pull out by</span>' + pulls + testOpts + allOpts + '</div>'
    + '<button type="button" class="a3d-btn a3d-tog" data-act="motion" aria-pressed="false" title="Fans, lights and marquees in motion"><i aria-hidden="true"></i><span class="a3d-bt">Motion</span></button>'
    + '<button type="button" class="a3d-btn a3d-hide-s" data-act="tour" title="A guided walk past the notable units">' + ICON.tour + '<span class="a3d-bt">Tour</span></button>'
    + '<button type="button" class="a3d-btn a3d-lit a3d-hide-s" data-act="unlit" hidden><i aria-hidden="true"></i><span></span></button>'
    + '<button type="button" class="a3d-btn a3d-hide-s" data-act="keys" aria-expanded="false" aria-label="Controls" title="Controls">' + ICON.keys + '</button>'
    + '</div>'
    + '<div class="a3d-keys a3d-glass" hidden><b>Getting around</b><ul>'
    + '<li>Drag to look around, right-drag to pan, scroll to zoom</li>'
    + '<li><kbd>W</kbd><kbd>A</kbd><kbd>S</kbd><kbd>D</kbd> or arrows to walk, <kbd>Q</kbd><kbd>E</kbd> down and up</li>'
    + '<li><kbd>[</kbd><kbd>]</kbd> change rack, <kbd>Home</kbd> back to the start</li>'
    + '<li>Point at a light, a fan or a gauge to read it; click a unit to open it</li>'
    + '<li>Click a language, a bar or a test on the wall to light or pull out those units</li>'
    + '</ul><button type="button" class="a3d-btn" data-act="keys-hide">Got it</button></div>'
    + '<div class="a3d-cap a3d-glass" hidden aria-live="polite"><b></b><div class="a3d-cap-t"></div><div class="a3d-row"><span></span><button type="button" class="a3d-btn" data-act="tour-next">Next</button><button type="button" class="a3d-btn" data-act="tour-stop">End the tour</button></div></div>'
    + '<div class="a3d-tip a3d-glass" role="tooltip"></div>'
    + '<div class="a3d-tip a3d-ledtip a3d-glass" role="tooltip"></div>'
    + '<aside class="a3d-panel a3d-glass" aria-label="Unit details" aria-hidden="true">'
    + '<div class="a3d-pbar"><button type="button" class="a3d-btn a3d-loc" aria-pressed="false"><i aria-hidden="true"></i><span>Locator light</span></button>'
    + '<span class="a3d-sp"></span><button type="button" class="a3d-btn" data-close aria-label="Slide the unit back into the rack">' + ICON.back + '<span>Slide back in</span></button></div>'
    + '<div class="a3d-pbody"></div></aside>'
    + '<div class="a3d-msg">Racking ' + units.length + ' unit' + (units.length === 1 ? '' : 's') + '…</div>'
    + '<div class="a3d-live" aria-live="polite"></div>';
  const addedCls = ['a3d-host', dark ? 'a3d-dark' : 'a3d-light'];
  host.classList.add(...addedCls);
  const hadRole = host.hasAttribute('role');
  if (!hadRole) { host.setAttribute('role', 'dialog'); host.setAttribute('aria-modal', 'true'); host.setAttribute('aria-label', o.title || '3D aisle'); }
  host.appendChild(root);
  const $ = s => root.querySelector(s);
  const cv = $('.a3d-cv'), tipEl = $('.a3d-tip:not(.a3d-ledtip)'), ledTipEl = $('.a3d-ledtip'), panel = $('.a3d-panel');
  const pbody = $('.a3d-pbody'), locBtn = $('.a3d-loc'), msgEl = $('.a3d-msg'), live = $('.a3d-live'), keysEl = $('.a3d-keys');
  const findIn = $('.a3d-find input'), findRes = $('.a3d-res'), capEl = $('.a3d-cap'), litBtn = $('[data-act="unlit"]');
  const motionBtn = $('[data-act="motion"]'), keysBtn = $('[data-act="keys"]'), pullSel = $('[data-pull-test]'), pullAll = $('[data-pull-all]');
  const btn = { prev: $('[data-act="prev"]'), next: $('[data-act="next"]') };
  const chipEls = Array.from(root.querySelectorAll('.a3d-chip[data-rack]'));
  const wallChip = $('[data-act="wall"]');
  let prefs = {};
  try { prefs = JSON.parse(localStorage.getItem('a3d-prefs') || '{}') || {}; } catch (e) { prefs = {}; }
  const savePrefs = () => { try { localStorage.setItem('a3d-prefs', JSON.stringify(prefs)); } catch (e) { /* storage off */ } };
  try { if (localStorage.getItem('a3d-help') !== '0' && !prefs.keysSeen) { keysEl.hidden = false; keysBtn.setAttribute('aria-expanded', 'true'); } } catch (e) { keysEl.hidden = false; }


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

  /* the renderer */
  let renderer;
  try {
    renderer = new THREE.WebGLRenderer({ canvas: cv, antialias: true, powerPreference: 'high-performance' });
  } catch (e) {
    return fail('This browser could not start WebGL, so the 3D aisle cannot open here.');
  }
  renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
  renderer.setSize(vw(), vh(), false);
  renderer.toneMapping = THREE.NeutralToneMapping;
  renderer.toneMappingExposure = P.exposure;
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  const aniso = Math.min(8, renderer.capabilities.getMaxAnisotropy());

  // the fonts the panels are printed in; a missing one falls back, a slow one does not hold the room up
  try {
    const want = ['600 34px "Saira SC"', '700 34px "Saira SC"', '600 24px "Inter"', '700 24px "Inter"', '500 24px "Inter"', '700 40px "DSEG7"'];
    await Promise.race([
      Promise.all(want.map(f => document.fonts.load(f).catch(() => null))).then(() => document.fonts.ready),
      new Promise(r => setTimeout(r, 2500)),
    ]);
  } catch (e) { /* no FontFaceSet: system fonts */ }
  if (disposed) { renderer.dispose(); return { close() {}, setFav() {}, focus() {} }; }

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
    return t;
  };
  // a redraw paints a fresh canvas; a new size needs fresh storage on the GPU
  const repaint = (t, w, h, draw) => {
    const c = canvas(w, h); draw(c);
    if (t.userData.size && t.userData.size !== w + 'x' + h) t.dispose();
    t.userData.size = w + 'x' + h;
    t.image = c; t.needsUpdate = true;
  };
  const T = { value: 0 };   // the one clock everything that moves reads

  /* the scene */
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(P.bg);
  scene.fog = new THREE.FogExp2(P.bg, P.fogD);
  const camera = new THREE.PerspectiveCamera(FOV, vw() / vh(), 0.02, 60);

  // a small room of lamps, prefiltered, for the metal to reflect
  let envRT = null;
  try {
    const es = new THREE.Scene();
    const bx = new THREE.BoxGeometry(1, 1, 1);
    const roomM = new THREE.MeshBasicMaterial({ color: dark ? 0x0c0f13 : 0xb4bcc4, side: THREE.BackSide });
    const room = new THREE.Mesh(bx, roomM); room.scale.set(14, 5, 10); room.position.y = 1.6; es.add(room);
    const lampM = new THREE.MeshBasicMaterial({ color: new THREE.Color(dark ? 0xc6dcff : 0xffffff).multiplyScalar(dark ? 6 : 3.5) });
    for (let i = -2; i <= 2; i++) { const m = new THREE.Mesh(bx, lampM); m.scale.set(11, 0.05, 0.28); m.position.set(0, 3.9, i * 1.9); es.add(m); }
    const floorM = new THREE.MeshBasicMaterial({ color: dark ? 0x101317 : 0xdde2e7 });
    const fl = new THREE.Mesh(bx, floorM); fl.scale.set(14, 0.02, 10); fl.position.y = -0.85; es.add(fl);
    const pm = new THREE.PMREMGenerator(renderer);
    envRT = pm.fromScene(es, 0.04);
    pm.dispose(); bx.dispose(); roomM.dispose(); lampM.dispose(); floorM.dispose();
    scene.environment = envRT.texture;
    scene.environmentIntensity = P.envK;
  } catch (e) { envRT = null; }

  // light
  scene.add(new THREE.HemisphereLight(P.hemi[0], P.hemi[1], P.hemi[2]));
  const sun = new THREE.DirectionalLight(P.dir[0], P.dir[1]);
  sun.position.set(rackX(0) - 2.2, 4.2, 5.2);
  sun.target.position.set(midX, 1, 0);
  scene.add(sun, sun.target);
  const nSpots = Math.min(P.spots, nR);
  for (let i = 0; i < nSpots; i++) {
    const x = nSpots === 1 ? midX : rowX0 + 0.3 + (rowX1 - rowX0 - 0.6) * i / (nSpots - 1);
    const sp = new THREE.SpotLight(P.spot[0], P.spot[1], 8, 0.78, 0.9, 1.6);
    sp.position.set(x, 2.95, 1.35); sp.target.position.set(x, 0.85, -0.2);
    scene.add(sp, sp.target);
  }

  // materials
  const std = (color, rough, metal, extra) => own(new THREE.MeshStandardMaterial(Object.assign({ color, roughness: rough, metalness: metal }, extra || {})));
  const basic = (color, extra) => own(new THREE.MeshBasicMaterial(Object.assign({ color }, extra || {})));
  const M = {
    frame: std(P.frame, P.frameRough, P.frameMetal),
    inner: std(P.inner, 0.8, 0.2),
    plinth: std(P.plinth, 0.7, 0.3),
    post: std(P.post, 0.5, 0.55),
    fixture: std(P.fixture, 0.6, 0.4),
    tray: std(P.tray, 0.5, 0.35),
    wall: std(P.wall, 0.95, 0, { emissive: P.wallWash, emissiveMap: own(new THREE.CanvasTexture((() => {
      // light from the ceiling washing down the walls
      const c = canvas(4, 256), x = c.getContext('2d'), g = x.createLinearGradient(0, 0, 0, 256);
      g.addColorStop(0, '#fff'); g.addColorStop(0.12, '#c8c8c8'); g.addColorStop(0.45, '#3a3a3a'); g.addColorStop(1, '#000');
      x.fillStyle = g; x.fillRect(0, 0, 4, 256); return keepCv(c);
    })())) }),
    ceil: std(P.ceil, 0.95, 0),
    body: std(P.body, 0.42, 0.65),
    plateEdge: std(P.face[1], 0.55, 0.4),
    rail: std(P.rail, 0.3, 0.85),
    lamp: basic(new THREE.Color(P.lamp).multiplyScalar(P.lampK)),
    wire: basic(dark ? 0x2a2f35 : 0x8e979f),
    bezel: std(dark ? 0x0b0d10 : 0x2a3036, 0.6, 0.4),
  };
  M.postFaceL = std(0xffffff, 0.5, 0.45, { map: tex(keepCv(postTexture(P, perRack, 'right'))) });   // the left post's opening edge is on its right
  M.postFaceR = std(0xffffff, 0.5, 0.45, { map: tex(keepCv(postTexture(P, perRack, 'left'))) });
  const rearT = tex(keepCv(rearTexture(P)), { repeat: [1, Math.max(1, Math.round(perRack / 10))] });
  M.rear = std(0xffffff, 0.75, 0.2, { map: rearT, emissiveMap: rearT, emissive: 0xffffff, emissiveIntensity: P.rearLit });
  M.pdu = std(0xffffff, 0.6, 0.3, { map: tex(keepCv(rearPduTexture(P, dark))) });

  /* the room: floor, tiles, walls, ceiling, the lights and the fibre runner */
  const ROOM = 36;
  const shiftX = (((rowX0 % 0.6) + 0.6) % 0.6);
  const floorT = tex(keepCv(tileTexture(P, false)), { repeat: [ROOM / 0.6, ROOM / 0.6] });
  const floor = new THREE.Mesh(own(new THREE.PlaneGeometry(ROOM, ROOM)), std(0xffffff, P.floorRough, 0, { map: floorT }));
  floor.rotation.x = -Math.PI / 2; floor.position.set(shiftX, 0, 0);
  scene.add(floor);
  const strips = [];
  const nRow = nR + 4;
  const perfT = tex(keepCv(tileTexture(P, true)), { repeat: [nRow, 1] });
  const perfM = std(0xffffff, P.floorRough, 0, { map: perfT, polygonOffset: true, polygonOffsetFactor: -1, polygonOffsetUnits: -1 });
  for (const z of [0.3, OPP_Z - 0.3]) {
    const strip = new THREE.Mesh(own(new THREE.PlaneGeometry(nRow * PITCH, 0.6)), perfM);
    strip.rotation.x = -Math.PI / 2; strip.position.set(midX, 0.0005, z);
    scene.add(strip); strips.push(strip);
  }

  const parts = new Map();
  const add = (key, g, m) => { if (!parts.has(key)) parts.set(key, []); parts.get(key).push({ g, m }); };
  const _q = new THREE.Quaternion(), _e = new THREE.Euler(), _s = new THREE.Vector3(1, 1, 1), _p = new THREE.Vector3();
  const mat4 = (x, y, z, ry = 0, rx = 0) => new THREE.Matrix4().compose(_p.set(x, y, z), _q.setFromEuler(_e.set(rx, ry, 0)), _s);
  const box = (key, base, w, h, d, x, y, z) => add(key, new THREE.BoxGeometry(w, h, d), base.clone().multiply(mat4(x, y, z)));
  const plane = (key, base, w, h, x, y, z, ry = 0, rx = 0) => add(key, new THREE.PlaneGeometry(w, h), base.clone().multiply(mat4(x, y, z, ry, rx)));

  // walls and ceiling
  const I4 = new THREE.Matrix4();
  plane('wall', I4, endR - endL, CEIL, midX, CEIL / 2, -1.75);
  plane('wall', I4, endR - endL, CEIL, midX, CEIL / 2, OPP_Z + 1.75, Math.PI);
  plane('wall', I4, OPP_Z + 3.5, CEIL, endL, CEIL / 2, OPP_Z / 2, Math.PI / 2);
  plane('wall', I4, OPP_Z + 3.5, CEIL, endR, CEIL / 2, OPP_Z / 2, -Math.PI / 2);
  plane('ceil', I4, endR - endL, OPP_Z + 3.5, midX, CEIL, OPP_Z / 2, 0, Math.PI / 2);
  // two lines of light over the aisle, hung from the ceiling
  const lampLen = rowX1 - rowX0 + 4 * PITCH;
  for (const z of [1.05, OPP_Z - 1.05]) {
    box('fixture', I4, lampLen, 0.05, 0.1, midX, 2.92, z);
    plane('lamp', I4, lampLen - 0.02, 0.07, midX, 2.894, z, 0, Math.PI / 2);
    for (let x = midX - lampLen / 2 + 0.3; x < midX + lampLen / 2; x += 1.5) box('wire', I4, 0.004, CEIL - 2.94, 0.004, x, (CEIL + 2.94) / 2, z);
  }
  // the fibre runner over each row
  for (const z of [-0.55, OPP_Z + 0.55]) {
    box('tray', I4, lampLen, 0.008, 0.24, midX, 2.62, z);
    box('tray', I4, lampLen, 0.09, 0.008, midX, 2.665, z - 0.116);
    box('tray', I4, lampLen, 0.09, 0.008, midX, 2.665, z + 0.116);
    for (let x = midX - lampLen / 2 + 0.4; x < midX + lampLen / 2; x += 1.2) box('wire', I4, 0.008, CEIL - 2.62, 0.008, x, (CEIL + 2.62) / 2, z);
  }

  // a cabinet: its frame, sides, roof, back, plinth; open fronts get posts, the rest a door
  function cabinet(base, isOpen) {
    const hw = RACK_W / 2;
    box('frame', base, SIDE_T, RACK_H, RACK_D, -hw + SIDE_T / 2, RACK_H / 2, -RACK_D / 2);
    box('frame', base, SIDE_T, RACK_H, RACK_D, hw - SIDE_T / 2, RACK_H / 2, -RACK_D / 2);
    box('frame', base, RACK_W, 0.014, RACK_D, 0, RACK_H - 0.007, -RACK_D / 2);
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
  for (let k = 0; k < nR; k++) cabinet(mat4(rackX(k), 0, 0), true);
  // the neighbours: closed cabinets at both ends of the row, and the row across the aisle
  const doors = [];
  const doorSpots = [];
  for (let k = -2; k < nR + 2; k++) {
    if (k < 0 || k >= nR) { const m = mat4(rackX(k), 0, 0); cabinet(m, false); doorSpots.push(m); }
    const m = mat4(rackX(k), 0, OPP_Z, Math.PI); cabinet(m, false); doorSpots.push(m);
  }
  const doorKinds = [doorTexture(P, 11, dark), doorTexture(P, 29, dark), doorTexture(P, 47, dark)];
  const doorW = RACK_W - 0.012, doorH = RACK_H - PLINTH_H - 0.012;
  doorKinds.forEach((d, i) => { M['door' + i] = std(0xffffff, 0.55, 0.35, { map: tex(keepCv(d.cv)) }); });
  doorSpots.forEach((m, i) => {
    const kind = (i * 7 + 3) % 3;
    plane('door' + kind, m, doorW, doorH, 0, PLINTH_H + 0.006 + doorH / 2, 0.006);
    doors.push({ m, kind });
  });
  const WALL_X = endR - 0.05;
  for (const [key, list] of parts) {
    const mesh = new THREE.Mesh(own(mergeParts(list)), M[key]);
    mesh.matrixAutoUpdate = false;
    scene.add(mesh);
  }

  /* each rack's own hardware: its plate, a marquee of its stats, a power strip
     with its language mix, a floor strip warmed by its average share */
  const plateGeo = own(new THREE.PlaneGeometry(0.3, 0.05));
  const mqGeo = own(new THREE.PlaneGeometry(0.54, 0.54 * MQ_ROWS / MQ_COLS));
  const glowT = tex(keepCv(glowTexture()), { linear: true });
  const pickRack = [];   // power strips and marquees answer the pointer too
  const mqs = [];
  for (const R of racks) {
    const k = R.k, x = rackX(k);
    const t = tex(keepCv(labelTexture(P, k, R.from, R.to)));
    const pm = new THREE.Mesh(plateGeo, P.plateLit ? basic(0xffffff, { map: t }) : std(0xffffff, 0.45, 0.2, { map: t }));
    pm.position.set(x, unitsTop + TOP_H - 0.037, 0.0008);
    scene.add(pm);
    const top3 = R.langs.slice(0, 4).map(l => l.name + ' ' + l.n).join(', ') + (R.langs.length > 4 ? ' +' + (R.langs.length - 4) : '');
    const msg = ['R' + (k + 1) + '  #' + R.from + (R.to > R.from ? '–' + R.to : ''),
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
    mq.position.set(x, unitsTop + 0.052, 0.0125);
    mq.userData = { rack: k, part: 'marquee', msg };
    scene.add(mq); mqs.push({ mesh: mq, w: mc.width, speed: 20 });
    pickRack.push(mq);
    // the power strip down the right side of the front frame
    const bw = RACK_W / 2 - (OPEN_HALF + POST_W), uh = perRack * U;
    const pt = tex(keepCv(rackPduTexture(P, R)));
    const pd = new THREE.Mesh(own(new THREE.PlaneGeometry(bw - 0.006, uh)), std(0xffffff, 0.6, 0.3, { map: pt, emissiveMap: pt, emissive: 0xffffff, emissiveIntensity: dark ? 0.6 : 0.22 }));
    pd.position.set(x + OPEN_HALF + POST_W + bw / 2, BASE_Y + uh / 2, 0.0006);
    pd.userData = { rack: k, part: 'pdu' };
    scene.add(pd); pickRack.push(pd);
    // the floor in front of it, cold blue to hot amber by its average share
    const sc = rampColor(P.ramp, R.load);
    const fs = new THREE.Mesh(own(new THREE.PlaneGeometry(RACK_W - 0.07, 0.034)), basic(sc.clone().multiplyScalar(P.stripK)));
    fs.rotation.x = -Math.PI / 2; fs.position.set(x, 0.0014, 0.03);
    const fg = new THREE.Mesh(own(new THREE.PlaneGeometry(RACK_W * 1.15, 0.9)), basic(sc, { alphaMap: glowT, transparent: true, opacity: P.stripGlow, depthWrite: false, blending: dark ? THREE.AdditiveBlending : THREE.NormalBlending }));
    fg.rotation.x = -Math.PI / 2; fg.position.set(x, 0.0018, 0.05);
    fg.renderOrder = 1;
    scene.add(fs, fg);
  }
  // light running along the cable tray over each rack, as fast as the rack's throughput
  const pulses = [];
  const rpsMax = Math.max(1, ...racks.map(R => R.rps));
  for (const R of racks) {
    if (!R.rps) continue;
    const pm = own(new THREE.ShaderMaterial({
      uniforms: THREE.UniformsUtils.merge([THREE.UniformsLib.fog, { uTime: { value: 0 }, uRate: { value: 0.4 + 2.2 * R.rps / rpsMax }, uColor: { value: new THREE.Color(P.ledB).multiplyScalar(dark ? 1.6 : 1.2) } }]),
      vertexShader: MQ_VS, fragmentShader: PULSE_FS, fog: true,
    }));
    pm.uniforms.uTime = T;
    const pl = new THREE.Mesh(own(new THREE.PlaneGeometry(PITCH - 0.02, 0.03)), pm);
    pl.position.set(rackX(R.k), 2.665, -0.55 + 0.121);
    scene.add(pl); pulses.push(pl);
  }

  // the sign over the aisle
  {
    const sw = Math.min(1.7, Math.max(1.1, rowX1 - rowX0 + 0.2)), sh = sw * 200 / 1280;
    const t = tex(keepCv(signTexture(P, o.title, o.subtitle)));
    const sign = new THREE.Mesh(own(new THREE.PlaneGeometry(sw, sh)), P.signLit ? basic(0xffffff, { map: t }) : std(0xffffff, 0.5, 0.05, { map: t }));
    sign.position.set(midX, 2.6, 1.07);
    const back = new THREE.Mesh(own(new THREE.BoxGeometry(sw + 0.03, sh + 0.03, 0.03)), M.fixture);
    back.position.set(midX, 2.6, 1.05);
    scene.add(sign, back);
    for (const dx of [-sw / 2 + 0.08, sw / 2 - 0.08]) {
      const w = new THREE.Mesh(own(new THREE.BoxGeometry(0.004, 2.894 - 2.6 - sh / 2, 0.004)), M.wire);
      w.position.set(midX + dx, (2.894 + 2.6 + sh / 2) / 2, 1.05);
      scene.add(w);
    }
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
    const m = new THREE.Mesh(nocGeo, basic(0xffffff, { map: t, toneMapped: false }));
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

  /* the units */
  const faceGeo = own(new THREE.PlaneGeometry(PANEL_W, UNIT_H));
  const plateBox = own(new THREE.BoxGeometry(PANEL_W, UNIT_H, PLATE_T));
  const bodyGeo = own(new THREE.BoxGeometry(BODY_W, UNIT_H * 0.95, BODY_D));
  const railGeo = own(new THREE.BoxGeometry(0.007, 0.013, BODY_D * 0.93));
  const faceW = small ? 768 : TW, faceH = Math.round(faceW * TH / TW);
  const lcdW = (LY.lcd[1] - LY.lcd[0]) / TW * PANEL_W, lcdH = (LY.lcdY[1] - LY.lcdY[0]) / TH * UNIT_H;
  const lcdGeo = own(new THREE.PlaneGeometry(lcdW, lcdH));
  const lcdPx = [small ? 192 : 256, Math.round((small ? 192 : 256) * lcdH / lcdW)];
  const lcdCx = pxX((LY.lcd[0] + LY.lcd[1]) / 2), lcdCy = pxY((LY.lcdY[0] + LY.lcdY[1]) / 2);
  const favT = tex(keepCv(favTexture()), { linear: true });
  const favGeo = own(new THREE.PlaneGeometry(PANEL_W, UNIT_H));
  const favMat = basic(new THREE.Color(P.ledB), { alphaMap: favT, transparent: true, opacity: P.favK, depthWrite: false, blending: P.favAdd ? THREE.AdditiveBlending : THREE.NormalBlending });
  const pipeGeo = own(new THREE.PlaneGeometry(PANEL_W - 0.004, 0.0011));
  const pipeMat = basic(new THREE.Color(P.ledB).multiplyScalar(P.favPipeK));
  const lcdMat = t => (P.lcdLit ? basic(0xffffff, { map: t }) : std(0xffffff, 0.35, 0, { map: t }));
  const WHITE = new THREE.Color(1, 1, 1);

  const faces = [], lcds = [];
  for (const u of units) {
    const g = new THREE.Group();
    u.x0 = rackX(u.rack); u.y0 = BASE_Y + (perRack - u.slot - 0.5) * U; u.z0 = FACE_Z;
    g.position.set(u.x0, u.y0, u.z0);
    const cf = canvas(faceW, faceH); drawFace(cf, u, LY, P);
    u.texFace = tex(cf);
    u.matFace = std(0xffffff, 0.6, 0.25, { map: u.texFace, emissiveMap: u.texFace, emissive: 0xffffff, emissiveIntensity: P.faceEm });
    u.face = new THREE.Mesh(faceGeo, u.matFace); u.face.position.z = 0.0001; u.face.userData = { u, part: 'face' };
    const cl = canvas(lcdPx[0], lcdPx[1]); drawLcd(cl, u, P);
    u.texLcd = tex(cl);
    u.matLcd = lcdMat(u.texLcd);
    u.lcd = new THREE.Mesh(lcdGeo, u.matLcd); u.lcd.position.set(lcdCx, lcdCy, 0.0003); u.lcd.userData = { u, part: 'lcd' };
    u.plate = new THREE.Mesh(plateBox, M.plateEdge); u.plate.position.z = -PLATE_T / 2; u.plate.userData = { u, part: 'plate' };
    u.body = new THREE.Mesh(bodyGeo, M.body); u.body.position.z = -PLATE_T - BODY_D / 2 - 0.0004; u.body.userData = { u, part: 'body' };
    u.railL = new THREE.Mesh(railGeo, M.rail); u.railL.position.set(-BODY_W / 2 - 0.0035, -0.004, -PLATE_T - BODY_D * 0.47);
    u.railR = new THREE.Mesh(railGeo, M.rail); u.railR.position.set(BODY_W / 2 + 0.0035, -0.004, -PLATE_T - BODY_D * 0.47);
    u.plate.visible = u.body.visible = u.railL.visible = u.railR.visible = false;
    g.add(u.face, u.lcd, u.plate, u.body, u.railL, u.railR);
    u.group = g; u.slide = 0; u.tw = null; u.fx = null; u.dim = 0; u.litUp = false; u.chartS = 0; u.chartV = null;
    scene.add(g);
    faces.push(u.face); lcds.push(u.lcd);
  }

  /* the lights, the equalisers and the fans: one instanced draw each */
  function instanced(count, vs, fs, uniforms, attrs, opt) {
    const geo = own(new THREE.PlaneGeometry(1, 1));
    for (const [name, size] of attrs) geo.setAttribute(name, new THREE.InstancedBufferAttribute(new Float32Array(Math.max(1, count) * size), size));
    const mat = own(new THREE.ShaderMaterial({
      uniforms: THREE.UniformsUtils.merge([THREE.UniformsLib.fog, uniforms]),
      vertexShader: vs, fragmentShader: fs, fog: true, transparent: true,
      depthWrite: !opt.additive, blending: opt.additive ? THREE.AdditiveBlending : THREE.NormalBlending,
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
  const RL = [   // the round lights on a panel: locator, activity, error, four completeness pips
    [pxX(LY.locX), pxY(LY.locY), 0.0062, 0.024], [pxX(LY.actX), pxY(LY.stY), 0.0028, 0.011], [pxX(LY.errX), pxY(LY.stY), 0.0028, 0.011],
    [pxX(LY.pipX), pxY(LY.pipY[0]), 0.0029, 0.01], [pxX(LY.pipX + 11), pxY(LY.pipY[0]), 0.0029, 0.01],
    [pxX(LY.pipX), pxY(LY.pipY[1]), 0.0029, 0.01], [pxX(LY.pipX + 11), pxY(LY.pipY[1]), 0.0029, 0.01],
  ];
  const per = RL.length;
  const decorLeds = [];
  doors.forEach(d => { for (const l of doorKinds[d.kind].leds) decorLeds.push({ m: d.m, l }); });
  const nLens = units.length * per, nGlow = nLens + (P.decorGlowK > 0 ? decorLeds.length : 0);
  const LED_ATTRS = [['aColor', 3], ['aLevel', 1], ['aHot', 1], ['aBlink', 2], ['aDim', 1]];
  const EQ_ATTRS = [['aColor', 3], ['aLevel', 1], ['aHot', 1], ['aDim', 1]];
  const lens = instanced(nLens, LED_VS, LENS_FS, { uTime: { value: 0 }, uOff: { value: new THREE.Color(P.ledOff) }, uBoost: { value: P.ledBoost } }, LED_ATTRS, { order: 2 });
  const glow = instanced(nGlow, LED_VS, GLOW_FS, { uTime: { value: 0 }, uGlow: { value: P.glowK }, uTint: { value: dark ? 0 : 1 } }, LED_ATTRS, { additive: dark, order: 3 });
  const nEq = units.length * nT;
  const eq = instanced(nEq, EQ_VS, EQ_FS, { uOff: { value: new THREE.Color(P.eqOff) }, uBoost: { value: P.ledBoost } }, EQ_ATTRS, { order: 2 });
  const eqGlow = instanced(nEq, EQ_VS, EQG_FS, { uGlow: { value: P.eqGlowK }, uTint: { value: dark ? 0 : 1 } }, EQ_ATTRS, { additive: dark, order: 3 });
  const fans = instanced(units.length, FAN_VS, FAN_FS, { uTime: { value: 0 }, uHousing: { value: new THREE.Color(P.fan[0]) }, uBlade: { value: new THREE.Color(P.fan[1]) }, uCavity: { value: new THREE.Color(P.fan[2]) } }, [['aSpeed', 1], ['aPhase', 1], ['aDim', 1]], { order: 2 });
  const cG = new THREE.Color(P.ledG), cB = new THREE.Color(P.ledB), cA = new THREE.Color(P.ledA), cR = new THREE.Color(P.ledR);
  const setAttr = (mesh, name, i, a, b, c) => { const at = mesh.geometry.attributes[name], k = i * at.itemSize; at.array[k] = a; if (b !== undefined) at.array[k + 1] = b; if (c !== undefined) at.array[k + 2] = c; };
  function setMat(mesh, i, x, y, z, sx, sy) {
    const e = mesh.instanceMatrix.array, o16 = i * 16;
    e[o16] = sx; e[o16 + 1] = 0; e[o16 + 2] = 0; e[o16 + 3] = 0;
    e[o16 + 4] = 0; e[o16 + 5] = sy; e[o16 + 6] = 0; e[o16 + 7] = 0;
    e[o16 + 8] = 0; e[o16 + 9] = 0; e[o16 + 10] = 1; e[o16 + 11] = 0;
    e[o16 + 12] = x; e[o16 + 13] = y; e[o16 + 14] = z; e[o16 + 15] = 1;
  }
  const eqX = tests.map((_, t) => pxX(LY.eqX0 + LY.sp * (t + 0.5)));
  const eqW = nT ? LY.sp * 0.74 / TW * PANEL_W : 0, eqH = (LY.eqY[1] - LY.eqY[0]) / TH * UNIT_H, eqCy = pxY((LY.eqY[0] + LY.eqY[1]) / 2);
  const fanD = 2 * LY.fanR / TW * PANEL_W, fanX = pxX(LY.fanX), fanY = pxY(LY.cy);
  function ledsOf(u) {
    const b = u.i * per, dim = u.dim;
    const put = (j, c, lv, hot, blink, phase) => {
      for (const m of [lens, glow]) { setAttr(m, 'aColor', b + j, c.r, c.g, c.b); setAttr(m, 'aLevel', b + j, lv); setAttr(m, 'aHot', b + j, hot); setAttr(m, 'aBlink', b + j, blink, phase); setAttr(m, 'aDim', b + j, dim); }
    };
    put(0, cB, u.fav ? 1 : -1, 0, 0, 0);
    // the activity light blinks faster the closer the entry is to the leader (the board's ACT)
    put(1, cG, u.share > 0 ? 0.85 : -1, 0, u.share > 0 ? 2.6 - 2.0 * u.share : 0, (hash(u.fw) % 1000) / 1000);
    put(2, cA, u.errors > 0 ? 0.95 : -1, 0, u.errors > 0 ? 1.7 : 0, 0.3);
    COMP.forEach(([k], j) => { const v = u.completeness ? u.completeness[k] : null; put(3 + j, v ? cG : cR, v == null ? -1 : 0.72, 0, 0, 0); });
    for (let t = 0; t < nT; t++) {
      const l = u.leds[t], p = l ? num(l.p) : null, i = u.i * nT + t;
      for (const m of [eq, eqGlow]) { setAttr(m, 'aColor', i, cG.r, cG.g, cG.b); setAttr(m, 'aLevel', i, p == null ? -1 : clamp01(p)); setAttr(m, 'aHot', i, p != null && l.best ? 1 : 0); setAttr(m, 'aDim', i, dim); }
    }
    setAttr(fans, 'aSpeed', u.i, u.cpuN == null ? 0 : 0.12 + 2.3 * u.cpuN);
    setAttr(fans, 'aPhase', u.i, (hash(u.fw) % 628) / 100);
    setAttr(fans, 'aDim', u.i, dim);
  }
  function placeLeds(u) {
    const p = u.group.position;
    for (let j = 0; j < per; j++) {
      const [x, y, s, gs] = RL[j];
      setMat(lens, u.i * per + j, p.x + x, p.y + y, p.z + LED_Z, s, s);
      setMat(glow, u.i * per + j, p.x + x, p.y + y, p.z + LED_Z + 0.0004, gs, gs);
    }
    for (let t = 0; t < nT; t++) {
      const i = u.i * nT + t;
      setMat(eq, i, p.x + eqX[t], p.y + eqCy, p.z + 0.0009, eqW, eqH);
      setMat(eqGlow, i, p.x + eqX[t], p.y + eqCy, p.z + 0.0014, eqW * 1.7, eqH / 0.86);
    }
    setMat(fans, u.i, p.x + fanX, p.y + fanY, p.z + 0.0007, fanD, fanD);
    lens.instanceMatrix.needsUpdate = glow.instanceMatrix.needsUpdate = fans.instanceMatrix.needsUpdate = true;
    if (nT) eq.instanceMatrix.needsUpdate = eqGlow.instanceMatrix.needsUpdate = true;
  }
  const ledAttrsDirty = () => {
    for (const m of [lens, glow, eq, eqGlow]) for (const k of ['aColor', 'aLevel', 'aHot', 'aDim', 'aBlink']) if (m.geometry.attributes[k]) m.geometry.attributes[k].needsUpdate = true;
    for (const k of ['aSpeed', 'aPhase', 'aDim']) fans.geometry.attributes[k].needsUpdate = true;
  };
  for (const u of units) { ledsOf(u); placeLeds(u); }
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

  // fav: the locator lit, the whole front washed blue, light pipes along its edges
  function favFx(u) {
    if (u.fav && !u.fx) {
      const ov = new THREE.Mesh(favGeo, favMat); ov.position.z = 0.0005; ov.renderOrder = 4;
      const top = new THREE.Mesh(pipeGeo, pipeMat); top.position.set(0, UNIT_H / 2 - 0.0007, 0.0006);
      const bot = new THREE.Mesh(pipeGeo, pipeMat); bot.position.set(0, -UNIT_H / 2 + 0.0007, 0.0006);
      u.fx = [ov, top, bot]; u.group.add(ov, top, bot);
    } else if (!u.fav && u.fx) {
      for (const m of u.fx) u.group.remove(m);
      u.fx = null;
    }
  }
  units.forEach(favFx);

  // the drawer chart: a coloured body for each drawer that is out, in one draw
  const selfLit = (mat, k) => { mat.onBeforeCompile = sh => { sh.fragmentShader = sh.fragmentShader.replace('#include <emissivemap_fragment>', '#include <emissivemap_fragment>\n  totalEmissiveRadiance += diffuseColor.rgb * ' + k.toFixed(2) + ';'); }; mat.customProgramCacheKey = () => 'a3d-lit-' + k.toFixed(2); return mat; };
  const chartBodies = new THREE.InstancedMesh(bodyGeo, selfLit(std(0xffffff, 0.45, 0.3), dark ? 0.55 : 0.18), Math.max(1, units.length));
  chartBodies.count = units.length; chartBodies.frustumCulled = false; chartBodies.visible = false;
  chartBodies.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
  for (const u of units) { chartBodies.setColorAt(u.i, WHITE); setMat(chartBodies, u.i, 0, -9, 0, 0, 0); }
  scene.add(chartBodies);
  function placeChartBody(u) {
    const e = chartBodies.instanceMatrix.array, o16 = u.i * 16, on = chart && u.slide > 0.0006 && u !== popped, p = u.group.position;
    e.fill(0, o16, o16 + 16);
    if (on) { e[o16] = 1; e[o16 + 5] = 1; e[o16 + 10] = 1; e[o16 + 12] = p.x; e[o16 + 13] = p.y; e[o16 + 14] = p.z + u.body.position.z; }
    e[o16 + 15] = 1;
    chartBodies.instanceMatrix.needsUpdate = true;
  }

  /* the podium for the top three, in front of the operations wall: each block
     carries its unit in miniature, turning slowly, its own panel on its front */
  const podium = [], podiumPick = [];
  {
    const PX = WALL_X - 0.8, PZ = OPP_Z / 2, ST = 0.42, hts = [0.34, 0.24, 0.17].map(h => h + ST), dz = [0, -0.44, 0.44];
    const stage = new THREE.Mesh(own(new THREE.BoxGeometry(0.62, ST, 1.48)), std(P.plinth, 0.5, 0.4));
    stage.position.set(PX, ST / 2, PZ); scene.add(stage);
    const cols = dark ? ['#f3c742', '#d5dde6', '#e09a62'] : ['#b8860b', '#6b7683', '#a0592a'];
    const miniBox = own(new THREE.BoxGeometry(0.4, 0.036, 0.26)), miniFace = own(new THREE.PlaneGeometry(0.4, 0.4 * UNIT_H / PANEL_W));
    units.slice(0, 3).forEach((u, k) => {
      const h = hts[k], z = PZ + dz[k];
      const blk = new THREE.Mesh(own(new THREE.BoxGeometry(0.36, h - ST, 0.38)), std(P.frame, 0.32, 0.6));
      blk.position.set(PX, ST + (h - ST) / 2, z); blk.userData = { u, part: 'podium' };
      const lab = new THREE.Mesh(own(new THREE.PlaneGeometry(0.22, 0.22)), basic(0xffffff, { map: tex(keepCv(podiumRank(k, cols[k]))), transparent: true, depthWrite: false }));
      lab.rotation.y = -Math.PI / 2; lab.position.set(PX - 0.182, Math.max(ST + 0.11, h - 0.14), z);
      const rim = new THREE.Mesh(own(new THREE.BoxGeometry(0.366, 0.008, 0.386)), basic(new THREE.Color(cols[k]).multiplyScalar(dark ? 1.5 : 0.9)));
      rim.position.set(PX, h - 0.004, z);
      const mini = new THREE.Group();
      mini.position.set(PX, h + 0.08, z); mini.rotation.y = -Math.PI / 2;
      const mb = new THREE.Mesh(miniBox, M.body); mb.userData = { u, part: 'podium' };
      const mf = new THREE.Mesh(miniFace, basic(0xffffff, { map: u.texFace }));
      mf.position.z = 0.1306;
      mini.add(mb, mf);
      const np = new THREE.Mesh(own(new THREE.PlaneGeometry(0.42, 0.13)), basic(0xffffff, { map: tex(keepCv(podiumPlate(u, k, cols[k], P))), transparent: true, depthWrite: false }));
      np.rotation.y = -Math.PI / 2; np.position.set(PX, h + 0.23, z); np.renderOrder = 4;
      scene.add(blk, lab, rim, mini, np);
      podium.push({ mini, base: h + 0.08, phase: k * 2.1 });
      podiumPick.push(blk, mb);
    });
  }

  /* an open unit's insides: built once, lent to whichever unit is out */
  const K = interiorPlan(nT);
  const inside = new THREE.Group();
  inside.visible = false;
  const floorY = -UNIT_H * 0.475, zMid = -PLATE_T - BODY_D / 2;
  {
    const tl = [];
    tl.push({ g: new THREE.BoxGeometry(BODY_W, 0.002, BODY_D), m: mat4(0, floorY, zMid) });
    tl.push({ g: new THREE.BoxGeometry(0.002, UNIT_H * 0.9, BODY_D), m: mat4(-BODY_W / 2, -0.001, zMid) });
    tl.push({ g: new THREE.BoxGeometry(0.002, UNIT_H * 0.9, BODY_D), m: mat4(BODY_W / 2, -0.001, zMid) });
    tl.push({ g: new THREE.BoxGeometry(BODY_W, UNIT_H * 0.9, 0.002), m: mat4(0, -0.001, -PLATE_T - BODY_D) });
    inside.add(new THREE.Mesh(own(mergeParts(tl)), M.body));
  }
  const pcbPx = [small ? 640 : 1024, Math.round((small ? 640 : 1024) * BODY_D / BODY_W)];
  const pcbT = tex(canvas(pcbPx[0], pcbPx[1]));
  const board = new THREE.Mesh(own(new THREE.PlaneGeometry(BODY_W - 0.003, BODY_D - 0.003)), std(0xffffff, 0.55, 0.25, { map: pcbT, emissiveMap: pcbT, emissive: 0xffffff, emissiveIntensity: dark ? 0.2 : 0.05 }));
  board.rotation.x = -Math.PI / 2; board.position.set(0, floorY + 0.0012, zMid);
  inside.add(board);
  // a chip per test, its height its share of the best: a little bar chart
  const chipGeo = own(new THREE.BoxGeometry(1, 1, 1)); chipGeo.translate(0, 0.5, 0);
  const chips = new THREE.InstancedMesh(chipGeo, selfLit(std(0xffffff, 0.35, 0.2), dark ? 0.7 : 0.22), Math.max(1, nT));
  chips.count = nT; chips.frustumCulled = false; chips.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
  chips.userData = { part: 'chips' };
  for (let t = 0; t < nT; t++) chips.setColorAt(t, WHITE);
  inside.add(chips);
  // the CPU: a heatsink that glows with the load
  const finT = tex(keepCv((() => { const c = canvas(128, 128), x = c.getContext('2d'); x.fillStyle = dark ? '#2a2f35' : '#9aa3ac'; x.fillRect(0, 0, 128, 128); x.fillStyle = dark ? '#5d666f' : '#e3e7ea'; for (let i = 0; i < 128; i += 10) x.fillRect(i, 0, 5, 128); return c; })()));
  const cpuMat = std(0xffffff, 0.4, 0.7, { map: finT, emissive: 0x000000 });
  const cpu = new THREE.Mesh(own(new THREE.BoxGeometry(K.cpu, 0.026, K.cpu)), cpuMat);
  cpu.position.set(0, floorY + 0.015, K.zCpu);
  const heatMat = basic(0xffffff, { alphaMap: glowT, transparent: true, opacity: 0, depthWrite: false, blending: dark ? THREE.AdditiveBlending : THREE.NormalBlending });
  const heat = new THREE.Mesh(own(new THREE.PlaneGeometry(K.cpu * 2.1, K.cpu * 2.1)), heatMat);
  heat.rotation.x = -Math.PI / 2; heat.position.set(0, floorY + 0.0295, K.zCpu);
  inside.add(cpu, heat);
  // memory: as many sticks as it uses, the nearest the CPU first
  const ramGeo = own(new THREE.BoxGeometry(0.0034, 0.03, K.ramLen)); ramGeo.translate(0, 0.015, 0);
  const ram = new THREE.InstancedMesh(ramGeo, std(dark ? 0x1d3b2c : 0x2a6b4c, 0.5, 0.3), 8);
  const ramLedGeo = own(new THREE.BoxGeometry(0.0038, 0.0028, K.ramLen * 0.92));
  const ramLed = new THREE.InstancedMesh(ramLedGeo, basic(new THREE.Color(P.holo).multiplyScalar(dark ? 1.5 : 1)), 8);
  const RAM_ORDER = [3, 4, 2, 5, 1, 6, 0, 7];
  const _m4 = new THREE.Matrix4();
  for (let i = 0; i < 8; i++) {
    const x = K.ramX[RAM_ORDER[i]];
    ram.setMatrixAt(i, _m4.makeTranslation(x, floorY + 0.002, K.zRam));
    ramLed.setMatrixAt(i, _m4.makeTranslation(x, floorY + 0.0335, K.zRam));
  }
  ram.count = ramLed.count = 0;
  inside.add(ram, ramLed);
  // the NIC, its activity light flickering with the throughput; the power supply
  const nic = new THREE.Mesh(own(new THREE.BoxGeometry(0.0025, 0.03, 0.11)), std(dark ? 0x173326 : 0x245a40, 0.5, 0.3));
  nic.position.set(K.nic, floorY + 0.017, K.zRam);
  const nicLed = [cA, cG].map((c, j) => { const m = new THREE.Mesh(own(new THREE.BoxGeometry(0.0055, 0.004, 0.008)), basic(c.clone())); m.position.set(K.nic, floorY + 0.0335, K.zRam + 0.045 - j * 0.016); return m; });
  const psuT = tex(keepCv((() => {
    const c = canvas(256, 256), x = c.getContext('2d');
    x.fillStyle = dark ? '#262b31' : '#a8b0b8'; x.fillRect(0, 0, 256, 256);
    x.strokeStyle = dark ? '#0c0e10' : '#4f5963'; x.lineWidth = 5;
    for (let r = 24; r < 96; r += 18) { x.beginPath(); x.arc(128, 110, r, 0, Math.PI * 2); x.stroke(); }
    x.fillStyle = dark ? '#c9d1d9' : '#1d2126'; x.font = '700 30px ' + FONT_SANS; x.textAlign = 'center'; x.fillText('1600 W', 128, 238);
    return c;
  })()));
  const psu = new THREE.Mesh(own(new THREE.BoxGeometry(0.07, 0.034, 0.12)), std(0xffffff, 0.45, 0.55, { map: psuT }));
  psu.position.set(K.psu, floorY + 0.019, K.zRam);
  inside.add(nic, psu, ...nicLed);
  // the lid; once open, it slides back into the rack and only its tag stays out
  const lidPx = [small ? 640 : 1024, Math.round((small ? 640 : 1024) * BODY_D / BODY_W)];
  const lidT = tex(canvas(lidPx[0], lidPx[1]));
  const lid = new THREE.Mesh(own(new THREE.PlaneGeometry(BODY_W - 0.002, BODY_D - 0.002)), std(0xffffff, 0.45, 0.55, { map: lidT }));
  lid.rotation.x = -Math.PI / 2; lid.position.set(0, UNIT_H * 0.475 + 0.0006, zMid);
  lid.userData = { part: 'lid' };
  inside.add(lid);
  // the strength hologram, projected up from the CPU
  const holoPx = small ? 512 : 640;
  const holoT = tex(canvas(holoPx, holoPx));
  const holoMat = own(new THREE.ShaderMaterial({ uniforms: { tHolo: { value: holoT }, uTime: T, uAlpha: { value: 0 } }, vertexShader: HOLO_VS, fragmentShader: HOLO_FS, transparent: true, depthWrite: false, side: THREE.DoubleSide }));
  const holo = new THREE.Mesh(own(new THREE.PlaneGeometry(0.23, 0.23)), holoMat);
  holo.position.set(0, floorY + 0.03 + 0.05 + 0.115, K.zCpu - 0.02);
  holo.renderOrder = 6;
  const beamMat = own(new THREE.ShaderMaterial({ uniforms: { uColor: { value: new THREE.Color(P.holo) }, uAlpha: { value: 0 }, uTime: T }, vertexShader: HOLO_VS, fragmentShader: BEAM_FS, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide }));
  const beam = new THREE.Mesh(own(new THREE.CylinderGeometry(0.1, 0.014, 0.05, 40, 1, true)), beamMat);
  beam.position.set(0, floorY + 0.03 + 0.025, K.zCpu - 0.01);
  beam.renderOrder = 5;
  inside.add(holo, beam);
  let openK = 0, openTw = null, openU = null;
  function setOpen(k) {
    openK = k;
    lid.position.z = zMid - k * LID_BACK; lid.position.y = UNIT_H * 0.475 + 0.0006 + k * 0.004;
    const u = openU;
    if (u) for (let t = 0; t < nT; t++) {
      const l = u.leds[t], p = l ? num(l.p) : null;
      const grow = clamp01(k * 1.6 - (t / Math.max(1, nT)) * 0.6);
      const h = (p == null ? 0.0025 : 0.004 + p * K.chipMax) * easeOut(grow) + 0.0003;
      chips.setMatrixAt(t, _m4.makeScale(K.chipW, h, K.chipW).setPosition(K.chipX[t], floorY + 0.0022, K.zChip));
    }
    chips.instanceMatrix.needsUpdate = true;
    const hk = clamp01((k - 0.45) / 0.55);
    holoMat.uniforms.uAlpha.value = u && (u.strength || u.spec != null || u.resil != null || u.completeness) ? hk : 0;
    beamMat.uniforms.uAlpha.value = holoMat.uniforms.uAlpha.value * (dark ? 1 : 0.6);
    holo.visible = beam.visible = holoMat.uniforms.uAlpha.value > 0.002;
    holo.scale.setScalar(0.85 + 0.15 * hk);
    if (u) { heatMat.opacity = (0.15 + 0.6 * (u.cpuN || 0)) * k; cpuMat.emissiveIntensity = (dark ? 0.3 + 2.2 * (u.cpuN || 0) : 0.2 + 0.9 * (u.cpuN || 0)) * k; }
  }
  function dressInside(u) {
    openU = u;
    repaint(pcbT, pcbPx[0], pcbPx[1], c => drawPcb(c, u, tests, K, P));
    repaint(lidT, lidPx[0], lidPx[1], c => drawLid(c, u, P));
    repaint(holoT, holoPx, holoPx, c => drawHolo(c, u, P));
    const pk = new THREE.Color();
    for (let t = 0; t < nT; t++) {
      const l = u.leds[t], p = l ? num(l.p) : null;
      if (p == null) pk.set(P.eqOff); else if (l.best) pk.setRGB(1, 1, 0.92); else pk.copy(cG).multiplyScalar(0.35 + 0.65 * clamp01(p));
      chips.setColorAt(t, pk);
    }
    if (chips.instanceColor) chips.instanceColor.needsUpdate = true;
    const sticks = u.memN == null ? 0 : Math.max(1, Math.round(1 + u.memN * 7));
    ram.count = ramLed.count = sticks;
    ram.instanceMatrix.needsUpdate = ramLed.instanceMatrix.needsUpdate = true;
    const hc = rampColor(P.heat, 0.25 + 0.75 * (u.cpuN || 0));
    cpuMat.emissive.copy(hc); heatMat.color.copy(hc);
    nicLed[1].material.color.copy(u.rps ? cG : new THREE.Color(P.ledOff));
    u.group.add(inside);
    inside.visible = true;
    setOpen(0);
  }

  // the shadow an open unit casts on the panels below it
  const shT = tex(keepCv(shadowTexture()), { linear: true });
  const shadow = new THREE.Mesh(own(new THREE.PlaneGeometry(PANEL_W, 0.075)), basic(0x000000, { alphaMap: shT, transparent: true, opacity: 0, depthWrite: false }));
  shadow.visible = false; shadow.renderOrder = 1;
  scene.add(shadow);

  /* A polished floor: the room mirrored in it, soft. A second, half-size pass from a
     camera under the floor; the floor reads it back where it is. Not on a phone. */
  let mirror = null;
  if (P.mirrorK > 0 && !small) {
    try {
      const ext = renderer.extensions;
      const hdr = ext.has('EXT_color_buffer_float') || ext.has('EXT_color_buffer_half_float');
      const rt = own(new THREE.WebGLRenderTarget(2, 2, { type: hdr ? THREE.HalfFloatType : THREE.UnsignedByteType, generateMipmaps: true, minFilter: THREE.LinearMipmapLinearFilter, magFilter: THREE.LinearFilter }));
      mirror = { rt, cam: new THREE.PerspectiveCamera(), mat: new THREE.Matrix4(), look: new THREE.Vector3(), up: new THREE.Vector3(), ks: [] };
      const polish = (mat, k) => {
        mat.onBeforeCompile = sh => {
          sh.uniforms.tMirror = { value: rt.texture };
          sh.uniforms.uMirror = { value: mirror.mat };
          sh.uniforms.uMirrorK = { value: k };
          mirror.ks.push(sh.uniforms.uMirrorK);
          sh.vertexShader = 'uniform mat4 uMirror;\nvarying vec4 vMirror;\n' + sh.vertexShader.replace('#include <project_vertex>', '#include <project_vertex>\n  vMirror = uMirror * modelMatrix * vec4(position, 1.0);');
          sh.fragmentShader = 'uniform sampler2D tMirror;\nuniform float uMirrorK;\nvarying vec4 vMirror;\n' + sh.fragmentShader.replace('#include <opaque_fragment>', [
            '{',
            '  vec2 muv = vMirror.xy / vMirror.w;',
            '  vec3 m = textureLod(tMirror, muv, 0.6).rgb * 0.6 + textureLod(tMirror, muv, 2.0).rgb * 0.4;',
            '  float fr = mix(0.35, 1.0, pow(1.0 - clamp(dot(geometryViewDir, normal), 0.0, 1.0), 3.0));',
            '  outgoingLight += m * uMirrorK * fr;',
            '}',
            '#include <opaque_fragment>'].join('\n'));
        };
        mat.customProgramCacheKey = () => 'a3d-mirror';
      };
      polish(floor.material, P.mirrorK);
      polish(perfM, P.mirrorK * 0.6);
    } catch (e) { mirror = null; }
  }
  function sizeMirror() {
    if (!mirror) return;
    const v = renderer.getDrawingBufferSize(new THREE.Vector2());
    mirror.rt.setSize(Math.max(2, Math.round(v.x / 2)), Math.max(2, Math.round(v.y / 2)));
  }
  sizeMirror();
  function renderMirror() {
    const m = mirror, c = camera;
    m.cam.position.set(c.position.x, -c.position.y, c.position.z);
    m.look.set(0, 0, -1).applyQuaternion(c.quaternion).add(c.position); m.look.y = -m.look.y;
    m.up.set(0, 1, 0).applyQuaternion(c.quaternion); m.up.y = -m.up.y;
    m.cam.up.copy(m.up); m.cam.lookAt(m.look);
    m.cam.updateMatrixWorld();
    m.cam.projectionMatrix.copy(c.projectionMatrix);
    m.cam.projectionMatrixInverse.copy(c.projectionMatrixInverse);
    m.mat.set(0.5, 0, 0, 0.5, 0, 0.5, 0, 0.5, 0, 0, 0.5, 0.5, 0, 0, 0, 1);
    m.mat.multiply(m.cam.projectionMatrix).multiply(m.cam.matrixWorldInverse);
    floor.visible = false; for (const st of strips) st.visible = false;
    renderer.setRenderTarget(m.rt);
    renderer.render(scene, m.cam);
    renderer.setRenderTarget(null);
    floor.visible = true; for (const st of strips) st.visible = true;
  }

  /* camera and controls */
  const controls = new OrbitControls(camera, cv);
  controls.enableDamping = !reduced;
  controls.dampingFactor = 0.09;
  controls.screenSpacePanning = true;
  controls.zoomToCursor = true;
  controls.minDistance = 0.16;
  controls.maxDistance = 5.6;
  controls.minPolarAngle = 0.18;
  controls.maxPolarAngle = Math.PI / 2 + 0.34;
  controls.rotateSpeed = 0.6;
  controls.panSpeed = 0.9;

  // The projection's centre sits in the middle of what is left of the screen: the
  // card's panel reserves the right (or, narrow, the bottom), the HUD on a phone the top.
  const shift = { x: 0, y: 0 };
  const topBar = $('.a3d-top');
  const topRes = () => (vw() <= 760 ? Math.max(0, topBar.getBoundingClientRect().bottom - root.getBoundingClientRect().top) : 0);
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
  function overview() {
    const a = vw() / vh(), t = Math.tan(FOV * DEG / 2), hf = (vh() - topRes()) / vh();
    if (a < 1.05) {
      // a tall screen: R1 whole, the rest of the row going away from it
      const d = Math.max((RACK_H * 1.12) / 2 / (t * hf), (PITCH * 1.3) / 2 / (t * a));
      return { target: V(rackX(0) + 0.12, 1.04, -0.2), pos: V(rackX(0) - 0.5, 1.47, Math.min(OPP_Z - 0.45, d)) };
    }
    const len = Math.min(rowX1 - rowX0, 3 * PITCH);
    return { target: V(rowX0 + len * 0.66, 1.02, -0.2), pos: V(rowX0 - 1.1, 1.52, Math.min(OPP_Z - 0.45, 2.98 + len * 0.15 + Math.max(0, 1.5 - a) * 1.6)) };
  }
  function rackView(k) {
    const W = vw(), H = vh(), Hf = H - topRes();
    const t = Math.tan(FOV * DEG / 2);
    const d = Math.max((RACK_H + 0.28) / 2 / (t * Hf / H), (RACK_W + 0.42) / 2 / (t * W / H));
    return { target: V(rackX(k), RACK_H / 2 + 0.02, 0), pos: V(rackX(k), RACK_H / 2 + 0.16, Math.min(OPP_Z - 0.35, d)) };
  }
  function wallView() {
    const W = vw(), H = vh(), t = Math.tan(FOV * DEG / 2);
    // the screens, and the podium in front of them along the bottom of the frame
    const d = Math.max(2.8 / 2 / (t * (H - topRes()) / H), 4.5 / 2 / (t * W / H));
    return { target: V(WALL_X, 1.6, OPP_Z / 2), pos: V(Math.max(endL + 0.6, WALL_X - d), 1.52, OPP_Z / 2) };
  }
  function podiumView() {
    return { target: V(WALL_X - 0.8, 0.84, OPP_Z / 2), pos: V(WALL_X - 2.35, 1.2, OPP_Z / 2 - 0.55) };
  }
  function chartView() {
    const a = vw() / vh();
    if (a < 1.05) return { target: V(rackX(0) + 0.1, 1.0, 0.15), pos: V(rackX(0) - 1.2, 1.7, 2.6) };
    return { target: V(midX + 0.15, 0.95, 0.12), pos: V(rowX0 - 1.4, 1.9, Math.min(OPP_Z - 0.4, 2.0 + 0.13 * nR)) };
  }
  function reserve() {
    const W = vw(), H = vh();
    if (W <= 760) { const r = panel.getBoundingClientRect(); return { x: 0, y: Math.min(H * 0.6, (r.height || H * 0.5) + 24) }; }
    return { x: Math.min(420, W - 32) + 32, y: 0 };
  }
  function popView(u) {
    const W = vw(), H = vh(), S = reserve();
    const t = Math.tan(FOV * DEG / 2);
    const tx = t * (W - S.x) / H, ty = t * (H - S.y - topRes()) / H;
    const d = Math.max(0.34, (PANEL_W * 0.58) / (0.78 * tx), 0.2 / (0.86 * ty));
    const yaw = 0.2, el = 0.6;
    const target = V(u.x0, u.y0 + 0.075, u.z0 + POP - 0.21);
    const pos = target.clone().add(V(Math.sin(yaw) * Math.cos(el), Math.sin(el), Math.cos(yaw) * Math.cos(el)).multiplyScalar(d));
    pos.y = clamp(pos.y, 0.15, CEIL - 0.25); pos.z = Math.min(pos.z, OPP_Z - 0.35);
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
  function flyTo(view, dur) {
    stopCam();
    hideTips();
    if (hovered && hovered !== popped) setHover(null);   // the pointer no longer means what it meant
    if (controls._sphericalDelta) controls._sphericalDelta.set(0, 0, 0);
    if (controls._panOffset) controls._panOffset.set(0, 0, 0);
    const p0 = camera.position.clone(), t0 = controls.target.clone();
    const dist = p0.distanceTo(view.pos) + t0.distanceTo(view.target);
    camTw = tween(dur || clamp(520 + dist * 230, 650, 1400), k => {
      camera.position.lerpVectors(p0, view.pos, k);
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
  let hovered = null, popped = null, home = null, aligned = -1, atOverview = true, chart = null, filter = null;
  const restSlide = u => (chart ? u.chartS : Math.max(u.litUp ? 0.032 : 0, u === hovered ? LIFT : 0));
  function setSlide(u, s) {
    u.slide = s;
    u.group.position.z = u.z0 + s;
    const vis = s > 0.0006, close = vis && (!chart || u === popped || u === hovered);
    u.plate.visible = u.railL.visible = u.railR.visible = close;   // in the chart, the coloured bodies say it all
    u.body.visible = vis && u !== popped && !chart;
    placeLeds(u);
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
      if (prev) { faceGlow(prev); if (prev !== popped && !chart) slideTo(prev, restSlide(prev), 160, easeOut); }
      if (u) { faceGlow(u); if (u !== popped && !chart) slideTo(u, restSlide(u), 140, easeOut); }
      cv.classList.toggle('hot', !!u);
      if (!popped) nocDue('sel', 'hist');
      invalidate();
    }
  }
  function faceGlow(u) {
    const tint = chart && u.chartV != null ? rampColor(P.ramp, u.chartV) : null;
    u.matFace.emissive.copy(tint || WHITE);
    u.matFace.color.copy(WHITE).multiplyScalar(u.dim ? 0.13 : 1);
    if (tint && !u.dim) u.matFace.color.lerp(tint, dark ? 0.18 : 0.32);
    u.matFace.emissiveIntensity = u.dim ? P.faceEm * 0.25 : (tint ? (dark ? 0.62 : 0.14) : 0) + (u === hovered ? P.faceEmHot : P.faceEm);
    u.matLcd.color.setScalar(u.dim ? 0.15 : 1);
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
  const cores = n => (hall.cores ? ' (about ' + fmtN(Math.min(hall.cores, n / 100)) + ' of ' + hall.cores + ' cores)' : ' (about ' + fmtN(n / 100) + ' cores)');
  const fromRuns = u => (u.runFrom === 'tests' ? ' across its tests' : '');
  function pullLine(u) {
    if (!chart) return '';
    const name = chartLabel();
    if (u.chartV == null) return '<div class="a3d-tt-k">Pulled out by ' + esc(name) + ': no figure, so it stays in</div>';
    let v = '';
    if (chart.kind === 'score') v = esc(u.score) + ' (' + Math.round(u.share * 100) + '% of the leader)';
    else if (chart.kind === 'test') { const l = u.leds[chart.i]; v = fmtN(clamp01(l.p) * 100, 1) + '% of the best' + (num(l.rps) != null ? ', ' + fmtRps(+l.rps) + ' req/s' : ''); }
    else if (chart.kind === 'cpu') v = fmtN(u.cpu) + '% CPU' + cores(u.cpu);
    else if (chart.kind === 'mem') v = fmtMem(u.mem) + ' (log scale)';
    else if (chart.kind === 'p99') v = fmtMs(u.p99) + ' p99 (log scale)';
    return '<div class="a3d-tt-s">Pulled out by ' + esc(name) + ': <b>' + v + '</b></div>';
  }
  function unitTip(u, region) {
    const kind = region ? region.kind : 'unit', h = '<div class="a3d-tt-h"><span class="a3d-tt-n">' + esc(u.fw) + '</span></div>';
    if (kind === 'loc') return h + '<div class="a3d-tt-s">' + (u.fav ? '<span class="a3d-tt-fav">Locator light is on.</span> Click to turn it off.' : 'Locator light. Click to light it up and mark this entry as a favourite.') + '</div>';
    if (kind === 'act') return h + '<div class="a3d-tt-s">Activity light: it blinks faster the closer an entry is to the leader. This one runs at <b>' + fmtN(u.share * 100, 1) + '%</b> of the leader, one blink every ' + fmtN(2.6 - 2.0 * u.share, 1) + ' s.</div>';
    if (kind === 'err') return h + '<div class="a3d-tt-s">' + (u.errors > 0 ? 'Error light: <b>' + fmtN(u.errors) + '</b> responses were 4xx or 5xx' + fromRuns(u) + '.' : u.errors === 0 ? 'Error light off: no 4xx or 5xx responses' + fromRuns(u) + '.' : 'Error light: no error count for this view.') + '</div>';
    if (kind === 'mem') return h + '<div class="a3d-tt-s">' + (u.mem != null ? 'Memory gauge: <b>' + fmtMem(u.mem) + '</b>' + (u.runFrom === 'tests' ? ' (median across its tests)' : '') + '. The gauge reads on a log scale from ' + fmtMem(hall.mem[0]) + ' to ' + fmtMem(hall.mem[1]) + ', the hall\'s range.' : 'Memory gauge: no memory figure for this view.') + '</div>';
    if (kind === 'fan') return h + '<div class="a3d-tt-s">' + (u.cpu != null ? 'Fans: <b>' + fmtN(u.cpu) + '% CPU</b>' + cores(u.cpu) + (u.runFrom === 'tests' ? ', the average across its tests' : '') + '. They spin at ' + Math.round((u.cpuN || 0) * 100) + '% of the busiest in the hall.' : 'Fans idle: no CPU figure for this view.') + '</div>';
    if (kind === 'pips') return h + '<div class="a3d-tt-s">' + (u.completeness ? 'Completeness: ' + COMP.map(([k, n]) => (u.completeness[k] ? '<span class="a3d-tt-ok">' + n + '</span>' : '<span class="a3d-tt-no">no ' + n.toLowerCase() + '</span>')).join(', ') + '.' : 'Completeness pips off: not graded here.') + '</div>';
    const rc = u.rank <= 3 ? ' r' + u.rank : '';
    const meta = [u.lang ? '<i style="background:' + esc(u.langColor) + '"></i>' + esc(u.lang) : '', esc(TYPE_NAMES[u.type] || ''), u.tuned ? 'Tuned' : '', u.engine && u.engine.toLowerCase() !== u.fw.toLowerCase() ? 'on ' + esc(u.engine) : '', u.fav ? '<span class="a3d-tt-fav">Locator on</span>' : '']
      .filter(Boolean).join('<span aria-hidden="true">·</span>');
    const facts = [['CPU', u.cpu != null ? fmtN(u.cpu) + '%' : null], ['Memory', u.mem != null ? fmtMem(u.mem) : null], ['p99', u.p99 != null ? fmtMs(u.p99) : null], ['Errors', u.errors != null ? fmtN(u.errors) : null]].filter(f => f[1] != null);
    return '<div class="a3d-tt-h"><span class="a3d-tt-r' + rc + '">#' + esc(u.rank) + '</span><span class="a3d-tt-n">' + esc(u.fw) + '</span></div>'
      + (meta ? '<div class="a3d-tt-m">' + meta + '</div>' : '')
      + (u.score ? '<div class="a3d-tt-s">' + esc(metric) + ' <b>' + esc(u.score) + '</b>' + (u.share > 0 ? ' · ' + (u.share * 100).toFixed(u.share >= 0.995 ? 0 : 1) + '% of the leader' : '') + '</div>' : '')
      + pullLine(u)
      + (facts.length ? '<div class="a3d-tt-g">' + facts.map(([k, v]) => '<span>' + k + '</span><b>' + v + '</b>').join('') + '</div>' : '')
      + '<div class="a3d-tt-k">' + (u === popped ? 'Click to slide it back in' : 'Click to slide it out. Point at its lights to read them.') + '</div>';
  }
  function ledFallback(u, i) {
    const t = tests[i], l = u.leds[i];
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
      const k = u.fw + '|' + region.i;
      if (ledTipEl.dataset.k !== k) {
        let h = null;
        try { h = o.ledTipHtml ? o.ledTipHtml(u.fw, region.i) : null; } catch (e) { console.error(e); }
        if (!h) h = ledFallback(u, region.i);
        ledTipEl.dataset.k = k;
        ledTipEl.innerHTML = h || '';
        ledTipEl.classList.toggle('on', !!h);
      }
      if (ledTipEl.classList.contains('on')) { tipEl.classList.remove('on'); tipEl.dataset.k = ''; placeTip(ledTipEl, x, y); return; }
    } else { ledTipEl.classList.remove('on'); ledTipEl.dataset.k = ''; }
    const k = u.fw + '|' + region.kind + '|' + u.fav + '|' + (u === popped) + '|' + (chart ? chart.kind + chart.i : '');
    if (tipEl.dataset.k !== k) { tipEl.innerHTML = unitTip(u, region); tipEl.dataset.k = k; }
    tipEl.classList.add('on');
    placeTip(tipEl, x, y);
  }

  const ray = new THREE.Raycaster(), ndc = new THREE.Vector2();
  const nocMeshes = Object.values(noc).map(n => n.mesh);
  function pick(x, y) {
    const r = cv.getBoundingClientRect();
    if (!r.width || !r.height) return null;
    ndc.set(((x - r.left) / r.width) * 2 - 1, -((y - r.top) / r.height) * 2 + 1);
    ray.setFromCamera(ndc, camera);
    const list = faces.concat(lcds, nocMeshes, pickRack, podiumPick);
    for (const u of units) if (u.slide > 0.0006) list.push(u.plate, u === popped ? board : u.body);
    if (inside.visible) list.push(lid, chips);
    const hits = ray.intersectObjects(list, false);
    if (!hits.length) return null;
    const h = hits[0], d = h.object.userData;
    if (d.noc) {
      const n = noc[d.noc], cx = h.uv.x * 1280, cy = (1 - h.uv.y) * 720;
      const hh = n.hits.find(q => cx >= q.x && cx <= q.x + q.w && cy >= q.y && cy <= q.y + q.h);
      return hh ? { noc: d.noc, act: hh.act, text: '<div class="a3d-tt-s">' + esc(hh.tip) + '</div>', key: 'noc|' + d.noc + '|' + JSON.stringify(hh.act) } : { noc: d.noc };
    }
    if (d.part === 'pdu' || d.part === 'marquee') {
      const R = racks[d.rack];
      const text = d.part === 'pdu'
        ? '<div class="a3d-tt-h"><span class="a3d-tt-n">R' + (R.k + 1) + ' power strip</span></div><div class="a3d-tt-s">Load <b>' + Math.round(R.load * 100) + '%</b>: the rack\'s average share of the leader.</div><div class="a3d-tt-m">' + R.langs.map(l => '<i style="background:' + esc(l.color) + '"></i>' + esc(l.name) + ' ' + l.n).join('<span aria-hidden="true">·</span>') + '</div>'
        : '<div class="a3d-tt-h"><span class="a3d-tt-n">R' + (R.k + 1) + ' marquee</span></div><div class="a3d-tt-s">' + esc(d.msg.replace(/\s+•\s+$/, '').split(/\s+•\s+/).join(' · ')) + '</div>';
      return { text, key: d.part + R.k };
    }
    const u = d.u || ((d.part === 'lid' || d.part === 'chips' || h.object === board) && openU);
    if (!u) return null;
    let region = { kind: 'unit' };
    if (d.part === 'chips' && h.instanceId != null) region = { kind: 'led', i: h.instanceId };
    else if (d.part === 'face' && h.uv) {
      const px = h.uv.x * TW, py = (1 - h.uv.y) * TH;
      if (Math.hypot(px - LY.locX, py - LY.locY) < 14) region = { kind: 'loc' };
      else if (Math.hypot(px - LY.actX, py - LY.stY) < 7) region = { kind: 'act' };
      else if (Math.hypot(px - LY.errX, py - LY.stY) < 7) region = { kind: 'err' };
      else if (px >= 996) region = { kind: 'mem' };
      else if (px >= LY.pipX - 8 && px <= LY.pipX + 19 && py >= LY.pipY[0] - 9 && py <= LY.pipY[1] + 9) region = { kind: 'pips' };
      else if (Math.hypot(px - LY.fanX, py - LY.cy) < LY.fanR + 4) region = { kind: 'fan' };
      else if (nT > 0 && py >= LY.eqY[0] - 6 && py <= LY.eqY[1] + 6 && px >= LY.eqX0 && px < LY.eqX0 + nT * LY.sp) region = { kind: 'led', i: clamp(Math.floor((px - LY.eqX0) / LY.sp), 0, nT - 1) };
    }
    return { u, region };
  }

  /* hi-res panel and display for the unit that is out */
  function hiRes(u, on) {
    if (on && !u.hi) {
      const cf = canvas(TW * 2, TH * 2); drawFace(cf, u, LY, P);
      const cl = canvas(lcdPx[0] * 2, lcdPx[1] * 2); drawLcd(cl, u, P);
      u.hi = { tf: tex(cf), tl: tex(cl) };
      u.matFace.map = u.matFace.emissiveMap = u.hi.tf;
      u.matLcd.map = u.hi.tl;
    } else if (!on && u.hi) {
      u.matFace.map = u.matFace.emissiveMap = u.texFace;
      u.matLcd.map = u.texLcd;
      for (const t of [u.hi.tf, u.hi.tl]) { freeImage(t); t.dispose(); bin.delete(t); }
      u.hi = null;
    }
    invalidate();
  }
  function redrawFace(u) {
    repaint(u.texFace, faceW, faceH, c => drawFace(c, u, LY, P));
    if (u.hi) repaint(u.hi.tf, TW * 2, TH * 2, c => drawFace(c, u, LY, P));
  }

  /* slide out, slide back in */
  function updateLoc() {
    if (!popped) return;
    locBtn.setAttribute('aria-pressed', popped.fav ? 'true' : 'false');
    locBtn.querySelector('span').textContent = popped.fav ? 'Locator light on' : 'Locator light';
  }
  function pop(u) {
    if (!u || popped === u) return;
    if (!popped) home = { pos: camera.position.clone(), target: controls.target.clone() };
    const prev = popped;
    popped = u;
    if (prev) slideBack(prev);
    aligned = -1; atOverview = false;
    hiRes(u, true);
    u.body.visible = false;
    if (chart) placeChartBody(u);
    slideTo(u, POP, 460, easeBack);
    if (openTw) { tweens.delete(openTw); openTw = null; }
    dressInside(u);
    openTw = tween(720, setOpen, easeInOut, () => { openTw = null; }, reduced ? 0 : 380);
    shadow.userData.u = u; shadow.visible = true; shadow.material.opacity = 0.42 * clamp01(u.slide / POP);
    shadow.position.set(u.x0, u.y0 - UNIT_H / 2 - 0.0376, FACE_Z + 0.0006);
    let h = '';
    try { h = o.detailHtml ? o.detailHtml(u.fw) : ''; } catch (e) { console.error(e); }
    pbody.innerHTML = h || '';
    pbody.scrollTop = 0;
    panel.classList.add('on'); panel.setAttribute('aria-hidden', 'false');
    updateLoc();
    shiftTo(reserve());
    flyTo(popView(u), 900);
    live.textContent = u.fw + ' slid out of rack R' + (u.rack + 1) + ': rank ' + u.rank + (u.score ? ', ' + metric.toLowerCase() + ' ' + u.score : '') + '.';
    nocDue('sel', 'hist');
    hideTips();
  }
  function slideBack(u) {
    slideTo(u, restSlide(u), 380, easeInOut, () => { if (popped !== u) hiRes(u, false); });
  }
  function closeInside() {
    if (openTw) { tweens.delete(openTw); openTw = null; }
    inside.visible = false; if (inside.parent) inside.parent.remove(inside);
    openU = null; setOpen(0);
  }
  function unpop(restore) {
    const u = popped;
    if (!u) return;
    popped = null;
    closeInside();
    slideBack(u);
    shadow.visible = false; shadow.userData.u = null;
    panel.classList.remove('on'); panel.setAttribute('aria-hidden', 'true');
    shiftTo({ x: 0, y: 0 });
    if (restore !== false && home) flyTo(home, 760);
    home = null;
    live.textContent = u.fw + ' slid back into the rack.';
    nocDue('sel', 'hist');
    hideTips();
    if (panel.contains(document.activeElement)) cv.focus({ preventScroll: true });
  }
  function toggleFav(u) {
    let on = !u.fav;
    if (o.onFav) { try { const r = o.onFav(u.fw); if (typeof r === 'boolean') on = r; } catch (e) { console.error(e); } }
    applyFav(u, on);
  }
  function applyFav(u, on) {
    on = !!on;
    if (u.fav === on) return;
    u.fav = on;
    redrawFace(u);
    ledsOf(u); ledAttrsDirty();
    favFx(u);
    if (popped === u) updateLoc();
    if (tipEl.classList.contains('on') && hovered === u) tipEl.dataset.k = '';
    live.textContent = u.fw + (on ? ': locator light on.' : ': locator light off.');
    invalidate();
  }

  /* lighting a set of units: a language, a band of the histogram */
  function setFilter(f) {
    if (f && filter && f.kind === filter.kind && (f.kind === 'lang' ? f.name === filter.name : f.i === filter.i)) f = null;
    filter = f;
    const pred = !f ? null : f.kind === 'lang' ? (u => u.lang === f.name) : (u => Math.min(19, Math.floor(clamp01(u.share) * 20)) === f.i);
    let n = 0;
    units.forEach((u, idx) => {
      const on = !pred || pred(u);
      if (pred && on) n++;
      const dim = pred && !on ? 1 : 0, lit = !!(pred && on);
      if (u.dim !== dim) { u.dim = dim; faceGlow(u); ledsOf(u); if (chart) chartBodies.setColorAt(u.i, chartColor(u, new THREE.Color())); }
      if (u.litUp !== lit) { u.litUp = lit; if (u !== popped && !chart) slideTo(u, restSlide(u), 320, easeOut, null, reduced ? 0 : (idx % perRack) * 4); }
    });
    ledAttrsDirty();
    if (chartBodies.instanceColor) chartBodies.instanceColor.needsUpdate = true;
    litBtn.hidden = !f;
    if (f) {
      const lang = f.kind === 'lang' ? hallLangs.find(l => l.name === f.name) : null;
      litBtn.querySelector('i').style.background = lang ? lang.color : rampCss(P.ramp, (f.i + 0.5) / 20);
      litBtn.querySelector('span').textContent = (lang ? lang.name : Math.round(f.i * 5) + '-' + Math.round(f.i * 5 + 5) + '% of the leader') + ' · ' + n + ' lit · clear';
      litBtn.setAttribute('aria-label', 'Clear the light on ' + (lang ? lang.name : 'that band') + ' (' + n + ' entries)');
      live.textContent = n + ' entr' + (n === 1 ? 'y' : 'ies') + ' lit up.';
    }
    nocDue('langs', 'hist');
    invalidate();
  }

  /* the drawer chart: every unit slides out by a measure, the racks become a bar chart */
  function chartLabel() {
    if (!chart) return '';
    if (chart.kind === 'test') return tests[chart.i] ? tests[chart.i].label : 'a test';
    return { score: metric.toLowerCase(), cpu: 'CPU', mem: 'memory', p99: 'p99 latency' }[chart.kind] || chart.kind;
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
  function setChart(c) {
    if (c && (c.kind === 'off' || (chart && c.kind === chart.kind && c.i === chart.i))) c = null;
    const was = chart;
    if (popped) unpop(false);
    chart = c;
    chartBodies.visible = !!chart;
    const col = new THREE.Color();
    units.forEach((u, idx) => {
      const v = chart ? chartValue(u, chart) : null;
      u.chartV = v;
      u.chartS = chart && v != null ? 0.012 + v * (CHART_MAX - 0.012) : 0;
      if (chart) chartBodies.setColorAt(u.i, chartColor(u, col));
      faceGlow(u);
      u.body.visible = false;
      slideTo(u, restSlide(u), 620, easeOut, () => { if (chart) placeChartBody(u); }, reduced ? 0 : idx * 6);
      placeChartBody(u);
    });
    if (chartBodies.instanceColor) chartBodies.instanceColor.needsUpdate = true;
    for (const b of root.querySelectorAll('[data-pull]')) b.setAttribute('aria-pressed', String(chart ? b.dataset.pull === chart.kind : b.dataset.pull === 'off'));
    if (pullSel) { pullSel.value = chart && chart.kind === 'test' ? String(chart.i) : ''; pullSel.classList.toggle('on', !!(chart && chart.kind === 'test')); }
    if (pullAll) { pullAll.value = !chart ? 'off' : chart.kind === 'test' ? 't' + chart.i : chart.kind; pullAll.classList.toggle('on', !!chart); }
    if (chart && !was) { aligned = -1; atOverview = false; flyTo(chartView(), 1300); }
    live.textContent = chart ? 'Every drawer pulled out by ' + chartLabel() + '.' : 'The drawers slid back in.';
    nocDue('view', 'tests');
    hideTips();
    invalidate();
  }

  /* find a framework */
  let findSel = 0, findList = [];
  function renderFind() {
    const q = findIn.value.trim().toLowerCase();
    if (!q) { findRes.classList.remove('on'); findList = []; return; }
    findList = units.filter(u => u.fw.toLowerCase().includes(q)).sort((a, b) => (a.fw.toLowerCase().indexOf(q) - b.fw.toLowerCase().indexOf(q)) || a.rank - b.rank).slice(0, 8);
    findSel = 0;
    findRes.innerHTML = findList.length
      ? findList.map((u, i) => '<li role="option" data-fw="' + esc(u.fw) + '"' + (i === 0 ? ' class="sel" aria-selected="true"' : '') + '><i style="background:' + esc(u.langColor) + '"></i><b>' + esc(u.fw) + '</b><small>#' + esc(u.rank) + ' · R' + (u.rack + 1) + '</small></li>').join('')
      : '<li class="none">No framework matches that</li>';
    findRes.classList.add('on');
  }
  function moveFind(d) {
    if (!findList.length) return;
    findSel = (findSel + d + findList.length) % findList.length;
    findRes.querySelectorAll('li').forEach((li, i) => { li.classList.toggle('sel', i === findSel); li.setAttribute('aria-selected', String(i === findSel)); });
  }
  function chooseFind(fw) {
    const u = byFw.get(fw);
    findIn.value = ''; findRes.classList.remove('on'); findList = [];
    findIn.blur();
    if (u) { endTour(); pop(u); }
  }

  /* moving through the aisle */
  function navIdx(dir) {
    if (atOverview) return dir > 0 ? 0 : -1;
    if (aligned >= 0) { const k = aligned + dir; return k >= 0 && k < nR ? k : -1; }
    const tx = controls.target.x;
    if (dir > 0) { for (let k = 0; k < nR; k++) if (rackX(k) >= tx - 0.15) return k; return -1; }
    for (let k = nR - 1; k >= 0; k--) if (rackX(k) <= tx + 0.15) return k;
    return -1;
  }
  function goRack(k) {
    if (k < 0 || k >= nR) return;
    if (popped) unpop(false);
    aligned = k; atOverview = false;
    flyTo(rackView(k));
    updateHud();
  }
  function goWall() {
    if (popped) unpop(false);
    aligned = -1; atOverview = false;
    flyTo(wallView(), 1300);
  }
  function resetView() {
    if (popped) unpop(false);
    aligned = -1; atOverview = true;
    flyTo(overview(), 1000);
  }
  let hudRack = -2, hudPrev = null, hudNext = null, hudWall = null;
  function updateHud() {
    let k = 0, best = Infinity;
    for (let i = 0; i < nR; i++) { const d = Math.abs(rackX(i) - controls.target.x); if (d < best) { best = d; k = i; } }
    const atWall = controls.target.x > rowX1 + 1.4;
    if (atOverview || atWall) k = -1;
    if (k !== hudRack) { hudRack = k; chipEls.forEach((c, i) => { c.classList.toggle('on', i === k); c.setAttribute('aria-current', i === k ? 'true' : 'false'); }); }
    if (atWall !== hudWall) { hudWall = atWall; wallChip.classList.toggle('on', atWall); }
    const p = navIdx(-1) < 0, n = navIdx(1) < 0;
    if (p !== hudPrev) { hudPrev = p; btn.prev.disabled = p; }
    if (n !== hudNext) { hudNext = n; btn.next.disabled = n; }
  }
  const _t0 = new THREE.Vector3(), _c0 = new THREE.Vector3();
  function clampView() {
    const t = controls.target, c = camera.position;
    _t0.copy(t); _c0.copy(c);
    t.x = clamp(t.x, rowX0 - 0.35, WALL_X - 0.02); t.y = clamp(t.y, 0.12, RACK_H + 0.6); t.z = clamp(t.z, -0.3, OPP_Z - 0.25);
    c.x = clamp(c.x, endL + 0.4, WALL_X - 0.3); c.y = clamp(c.y, 0.1, CEIL - 0.22); c.z = clamp(c.z, 0.1, OPP_Z - 0.3);
    if (!t.equals(_t0) || !c.equals(_c0)) camera.lookAt(t);
  }

  const keys = new Set();
  const MOVE = { ArrowLeft: 'l', KeyA: 'l', ArrowRight: 'r', KeyD: 'r', ArrowUp: 'f', KeyW: 'f', ArrowDown: 'b', KeyS: 'b', KeyQ: 'd', KeyE: 'u' };
  const fwd = new THREE.Vector3(), side = new THREE.Vector3(), mv = new THREE.Vector3(), UP = new THREE.Vector3(0, 1, 0);
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
    if (mv.lengthSq() === 0) return false;
    mv.normalize().multiplyScalar((fast ? 2.4 : 1.05) * dt);
    camera.position.add(mv); controls.target.add(mv);
    return true;
  }

  /* the operations wall's screens repaint when what they show changes */
  const selU = () => popped || hovered || null;
  const nocData = () => ({ units, metric, leader: hall.leader, sel: selU(), bin: filter && filter.kind === 'bin' ? filter.i : null, view: world.view ? String(world.view) : o.title || 'The aisle',
    round: world.round ? String(world.round) : '', racks: nR, tests: nT, langs: hallLangs, lit: filter && filter.kind === 'lang' ? filter.name : null, leaderU: units[0] || null,
    pull: chart ? chartLabel() : '', family, chart: chart && chart.kind === 'test' ? chart.i : null, machine });
  let nocLast = 0;
  function nocDue(...ids) { for (const id of ids) noc[id].due = true; invalidate(); }
  function paintNoc(id) {
    const n = noc[id], ctx = n.cv.getContext('2d');
    ctx.setTransform(NOC_W / 1280, 0, 0, NOC_W / 1280, 0, 0);
    const pc = { width: 1280, height: 720, getContext: () => ctx }, d = nocData();
    n.hits = (id === 'hist' ? nocHist(pc, NC, P, d) : id === 'langs' ? nocLangs(pc, NC, d) : id === 'tests' ? nocTests(pc, NC, Object.assign({}, d, { tests })) : null) || [];
    if (id === 'view') nocView(pc, NC, d); else if (id === 'machine') nocMachine(pc, NC, d); else if (id === 'sel') nocSel(pc, NC, P, d);
    n.t.needsUpdate = true; n.due = false;
  }
  function nocTick(now) {
    let pending = false;
    for (const id in noc) {
      if (!noc[id].due) continue;
      if ((id === 'sel' || id === 'hist') && now - nocLast < 140 && nocLast) { pending = true; continue; }
      paintNoc(id);
      if (id === 'sel' || id === 'hist') nocLast = now;
    }
    return pending;
  }

  /* the tour: a short walk past the notable units */
  let tour = null, tourTimer = 0;
  function buildTour() {
    const s = [];
    s.push({ view: overview, title: world.view ? String(world.view) : o.title || 'The aisle', text: units.length + ' entries in ' + nR + ' rack' + (nR === 1 ? '' : 's') + ', best first. Every light, fan and gauge is a measurement: point at one to read it.' });
    if (units[0]) s.push({ u: units[0], title: 'The leader', text: units[0].fw + ' leads with ' + units[0].score + (units[0].lang ? ', written in ' + units[0].lang : '') + '. Its lid is off: a chip per test, a CPU that glows with its load, a stick of memory per step of its footprint.' });
    for (const l of hallLangs.slice(0, 3)) if (l.best !== units[0]) s.push({ u: l.best, title: 'Best in ' + l.name, text: l.best.fw + ' is the best of the ' + l.n + ' ' + l.name + ' entr' + (l.n === 1 ? 'y' : 'ies') + ', at #' + l.best.rank + '.' });
    const lo = (k, f) => units.filter(u => u[k] != null).sort((a, b) => a[k] - b[k] || a.rank - b.rank)[0];
    const fast = lo('p99'), lean = lo('mem');
    if (fast) s.push({ u: fast, title: 'The fastest p99', text: fast.fw + ' answers 99% of its requests within ' + fmtMs(fast.p99) + (fast.runFrom === 'tests' ? ' (its median across tests)' : '') + '.' });
    if (lean && lean !== fast) s.push({ u: lean, title: 'The leanest', text: lean.fw + ' gets by on ' + fmtMem(lean.mem) + ' of memory: one stick in its open chassis.' });
    if (units.length >= 3) s.push({ view: podiumView, title: 'The podium', text: 'The top three in front of the wall: ' + units.slice(0, 3).map(u => u.fw).join(', ') + '. Each block carries its unit in miniature, its own panel on its front.' });
    s.push({ wall: true, title: 'The operations wall', text: 'The hall at a glance. Click a language or a bar to light its units, or a test to pull every drawer out by it.' });
    return s;
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
    else { if (popped) unpop(false); if (st.wall) goWall(); else { atOverview = st.view === overview; aligned = -1; flyTo(st.view(), 1300); } }
    tour.busy = false;
    if (motion) tourTimer = setTimeout(() => nextStop(), 9000);
  }
  function startTour() { endTour(); tour = { stops: buildTour(), i: 0 }; showStop(); }
  function nextStop() { if (!tour) return; tour.i++; if (tour.i >= tour.stops.length) { endTour(); resetView(); return; } showStop(); }
  function endTour() { clearTimeout(tourTimer); tourTimer = 0; if (!tour) return; tour = null; capEl.hidden = true; }

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
    for (const p of podium) {
      p.mini.rotation.y = motion ? -Math.PI / 2 + Math.sin(T.value * 0.45 + p.phase) * 0.9 : -Math.PI / 2;
      p.mini.position.y = p.base + (motion ? Math.sin(T.value * 1.3 + p.phase) * 0.008 : 0);
    }
    for (const m of mqs) m.mesh.material.uniforms.uShift.value = motion ? Math.floor(T.value * m.speed) % (m.w + MQ_COLS) : MQ_COLS;
    if (inside.visible && openU) {
      const f = 1.5 + 16 * (openU.rpsN || 0), on = openU.rps ? (motion ? (Math.sin(T.value * f * 6.283) + Math.sin(T.value * f * 4.1) > 0 ? 1 : 0.15) : 1) : 0.1;
      nicLed[0].material.color.copy(cA).multiplyScalar(on * (dark ? 1.4 : 1));
      if (holo.visible) { holo.getWorldPosition(_cw); holo.rotation.y = Math.atan2(camera.position.x - _cw.x, camera.position.z - _cw.z); }
    }
    return nocTick(now);
  }

  /* the loop: on demand while still; with motion on, the room's own motion at ~30 fps */
  let raf = 0, lastT = 0, renders = 0, shiftKey = false, dirty = true, lastDraw = 0;
  // a slow machine finds out in the first second of motion: fewer pixels, no mirror
  const probe = { n: 0, slow: 0, done: reduced };
  function lighten() {
    if (mirror) { for (const k of mirror.ks) k.value = 0; mirror.rt.dispose(); bin.delete(mirror.rt); mirror = null; }
    renderer.setPixelRatio(Math.max(1, renderer.getPixelRatio() * 0.7));
    renderer.setSize(vw(), vh(), false);
  }
  function invalidate() { dirty = true; if (!raf && !disposed) raf = requestAnimationFrame(frame); }
  function frame(now) {
    raf = 0;
    if (disposed) return;
    const dt = lastT ? Math.min(0.05, (now - lastT) / 1000) : 1 / 60;
    if (!probe.done && lastT && ++probe.n > 10) {
      if (now - lastT > 26) probe.slow++;
      if (probe.n >= 70) { probe.done = true; if (probe.slow > 36) lighten(); }
    }
    lastT = now;
    const ambient = motion && !document.hidden;
    if (ambient) T.value += dt;
    let more = runTweens(now);
    if (keys.size) { if (walk(dt, shiftKey)) { stopCam(); aligned = -1; atOverview = false; } more = true; }
    if (controls.update()) more = true;
    clampView();
    const must = dirty || more;
    dirty = false;
    if (!must && ambient && now - lastDraw < 31) { raf = requestAnimationFrame(frame); return; }
    camera.updateMatrixWorld();
    updateHud();
    if (tick(now)) more = true;
    if (mirror) renderMirror();
    renderer.render(scene, camera);
    renders++; lastDraw = now;
    if (more || ambient) { if (!raf) raf = requestAnimationFrame(frame); } else lastT = 0;
  }
  controls.addEventListener('change', invalidate);
  controls.addEventListener('start', () => { stopCam(); aligned = -1; atOverview = false; hideTips(); endTour(); });
  const onVis = () => { if (!document.hidden) invalidate(); };
  document.addEventListener('visibilitychange', onVis);

  /* input */
  let down = null, pendingMove = null, moveRaf = 0;
  function onDown(e) {
    down = { x: e.clientX, y: e.clientY, t: performance.now(), b: e.button, moved: false };
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
      cv.classList.toggle('hot', !!(hit && (hit.u || hit.act)));
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
    if (hit.act) {
      endTour();
      if (hit.act.kind === 'lang' || hit.act.kind === 'bin') setFilter(hit.act);
      else if (hit.act.kind === 'test') setChart({ kind: 'test', i: hit.act.i });
      hideTips();
      return;
    }
    if (!hit.u) return;
    if (hit.region.kind === 'loc') { toggleFav(hit.u); showTips(hit, e.clientX, e.clientY); return; }
    endTour();
    if (popped === hit.u) unpop(); else pop(hit.u);
  }
  function onLeave() { if (!down) { setHover(null); hideTips(); } }
  function onWheel() { hideTips(); }
  function onKey(e) {
    if (disposed) return;
    const tg = e.target;
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
      if (e.key === 'Enter') { e.preventDefault(); e.stopImmediatePropagation(); if (findList[findSel]) chooseFind(findList[findSel].fw); return; }
      if (e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); if (findIn.value) { findIn.value = ''; renderFind(); } else findIn.blur(); return; }
      return;
    }
    if (e.key === 'Escape') {
      e.preventDefault(); e.stopImmediatePropagation();
      if (tour) { endTour(); return; }
      if (popped) unpop(); else if (!keysEl.hidden) toggleKeys(false); else closeSelf();
      return;
    }
    if (tg && (tg.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(tg.tagName || ''))) return;
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === ']' || e.key === 'PageDown') { e.preventDefault(); e.stopImmediatePropagation(); endTour(); goRack(navIdx(1)); return; }
    if (e.key === '[' || e.key === 'PageUp') { e.preventDefault(); e.stopImmediatePropagation(); endTour(); goRack(navIdx(-1)); return; }
    if (e.key === 'Home') { e.preventDefault(); e.stopImmediatePropagation(); endTour(); resetView(); return; }
    if (e.key === '/' ) { e.preventDefault(); e.stopImmediatePropagation(); findIn.focus(); return; }
    if (MOVE[e.code]) {
      if (tg instanceof Node && panel.contains(tg)) return;   // let the card scroll
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
    const a = e.target.closest('[data-act],[data-rack],[data-close],[data-pull]');
    if (!a || !root.contains(a)) return;
    if (a.hasAttribute('data-close')) { e.preventDefault(); unpop(); return; }
    if (a.hasAttribute('data-rack')) { endTour(); goRack(+a.getAttribute('data-rack')); return; }
    if (a.hasAttribute('data-pull') && a.tagName === 'BUTTON') { endTour(); setChart({ kind: a.dataset.pull }); return; }
    const act = a.getAttribute('data-act');
    if (act === 'prev') { endTour(); goRack(navIdx(-1)); }
    else if (act === 'next') { endTour(); goRack(navIdx(1)); }
    else if (act === 'reset') { endTour(); resetView(); }
    else if (act === 'wall') { endTour(); goWall(); }
    else if (act === 'close') closeSelf();
    else if (act === 'motion') setMotion(!motion);
    else if (act === 'tour') { if (tour) endTour(); else startTour(); }
    else if (act === 'tour-next') nextStop();
    else if (act === 'tour-stop') endTour();
    else if (act === 'unlit') setFilter(null);
    else if (act === 'keys') toggleKeys(keysEl.hidden);
    else if (act === 'keys-hide') toggleKeys(false);
  }
  locBtn.addEventListener('click', () => { if (popped) toggleFav(popped); });
  if (pullSel) pullSel.addEventListener('change', () => { endTour(); if (pullSel.value === '') { if (chart && chart.kind === 'test') setChart(null); } else setChart({ kind: 'test', i: +pullSel.value }); pullSel.blur(); });
  if (pullAll) pullAll.addEventListener('change', () => { endTour(); const v = pullAll.value; setChart(v === 'off' ? null : v[0] === 't' && v !== 'off' && !isNaN(+v.slice(1)) ? { kind: 'test', i: +v.slice(1) } : { kind: v }); pullAll.blur(); });
  findIn.addEventListener('input', renderFind);
  findIn.addEventListener('focus', () => { if (findIn.value) renderFind(); });
  findRes.addEventListener('pointerdown', e => e.preventDefault());
  findRes.addEventListener('click', e => { const li = e.target.closest('li[data-fw]'); if (li) chooseFind(li.dataset.fw); });
  cv.addEventListener('pointerdown', onDown);
  cv.addEventListener('pointermove', onMove);
  cv.addEventListener('pointerup', onUp);
  cv.addEventListener('pointercancel', () => { down = null; cv.classList.remove('drag'); });
  cv.addEventListener('pointerleave', onLeave);
  cv.addEventListener('wheel', onWheel, { passive: true });
  root.addEventListener('click', onClick);
  // the page behind does not scroll under the room; the card and the matches scroll on their own
  root.addEventListener('wheel', e => { if (!pbody.contains(e.target) && !findRes.contains(e.target)) e.preventDefault(); }, { passive: false });
  window.addEventListener('keydown', onKey, true);
  window.addEventListener('keyup', onKeyUp, true);
  window.addEventListener('blur', onBlur);
  const ro = new ResizeObserver(() => {
    if (disposed) return;
    renderer.setSize(vw(), vh(), false);
    sizeMirror();
    if (popped) { const S = reserve(); if (!shiftTw) { shift.x = S.x; shift.y = S.y; } }
    applyView();
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
    clearTimeout(tourTimer);
    tweens.clear();
    window.removeEventListener('keydown', onKey, true);
    window.removeEventListener('keyup', onKeyUp, true);
    window.removeEventListener('blur', onBlur);
    document.removeEventListener('visibilitychange', onVis);
    ro.disconnect();
    controls.dispose();
    if (!inside.parent) scene.add(inside);
    scene.traverse(ob => {
      if (ob.geometry) bin.add(ob.geometry);
      const ms = Array.isArray(ob.material) ? ob.material : ob.material ? [ob.material] : [];
      for (const m of ms) {
        bin.add(m);
        for (const k of Object.keys(m)) { const v = m[k]; if (v && v.isTexture) bin.add(v); }
        if (m.uniforms) for (const k in m.uniforms) { const v = m.uniforms[k] && m.uniforms[k].value; if (v && v.isTexture) bin.add(v); }
      }
    });
    for (const u of units) { if (u.hi) { bin.add(u.hi.tf); bin.add(u.hi.tl); } if (u.fx) for (const m of u.fx) bin.add(m.material); }
    const texList = Array.from(bin).filter(x => x.isTexture);
    for (const x of bin) { try { x.dispose(); } catch (e) { /* already gone */ } }
    bin.clear();
    if (envRT) envRT.dispose();
    scene.environment = null;
    renderer.renderLists.dispose();
    renderer.dispose();
    try { renderer.forceContextLoss(); } catch (e) { /* fine */ }
    for (const c of canvases) { c.width = c.height = 0; }
    canvases.length = 0;
    for (const x of texList) { const c = x.image; if (c && c.getContext) { c.width = c.height = 0; } }
    for (const id in noc) noc[id].cv.width = noc[id].cv.height = 0;
    root.remove();
    host.classList.remove(...addedCls);
    if (!hadRole) { host.removeAttribute('role'); host.removeAttribute('aria-modal'); host.removeAttribute('aria-label'); }
  }
  function closeSelf() {
    if (disposed) return;
    dispose();
    try { if (o.onClose) o.onClose(); } catch (e) { console.error(e); }
  }

  /* first light */
  for (const id in noc) paintNoc(id);
  applyView();
  const ov = overview();
  if (reduced) { camera.position.copy(ov.pos); controls.target.copy(ov.target); }
  else {
    camera.position.copy(ov.pos).add(V(-0.55, 0.45, 0.6));
    controls.target.copy(ov.target).add(V(-0.25, 0.1, 0));
  }
  clampView();
  controls.update();
  renderer.compile(scene, camera);
  invalidate();
  msgEl.classList.add('off');
  setTimeout(() => { if (!disposed && !msgEl.classList.contains('err')) msgEl.style.display = 'none'; }, 350);
  if (!reduced) flyTo(ov, 1500);
  try { cv.focus({ preventScroll: true }); } catch (e) { /* fine */ }

  const handle = {
    close() { dispose(); },
    setFav(fw, on) { const u = byFw.get(String(fw)); if (u && !disposed) applyFav(u, on); },
    focus(fw) { const u = byFw.get(String(fw)); if (u && !disposed) { endTour(); pop(u); } },
  };
  // for tests: where things are on screen, a camera to look through, and the room's state
  Object.defineProperty(handle, '_debug', {
    enumerable: false,
    value: {
      screenOf(fw, part) {
        const u = byFw.get(String(fw)); if (!u) return null;
        const r = cv.getBoundingClientRect();
        const lx = part === 'loc' ? pxX(LY.locX) : part === 'fan' ? fanX : part === 'mem' ? pxX(1005) : part === 'act' ? pxX(LY.actX) : typeof part === 'number' ? eqX[part] : 0;
        const ly = part === 'loc' ? pxY(LY.locY) : part === 'act' ? pxY(LY.stY) : typeof part === 'number' ? eqCy : 0;
        const v = V(lx, ly, 0.0002);
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
      chart(kind, i) { setChart(kind ? { kind, i } : null); },
      filter(name) { setFilter(name ? { kind: 'lang', name } : null); },
      wall() { goWall(); },
      tour() { startTour(); },
      motion(on) { setMotion(on); },
      stats() { return { renders, popped: popped && popped.fw, hovered: hovered && hovered.fw, aligned, tweens: tweens.size, chart: chart && chart.kind, filter: filter && (filter.name || filter.i), motion, info: renderer.info.render.calls, textures: renderer.info.memory.textures, geometries: renderer.info.memory.geometries }; },
    },
  });
  return handle;
}
