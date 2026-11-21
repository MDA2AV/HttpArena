/* HttpArena - the 3D aisle.

   The aisle view as a room to walk through: every framework is a 1U unit in a
   cabinet, racked by rank (R1 from the top down, then R2, ...). Drag to look
   around, right-drag to pan, scroll to zoom, walk with WASD or the arrows, Q/E
   for down and up, [ and ] (or PageUp/PageDown) for the next cabinet. Click a
   unit and it slides out on its rails with its card beside it; click it again,
   or press Esc, and it slides back in. Esc with nothing out closes the room.

     open(opts) -> Promise<{ close(), setFav(fw, on), focus(fw) }>

   close() disposes everything and does not call onClose (the page asked for
   it); the module calls onClose only when it closed itself. It draws only
   while something moves - the camera, a unit, a tween - so an idle room costs
   the GPU nothing. */
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
const PLINTH_H = 0.07, BASE_Y = 0.1, TOP_H = 0.125, FRAME_D = 0.03;
const FACE_Z = -RECESS + PLATE_T;  // the front of a racked panel
const POP = 0.4, LIFT = 0.017;     // slid out, and lifted under the pointer
const OPP_Z = 4.2;                 // the facing row, across the aisle
const CEIL = 3.2;
const FOV = 40, DEG = Math.PI / 180;
const TW = 1024, TH = 92;          // a panel's texture (1 px ~ 0.47 mm)
const LENS = 0.0043, LENS_LOC = 0.0062, GLOW = 0.0125, GLOW_LOC = 0.024;
const LED_Z = 0.0012;

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

/* ── the two rooms: the hall at night, and the clean room ──────────────── */
const DARK = {
  exposure: 1.0, envK: 0.6, bg: 0x07090c, fogD: 0.065,
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
  ledG: '#3dff8f', ledB: '#3aa0ff', ledA: '#ffb020', ledOff: '#1b2025',
  body: 0x30353b, rail: 0x7a838c,
  plate: '#0b0e11', plateLine: '#2b3138', plateText: '#eef1f4', plateMuted: '#8e99a4', plateLit: true,
  faceEm: 0.34, faceEmHot: 0.62, ledBoost: 1.0, glowK: 1.0, decorGlowK: 0.75,
  lamp: 0xe9f3ff, lampK: 2.6, fixture: 0x1a1d21, tray: 0x2a2f35,
  door: '#111418', doorFrame: '#191c21', doorBack: '#040506', doorKit: ['#262b31', '#2f353c', '#1d2126'], rear: '#0c0e11', rearHole: '#2a3a4c', rearLit: 0.55,
  favAdd: true, favK: 0.42, favPipeK: 3.6, mirrorK: 1.0,
  sticker: '#e6e9ec', stickerText: '#14181d', lid: ['#3a4047', '#2c3137'],
  sign: '#0b0e12', signText: '#f2f4f6', signMuted: '#9da7b2', signLine: '#62c4ff', signLit: true,
};
const LIGHT = {
  exposure: 1.0, envK: 0.42, bg: 0xdde2e7, fogD: 0.04,
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
  ledG: '#16b75c', ledB: '#1c7cf0', ledA: '#e08a00', ledOff: '#a9b1b9',
  body: 0xbfc6cd, rail: 0x8e979f,
  plate: '#f6f7f8', plateLine: '#c7ced5', plateText: '#0f1318', plateMuted: '#47525e', plateLit: false,
  faceEm: 0.03, faceEmHot: 0.16, ledBoost: 1.1, glowK: 0.55, decorGlowK: 0.6,
  lamp: 0xffffff, lampK: 1.6, fixture: 0xc9cfd5, tray: 0x9aa3ac,
  door: '#363c43', doorFrame: '#30363c', doorBack: '#0d0f12', doorKit: ['#4a525b', '#58616a', '#3f464e'], rear: '#2a3036', rearHole: '#aab4be', rearLit: 0.25,
  favAdd: false, favK: 0.2, favPipeK: 1.6, mirrorK: 0.3,
  sticker: '#ffffff', stickerText: '#14181d', lid: ['#c9d0d6', '#b7bfc6'],
  sign: '#ffffff', signText: '#0f1318', signMuted: '#47525e', signLine: '#0a5cc0', signLit: false,
};

/* ── the HUD's styles, scoped to the host; the page's tokens when it has them ── */
const CSS = `
.a3d-host{--a3-bg:var(--bg,#090b0e);--a3-panel:var(--panel,#13161a);--a3-panel-2:var(--panel-2,#1a1e23);--a3-text:var(--text,#f2f4f6);--a3-text-2:var(--text-2,#c6cdd5);--a3-muted:var(--muted,#9da7b2);--a3-line:var(--line,#383f47);--a3-accent:var(--accent,#62c4ff);--a3-led-g:var(--led-g,#3dff8f);--a3-led-b:var(--led-b,#3aa0ff);--a3-led-off:var(--led-off,#2c3238);--a3-gold:var(--gold,#e3b54a);--a3-silver:var(--silver,#b6bfca);--a3-bronze:var(--bronze,#d9925c);--a3-sans:var(--sans,"Inter",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif);--a3-label:var(--label,"Saira SC","Inter",system-ui,sans-serif);--a3-shadow:0 14px 34px -12px rgba(0,0,0,.75),0 1px 2px rgba(0,0,0,.5);--a3-glass:82%}
.a3d-host.a3d-light{--a3-bg:var(--bg,#e8ebee);--a3-panel:var(--panel,#ffffff);--a3-panel-2:var(--panel-2,#f1f3f5);--a3-text:var(--text,#0f1318);--a3-text-2:var(--text-2,#313b46);--a3-muted:var(--muted,#47525e);--a3-line:var(--line,#b3bcc5);--a3-accent:var(--accent,#0a5cc0);--a3-led-g:var(--led-g,#16b75c);--a3-led-b:var(--led-b,#1c7cf0);--a3-led-off:var(--led-off,#aab2ba);--a3-gold:var(--gold,#9a7412);--a3-silver:var(--silver,#5f6975);--a3-bronze:var(--bronze,#96582a);--a3-shadow:0 14px 32px -14px rgba(20,30,45,.38),0 1px 2px rgba(20,30,45,.14);--a3-glass:86%}
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
.a3d-btn:focus-visible{outline:2px solid var(--a3-accent);outline-offset:2px}
.a3d-btn:disabled{opacity:.42;cursor:default;border-color:var(--a3-line)}
.a3d-btn svg{width:16px;height:16px;flex:none;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
.a3d-chips{display:flex;gap:4px}
.a3d-chip{padding:0 10px;gap:6px}
.a3d-chip small{font-size:12px;font-weight:500;color:var(--a3-muted);font-variant-numeric:tabular-nums}
.a3d-chip.on{border-color:var(--a3-accent);background:color-mix(in srgb,var(--a3-accent) 16%,var(--a3-panel-2))}
.a3d-sep{width:1px;height:22px;background:var(--a3-line);margin:0 3px;flex:none}
.a3d-help{position:absolute;left:16px;bottom:14px;max-width:calc(100% - 32px);display:flex;align-items:center;gap:5px 14px;flex-wrap:wrap;padding:7px 7px 7px 13px;font-size:12.5px;line-height:1.5;color:var(--a3-text-2);z-index:2}
.a3d-help>span{white-space:nowrap}
.a3d-help kbd{display:inline-block;min-width:21px;text-align:center;font:600 12px/1 var(--a3-sans);padding:3px 5px 2px;margin:0 1px;border:1px solid var(--a3-line);border-bottom-width:2px;border-radius:5px;background:var(--a3-panel-2);color:var(--a3-text)}
.a3d-help .a3d-btn{height:28px;padding:0 10px;font-size:12px}
.a3d-tip{position:absolute;left:0;top:0;z-index:6;pointer-events:none;max-width:320px;padding:9px 12px 10px;font-size:13px;line-height:1.45;color:var(--a3-text-2);opacity:0;visibility:hidden;transition:opacity .1s ease}
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
.a3d-tt-k{margin-top:6px;font-size:12px;color:var(--a3-muted)}
.a3d-tt-fav{color:var(--a3-led-b);font-weight:600}
.a3d-panel{position:absolute;top:76px;right:16px;bottom:16px;width:min(420px,calc(100% - 32px));display:flex;flex-direction:column;z-index:4;transform:translateX(calc(100% + 28px));visibility:hidden;transition:transform .34s cubic-bezier(.2,.8,.2,1),visibility 0s linear .34s}
.a3d-panel.on{transform:none;visibility:visible;transition:transform .34s cubic-bezier(.2,.8,.2,1),visibility 0s}
.a3d-pbar{display:flex;align-items:center;gap:8px;padding:10px 10px 10px 12px;border-bottom:1px solid var(--a3-line);flex:none}
.a3d-pbar .a3d-sp{flex:1}
.a3d-loc i{width:10px;height:10px;border-radius:50%;flex:none;background:var(--a3-led-off);box-shadow:inset 0 0 0 1px rgba(0,0,0,.35)}
.a3d-loc[aria-pressed="true"]{border-color:var(--a3-led-b)}
.a3d-loc[aria-pressed="true"] i{background:var(--a3-led-b);box-shadow:0 0 0 1px rgba(0,0,0,.2),0 0 10px 2px var(--a3-led-b)}
.a3d-pbody{flex:1;min-height:0;overflow:auto;overscroll-behavior:contain;touch-action:pan-y;padding:14px;user-select:text;-webkit-user-select:text}
.a3d-msg{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;padding:24px;text-align:center;font-size:14px;color:var(--a3-muted);z-index:7;pointer-events:none;transition:opacity .3s ease}
.a3d-msg.off{opacity:0}
.a3d-msg.err{pointer-events:auto;background:var(--a3-bg)}
.a3d-live{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);clip-path:inset(50%);white-space:nowrap}
@media (max-width:760px){
  .a3d-top{left:10px;right:10px;top:10px;gap:6px}
  .a3d-title{padding:7px 12px 8px}
  .a3d-title b{font-size:15px}
  .a3d-title span{display:none}
  .a3d-nav{padding:4px;gap:4px}
  .a3d-panel{top:auto;left:10px;right:10px;bottom:10px;width:auto;max-height:56%;transform:translateY(calc(100% + 24px))}
  .a3d-help{display:none}
  .a3d-nav .a3d-bt{display:none}
  .a3d-nav .a3d-btn{padding:0 10px}
  .a3d-chip small{display:none}
}
@media (prefers-reduced-motion:reduce){.a3d-panel,.a3d-panel.on,.a3d-tip,.a3d-btn,.a3d-msg{transition:none}}
`;

const ICON = {
  prev: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 18l-6-6 6-6"/></svg>',
  next: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 18l6-6-6-6"/></svg>',
  reset: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 12a9 9 0 1 0 2.6-6.4"/><path d="M3 4v5h5"/></svg>',
  close: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M18 6L6 18M6 6l12 12"/></svg>',
  back: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 19V5"/><path d="M5 12l7-7 7 7"/></svg>',
};

/* ── the LEDs: one instanced quad each, a lens and, additive, its glow ── */
const LED_VS = `
attribute vec3 aColor;
attribute float aLevel;
attribute float aHot;
varying vec2 vUv;
varying vec3 vColor;
varying float vLevel;
varying float vHot;
#include <fog_pars_vertex>
void main() {
  vUv = uv; vColor = aColor; vLevel = aLevel; vHot = aHot;
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
#include <fog_pars_fragment>
void main() {
  vec2 c = vUv * 2.0 - 1.0;
  float d = length(c);
  float aa = max(fwidth(d), 0.02);
  float a = 1.0 - smoothstep(1.0 - aa, 1.0, d);
  if (a <= 0.0) discard;
  float on = step(0.0, vLevel);
  float L = 0.18 + 0.82 * clamp(vLevel, 0.0, 1.0);
  vec3 lit = vColor * uBoost * (0.26 + 1.12 * L);
  vec3 col = mix(uOff, lit, on);
  float core = on * vHot * (1.0 - smoothstep(0.0, 0.66, d));
  col = mix(col, vec3(1.0, 1.0, 0.95) * uBoost * 2.2, core);
  col *= mix(0.62, 1.0, 1.0 - smoothstep(0.5, 1.0, d));
  float spec = 1.0 - smoothstep(0.0, 0.34, length(c - vec2(-0.34, 0.4)));
  col += vec3(spec * mix(0.22, 0.12, on));
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
#include <fog_pars_fragment>
void main() {
  if (vLevel < 0.0) discard;
  vec2 c = vUv * 2.0 - 1.0;
  float d2 = dot(c, c);
  if (d2 > 1.0) discard;
  float L = 0.18 + 0.82 * clamp(vLevel, 0.0, 1.0);
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
function layout(n) {
  const L = { n, locX: 17, cy: 46, rankX: 79, lang: [112, 236], nameX: 248, lcdY: [16, 76] };
  if (n > 0) {
    L.lcd = [834, 974];
    L.sp = Math.min(19, 300 / n);
    L.ledX0 = L.lcd[0] - 16 - n * L.sp;
    L.nameEnd = L.ledX0 - 10;
  } else {
    L.lcd = [778, 974];
    L.nameEnd = L.lcd[0] - 18;
  }
  return L;
}
const pxX = px => (px / TW - 0.5) * PANEL_W;
const pxY = py => (0.5 - py / TH) * UNIT_H;

/* ── textures ──────────────────────────────────────────────────────────── */
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
  // the ears, a step in the panel
  ctx.fillStyle = P.ear; ctx.fillRect(0, 0, 34, H); ctx.fillRect(990, 0, 34, H);
  ctx.fillStyle = P.earSeam; ctx.fillRect(34, 0, 1.5, H); ctx.fillRect(988.5, 0, 1.5, H);
  // bevel: a highlight along the top, a shadow along the bottom
  ctx.fillStyle = P.faceHi; ctx.fillRect(0, 0, W, 1.6);
  ctx.fillStyle = P.faceLo; ctx.fillRect(0, H - 2, W, 2);
  // the locator button's bezel (its LED is a lens of its own)
  ctx.fillStyle = 'rgba(0,0,0,.35)'; circle(ctx, L.locX, cy + 1, 12.5); ctx.fill();
  ctx.fillStyle = P.ledRim; circle(ctx, L.locX, cy, 11.5); ctx.fill();
  ctx.fillStyle = P.ledHole; circle(ctx, L.locX, cy, 9); ctx.fill();
  // a captive thumbscrew on the right ear
  screwHead(ctx, 1007, cy, 8.5, P);
  // a tuned entry wears hazard stripes at both ends of its panel
  if (u.tuned) { hazard(ctx, 37.5, 2, 9, H - 4); hazard(ctx, 977.5, 2, 9, H - 4); }
  // the service label: the rank, gold, silver and bronze for the first three
  const rk = String(u.rank);
  const pl = RANK_PLATES[u.rank];
  if (pl) {
    const x = L.rankX - 24, y = 19, w = 48, h = 54;
    ctx.save(); ctx.shadowColor = 'rgba(0,0,0,.45)'; ctx.shadowBlur = 4; ctx.shadowOffsetY = 1.5;
    g = ctx.createLinearGradient(x, y, x + w, y + h);
    g.addColorStop(0, pl[0]); g.addColorStop(0.55, pl[1]); g.addColorStop(1, pl[2]);
    ctx.fillStyle = g; rrect(ctx, x, y, w, h, 3); ctx.fill(); ctx.restore();
    ctx.fillStyle = 'rgba(255,255,255,.6)'; ctx.fillRect(x + 2, y + 1, w - 4, 1.2);
    ctx.font = '700 30px ' + FONT_SANS; ctx.textAlign = 'center'; ctx.fillStyle = pl[3];
    ctx.fillText(rk, L.rankX, centreY(ctx, rk, cy));
  } else {
    const f = fit(ctx, rk, '600', FONT_SANS, 27, 18, 56);
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
    const f = fit(ctx, u.lang.toUpperCase(), '600', FONT_LABEL, 22, 14, x1 - x0 - 22);
    ctx.font = '600 ' + f.px + 'px ' + FONT_LABEL; ctx.textAlign = 'left'; ctx.fillStyle = P.langText;
    ctx.fillText(f.text, x0 + 14, centreY(ctx, 'H', cy));
    spacing(ctx, '0px');
  }
  // the name plate
  const nameW = L.nameEnd - L.nameX - 18;
  const f = fit(ctx, u.fw, '600', FONT_LABEL, 34, 22, nameW);
  ctx.font = '600 ' + f.px + 'px ' + FONT_LABEL; ctx.textAlign = 'left';
  ctx.fillStyle = u.fav ? P.nameFav : P.name;
  ctx.fillText(f.text, L.nameX, centreY(ctx, 'H', cy));
  // the entry's type, a small square at the end of the plate
  if (TYPE_COLORS[u.type]) { ctx.fillStyle = TYPE_COLORS[u.type]; rrect(ctx, L.nameEnd - 10, cy - 4.5, 9, 9, 1.5); ctx.fill(); }
  // the LED row: a hole per test; the LEDs themselves are lenses in front of it
  for (let t = 0; t < L.n; t++) {
    const x = L.ledX0 + L.sp * (t + 0.5);
    ctx.fillStyle = P.ledRim; circle(ctx, x, cy + 0.6, 6.4); ctx.fill();
    ctx.fillStyle = P.ledHole; circle(ctx, x, cy, 5.6); ctx.fill();
  }
  // the display's bezel (the display is a part of its own, lit)
  const [l0, l1] = L.lcd, [y0, y1] = L.lcdY;
  ctx.fillStyle = P.lcdBezel; rrect(ctx, l0 - 4, y0 - 4, l1 - l0 + 8, y1 - y0 + 8, 3); ctx.fill();
  ctx.fillStyle = P.faceHi; ctx.globalAlpha = 0.5; ctx.fillRect(l0 - 3, y1 + 3.4, l1 - l0 + 6, 1); ctx.globalAlpha = 1;
}

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

function drawLid(cv, u, P) {
  const ctx = cv.getContext('2d');
  const W = cv.width, H = cv.height;  // the canvas' top is the back of the chassis
  let g = ctx.createLinearGradient(0, 0, W, 0);
  g.addColorStop(0, P.lid[1]); g.addColorStop(0.5, P.lid[0]); g.addColorStop(1, P.lid[1]);
  ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
  const r = rng(hash(u.fw) ^ 0x9e37);
  for (let y = 0; y < H; y += 2) { ctx.globalAlpha = 0.04 * r(); ctx.fillStyle = r() < 0.5 ? '#fff' : '#000'; ctx.fillRect(0, y, W, 1); }
  ctx.globalAlpha = 1;
  // a seam across, where the lid's front section lifts off
  ctx.fillStyle = 'rgba(0,0,0,.35)'; ctx.fillRect(0, H * 0.34, W, 2);
  // vent slots along the front edge
  ctx.fillStyle = 'rgba(0,0,0,.55)';
  for (let row = 0; row < 3; row++) for (let i = 0; i < 18; i++) { rrect(ctx, 24 + i * 26.5, H - 64 + row * 16, 18, 7, 3.5); ctx.fill(); }
  // corner screws
  for (const [x, y] of [[16, 16], [W - 16, 16], [16, H - 16], [W - 16, H - 16], [16, H * 0.34 + 14], [W - 16, H * 0.34 + 14]]) screwHead(ctx, x, y, 6, P);
  // the service tag
  const sx = 30, sy = H * 0.4, sw = W - 60, sh = 250;
  ctx.save(); ctx.shadowColor = 'rgba(0,0,0,.4)'; ctx.shadowBlur = 6; ctx.shadowOffsetY = 2;
  ctx.fillStyle = P.sticker; rrect(ctx, sx, sy, sw, sh, 8); ctx.fill(); ctx.restore();
  ctx.fillStyle = u.langColor; ctx.fillRect(sx, sy + 14, 8, sh - 28);
  ctx.textAlign = 'left'; ctx.fillStyle = P.stickerText;
  let f = fit(ctx, u.fw, '700', FONT_LABEL, 60, 28, sw - 50);
  ctx.font = '700 ' + f.px + 'px ' + FONT_LABEL; ctx.fillText(f.text, sx + 26, sy + 66);
  const meta = [u.lang, TYPE_NAMES[u.type], u.tuned ? 'Tuned' : ''].filter(Boolean).join(' · ');
  f = fit(ctx, meta, '500', FONT_SANS, 32, 18, sw - 50);
  ctx.font = '500 ' + f.px + 'px ' + FONT_SANS; ctx.fillStyle = 'rgba(20,24,29,.78)'; ctx.fillText(f.text, sx + 26, sy + 118);
  ctx.font = '600 32px ' + FONT_SANS; ctx.fillStyle = P.stickerText;
  ctx.fillText('Rank ' + u.rank + (u.score ? '  ·  ' + u.score : ''), sx + 26, sy + 166);
  // a barcode, for the look of it
  const rb = rng(hash(u.fw));
  let x = sx + 26;
  ctx.fillStyle = P.stickerText;
  while (x < sx + sw - 30) { const w = 1.5 + Math.floor(rb() * 3) * 1.5; ctx.fillRect(x, sy + 190, w, 40); x += w + 1.5 + Math.floor(rb() * 3) * 1.5; }
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

function pduTexture(P, dark) {
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

/* ── open ──────────────────────────────────────────────────────────────── */
export async function open(opts) {
  const o = opts || {};
  const host = o.host;
  if (!host) throw new Error('aisle3d: open() needs opts.host');
  const dark = o.theme !== 'light';
  const P = dark ? DARK : LIGHT;
  const reduced = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  const tests = Array.isArray(o.tests) ? o.tests : [];
  const nT = tests.length;
  const perRack = Math.max(1, Math.floor(+o.perRack) || 42);
  const LY = layout(nT);
  const units = (Array.isArray(o.units) ? o.units : []).map((s, i) => ({
    i, fw: String(s.fw), rank: s.rank != null ? s.rank : i + 1, lang: s.lang ? String(s.lang) : '',
    langColor: s.langColor || '#8b96a3', type: s.type || '', tuned: !!s.tuned, fav: !!s.fav,
    score: s.score == null ? '' : String(s.score), share: clamp01(s.share),
    leds: Array.isArray(s.leds) ? s.leds : [], rack: Math.floor(i / perRack), slot: i % perRack,
  }));
  const byFw = new Map(units.map(u => [u.fw, u]));
  const nR = Math.max(1, Math.ceil(units.length / perRack));
  const unitsTop = BASE_Y + perRack * U, RACK_H = unitsTop + TOP_H;
  const X0 = -((nR - 1) * PITCH) / 2;
  const rackX = k => X0 + k * PITCH;
  const rowX0 = rackX(0) - PITCH / 2, rowX1 = rackX(nR - 1) + PITCH / 2;

  const bin = new Set();
  const own = x => { bin.add(x); return x; };
  const canvases = [];
  const keepCv = c => { canvases.push(c); return c; };
  let disposed = false;

  /* the HUD */
  const root = document.createElement('div');
  root.className = 'a3d';
  const chips = Array.from({ length: nR }, (_, k) => {
    const a = k * perRack + 1, b = Math.min(units.length, (k + 1) * perRack);
    return '<button type="button" class="a3d-btn a3d-chip" data-rack="' + k + '" aria-label="Go to rack R' + (k + 1) + ', units ' + a + ' to ' + b + '">R' + (k + 1)
      + (b >= a ? '<small>#' + a + (b > a ? '–' + b : '') + '</small>' : '') + '</button>';
  }).join('');
  root.innerHTML = '<style>' + CSS + '</style>'
    + '<canvas class="a3d-cv" tabindex="0" aria-label="The racks in 3D. Drag to look around, scroll to zoom."></canvas>'
    + '<div class="a3d-top"><div class="a3d-title a3d-glass"><b>' + esc(o.title || 'The aisle') + '</b>' + (o.subtitle ? '<span>' + esc(o.subtitle) + '</span>' : '') + '</div>'
    + '<div class="a3d-nav a3d-glass" role="toolbar" aria-label="Aisle navigation">'
    + '<button type="button" class="a3d-btn" data-act="prev" aria-label="Previous rack" title="Previous rack ([ or PageUp)">' + ICON.prev + '<span class="a3d-bt">Previous rack</span></button>'
    + '<div class="a3d-chips">' + chips + '</div>'
    + '<button type="button" class="a3d-btn" data-act="next" aria-label="Next rack" title="Next rack (] or PageDown)"><span class="a3d-bt">Next rack</span>' + ICON.next + '</button>'
    + '<span class="a3d-sep" aria-hidden="true"></span>'
    + '<button type="button" class="a3d-btn" data-act="reset" aria-label="Reset view" title="Reset view (Home)">' + ICON.reset + '<span class="a3d-bt">Reset view</span></button>'
    + '<button type="button" class="a3d-btn" data-act="close" aria-label="Close the 3D aisle (Esc)">' + ICON.close + '<span class="a3d-bt">Close (Esc)</span></button>'
    + '</div></div>'
    + '<div class="a3d-help a3d-glass"><span>Drag to look around</span><span>Right-drag to pan</span><span>Scroll to zoom</span>'
    + '<span><kbd>W</kbd><kbd>A</kbd><kbd>S</kbd><kbd>D</kbd> or arrows to walk, <kbd>Q</kbd><kbd>E</kbd> down and up</span>'
    + '<span><kbd>[</kbd><kbd>]</kbd> change rack</span><span>Click a unit to slide it out</span>'
    + '<button type="button" class="a3d-btn" data-act="hidehelp">Hide</button></div>'
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
  const pbody = $('.a3d-pbody'), locBtn = $('.a3d-loc'), msgEl = $('.a3d-msg'), live = $('.a3d-live'), helpEl = $('.a3d-help');
  const btn = { prev: $('[data-act="prev"]'), next: $('[data-act="next"]') };
  const chipEls = Array.from(root.querySelectorAll('.a3d-chip'));
  try { if (localStorage.getItem('a3d-help') === '0') helpEl.style.display = 'none'; } catch (e) { /* storage off: keep it */ }

  const vw = () => host.clientWidth || window.innerWidth || 1;
  const vh = () => host.clientHeight || window.innerHeight || 1;

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
    t.onUpdate = freeImage;
    return t;
  };
  const repaint = (t, w, h, draw) => { const c = canvas(w, h); draw(c); t.image = c; t.needsUpdate = true; };

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
  const hemi = new THREE.HemisphereLight(P.hemi[0], P.hemi[1], P.hemi[2]);
  scene.add(hemi);
  const sun = new THREE.DirectionalLight(P.dir[0], P.dir[1]);
  sun.position.set(rackX(0) - 2.2, 4.2, 5.2);
  sun.target.position.set((rowX0 + rowX1) / 2, 1, 0);
  scene.add(sun, sun.target);
  const nSpots = Math.min(P.spots, nR);
  for (let i = 0; i < nSpots; i++) {
    const x = nSpots === 1 ? (rowX0 + rowX1) / 2 : rowX0 + 0.3 + (rowX1 - rowX0 - 0.6) * i / (nSpots - 1);
    const sp = new THREE.SpotLight(P.spot[0], P.spot[1], 8, 0.78, 0.9, 1.6);
    sp.position.set(x, 2.95, 1.35); sp.target.position.set(x, 0.85, -0.2);
    scene.add(sp, sp.target);
  }

  // materials
  const std = (color, rough, metal, extra) => own(new THREE.MeshStandardMaterial(Object.assign({ color, roughness: rough, metalness: metal }, extra || {})));
  const M = {
    frame: std(P.frame, P.frameRough, P.frameMetal),
    inner: std(P.inner, 0.8, 0.2),
    plinth: std(P.plinth, 0.7, 0.3),
    post: std(P.post, 0.5, 0.55),
    fixture: std(P.fixture, 0.6, 0.4),
    tray: std(P.tray, 0.5, 0.15),
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
    lamp: own(new THREE.MeshBasicMaterial({ color: new THREE.Color(P.lamp).multiplyScalar(P.lampK) })),
    wire: own(new THREE.MeshBasicMaterial({ color: dark ? 0x2a2f35 : 0x8e979f })),
  };
  const postL = tex(keepCv(postTexture(P, perRack, 'right')));   // the left post's opening edge is on its right
  const postR = tex(keepCv(postTexture(P, perRack, 'left')));
  M.postFaceL = std(0xffffff, 0.5, 0.45, { map: postL });
  const rearT = tex(keepCv(rearTexture(P)), { repeat: [1, Math.max(1, Math.round(perRack / 10))] });
  M.rear = std(0xffffff, 0.75, 0.2, { map: rearT, emissiveMap: rearT, emissive: 0xffffff, emissiveIntensity: P.rearLit });
  M.pdu = std(0xffffff, 0.6, 0.3, { map: tex(keepCv(pduTexture(P, dark))) });
  M.postFaceR = std(0xffffff, 0.5, 0.45, { map: postR });

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
    strip.rotation.x = -Math.PI / 2; strip.position.set((rowX0 + rowX1) / 2, 0.0005, z);
    scene.add(strip); strips.push(strip);
  }

  const parts = new Map();
  const add = (key, g, m) => { if (!parts.has(key)) parts.set(key, []); parts.get(key).push({ g, m }); };
  const _q = new THREE.Quaternion(), _e = new THREE.Euler(), _s = new THREE.Vector3(1, 1, 1), _p = new THREE.Vector3();
  const mat4 = (x, y, z, ry = 0, rx = 0) => new THREE.Matrix4().compose(_p.set(x, y, z), _q.setFromEuler(_e.set(rx, ry, 0)), _s);
  const box = (key, base, w, h, d, x, y, z) => add(key, new THREE.BoxGeometry(w, h, d), base.clone().multiply(mat4(x, y, z)));
  const plane = (key, base, w, h, x, y, z, ry = 0, rx = 0) => add(key, new THREE.PlaneGeometry(w, h), base.clone().multiply(mat4(x, y, z, ry, rx)));

  // walls and ceiling
  const midX = (rowX0 + rowX1) / 2, endL = rowX0 - 2 * PITCH - 1.4, endR = rowX1 + 2 * PITCH + 1.4;
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
    // the opening's floor and ceiling, dark inside
    box('inner', base, 2 * OPEN_HALF + 2 * POST_W, 0.01, RACK_D - 0.05, 0, BASE_Y - 0.005, -RACK_D / 2);
    box('inner', base, 2 * OPEN_HALF + 2 * POST_W, 0.01, RACK_D - 0.05, 0, unitsTop + 0.005, -RACK_D / 2);
    for (const sx of [-1, 1]) {
      const x = sx * (OPEN_HALF + POST_W / 2);
      box('post', base, POST_W, uh + 0.02, POST_D, x, cy, -RECESS - POST_D / 2);
      box('post', base, POST_W, uh + 0.02, POST_D, x, cy, -RACK_D + 0.12);
      plane(sx < 0 ? 'postFaceL' : 'postFaceR', base, POST_W, uh, x, cy, -RECESS + 0.0004);
      // the inner walls between the front and rear posts
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
  const doorMats = doorKinds.map(d => std(0xffffff, 0.55, 0.35, { map: tex(keepCv(d.cv)) }));
  const doorW = RACK_W - 0.012, doorH = RACK_H - PLINTH_H - 0.012;
  doorSpots.forEach((m, i) => {
    const kind = (i * 7 + 3) % 3;
    plane('door' + kind, m, doorW, doorH, 0, PLINTH_H + 0.006 + doorH / 2, 0.006);
    doors.push({ m, kind });
  });
  doorMats.forEach((dm, i) => { M['door' + i] = dm; });
  for (const [key, list] of parts) {
    const mesh = new THREE.Mesh(own(mergeParts(list)), M[key]);
    mesh.matrixAutoUpdate = false;
    scene.add(mesh);
  }

  // the cabinets' label plates, R1 · #1-42
  const plateGeo = own(new THREE.PlaneGeometry(0.34, 0.064));
  for (let k = 0; k < nR; k++) {
    const a = k * perRack + 1, b = Math.min(units.length, (k + 1) * perRack);
    const t = tex(keepCv(labelTexture(P, k, a, b)));
    const m = P.plateLit ? own(new THREE.MeshBasicMaterial({ map: t })) : std(0xffffff, 0.45, 0.2, { map: t });
    const pm = new THREE.Mesh(plateGeo, m);
    pm.position.set(rackX(k), unitsTop + TOP_H / 2, 0.0008);
    scene.add(pm);
  }
  // the sign over the aisle
  {
    const sw = Math.min(1.7, Math.max(1.1, rowX1 - rowX0 + 0.2)), sh = sw * 200 / 1280;
    const t = tex(keepCv(signTexture(P, o.title, o.subtitle)));
    const sm = P.signLit ? own(new THREE.MeshBasicMaterial({ map: t })) : std(0xffffff, 0.5, 0.05, { map: t });
    const sign = new THREE.Mesh(own(new THREE.PlaneGeometry(sw, sh)), sm);
    sign.position.set(midX, 2.6, 1.05 + 0.02);
    const back = new THREE.Mesh(own(new THREE.BoxGeometry(sw + 0.03, sh + 0.03, 0.03)), M.fixture);
    back.position.set(midX, 2.6, 1.05);
    scene.add(sign, back);
    for (const dx of [-sw / 2 + 0.08, sw / 2 - 0.08]) {
      const w = new THREE.Mesh(own(new THREE.BoxGeometry(0.004, 2.894 - 2.6 - sh / 2, 0.004)), M.wire);
      w.position.set(midX + dx, (2.894 + 2.6 + sh / 2) / 2, 1.05);
      scene.add(w);
    }
  }

  /* the units */
  const faceGeo = own(new THREE.PlaneGeometry(PANEL_W, UNIT_H));
  const plateBox = own(new THREE.BoxGeometry(PANEL_W, UNIT_H, PLATE_T));
  const bodyGeo = own(new THREE.BoxGeometry(BODY_W, UNIT_H * 0.95, BODY_D));
  const railGeo = own(new THREE.BoxGeometry(0.007, 0.013, BODY_D * 0.93));
  const small = vw() <= 760;
  const faceW = small ? 768 : TW, faceH = Math.round(faceW * TH / TW);
  const lcdW = (LY.lcd[1] - LY.lcd[0]) / TW * PANEL_W, lcdH = (LY.lcdY[1] - LY.lcdY[0]) / TH * UNIT_H;
  const lcdGeo = own(new THREE.PlaneGeometry(lcdW, lcdH));
  const lcdPx = [small ? 192 : 256, Math.round((small ? 192 : 256) * lcdH / lcdW)];
  const lcdCx = pxX((LY.lcd[0] + LY.lcd[1]) / 2), lcdCy = pxY((LY.lcdY[0] + LY.lcdY[1]) / 2);
  const favT = tex(keepCv(favTexture()), { linear: true });
  const favGeo = own(new THREE.PlaneGeometry(PANEL_W, UNIT_H));
  const favMat = own(new THREE.MeshBasicMaterial({
    color: new THREE.Color(P.ledB), alphaMap: favT, transparent: true, opacity: P.favK, depthWrite: false,
    blending: P.favAdd ? THREE.AdditiveBlending : THREE.NormalBlending,
  }));
  const pipeGeo = own(new THREE.PlaneGeometry(PANEL_W - 0.004, 0.0011));
  const pipeMat = own(new THREE.MeshBasicMaterial({ color: new THREE.Color(P.ledB).multiplyScalar(P.favPipeK) }));
  const lcdMat = t => (P.lcdLit ? own(new THREE.MeshBasicMaterial({ map: t })) : std(0xffffff, 0.35, 0, { map: t }));

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
    u.group = g; u.slide = 0; u.tw = null; u.fx = null;
    scene.add(g);
    faces.push(u.face); lcds.push(u.lcd);
  }

  /* the LEDs */
  const per = nT + 1;
  const nLens = units.length * per;
  const decorLeds = [];
  doors.forEach(d => { for (const l of doorKinds[d.kind].leds) decorLeds.push({ m: d.m, l }); });
  const nGlow = nLens + (P.decorGlowK > 0 ? decorLeds.length : 0);
  const quad = own(new THREE.PlaneGeometry(1, 1));
  function ledMesh(count, fs, uniforms, additive) {
    const geo = own(quad.clone());
    geo.setAttribute('aColor', new THREE.InstancedBufferAttribute(new Float32Array(Math.max(1, count) * 3), 3));
    geo.setAttribute('aLevel', new THREE.InstancedBufferAttribute(new Float32Array(Math.max(1, count)), 1));
    geo.setAttribute('aHot', new THREE.InstancedBufferAttribute(new Float32Array(Math.max(1, count)), 1));
    const mat = own(new THREE.ShaderMaterial({
      uniforms: THREE.UniformsUtils.merge([THREE.UniformsLib.fog, uniforms]),
      vertexShader: LED_VS, fragmentShader: fs, fog: true, transparent: true,
      depthWrite: !additive, blending: additive ? THREE.AdditiveBlending : THREE.NormalBlending,
      side: THREE.DoubleSide,
    }));
    const mesh = new THREE.InstancedMesh(geo, mat, Math.max(1, count));
    mesh.count = count;
    mesh.frustumCulled = false;
    mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    mesh.renderOrder = additive ? 3 : 2;
    scene.add(mesh);
    return mesh;
  }
  const lens = ledMesh(nLens, LENS_FS, { uOff: { value: new THREE.Color(P.ledOff) }, uBoost: { value: P.ledBoost } }, false);
  const glow = ledMesh(nGlow, GLOW_FS, { uGlow: { value: P.glowK }, uTint: { value: dark ? 0 : 1 } }, true);
  if (!dark) glow.material.blending = THREE.NormalBlending;
  const cG = new THREE.Color(P.ledG), cB = new THREE.Color(P.ledB);
  function setLed(mesh, i, color, level, hot) {
    const a = mesh.geometry.attributes;
    a.aColor.array[i * 3] = color.r; a.aColor.array[i * 3 + 1] = color.g; a.aColor.array[i * 3 + 2] = color.b;
    a.aLevel.array[i] = level; a.aHot.array[i] = hot;
  }
  function setMat(mesh, i, x, y, z, s) {
    const e = mesh.instanceMatrix.array, o16 = i * 16;
    e[o16] = s; e[o16 + 1] = 0; e[o16 + 2] = 0; e[o16 + 3] = 0;
    e[o16 + 4] = 0; e[o16 + 5] = s; e[o16 + 6] = 0; e[o16 + 7] = 0;
    e[o16 + 8] = 0; e[o16 + 9] = 0; e[o16 + 10] = 1; e[o16 + 11] = 0;
    e[o16 + 12] = x; e[o16 + 13] = y; e[o16 + 14] = z; e[o16 + 15] = 1;
  }
  const ledX = Array.from({ length: nT }, (_, t) => pxX(LY.ledX0 + LY.sp * (t + 0.5)));
  const locX = pxX(LY.locX);
  function ledsOf(u) {
    for (let t = 0; t < nT; t++) {
      const l = u.leds[t];
      const has = l && l.p != null && isFinite(+l.p);
      const lv = has ? clamp01(l.p) : -1, hot = has && l.best ? 1 : 0;
      setLed(lens, u.i * per + t, cG, lv, hot); setLed(glow, u.i * per + t, cG, lv, hot);
    }
    setLed(lens, u.i * per + nT, cB, u.fav ? 1 : -1, 0); setLed(glow, u.i * per + nT, cB, u.fav ? 1 : -1, 0);
  }
  function placeLeds(u) {
    const p = u.group.position;
    for (let t = 0; t < nT; t++) {
      setMat(lens, u.i * per + t, p.x + ledX[t], p.y, p.z + LED_Z, LENS);
      setMat(glow, u.i * per + t, p.x + ledX[t], p.y, p.z + LED_Z + 0.0004, GLOW);
    }
    setMat(lens, u.i * per + nT, p.x + locX, p.y, p.z + LED_Z, LENS_LOC);
    setMat(glow, u.i * per + nT, p.x + locX, p.y, p.z + LED_Z + 0.0004, GLOW_LOC);
    lens.instanceMatrix.needsUpdate = glow.instanceMatrix.needsUpdate = true;
  }
  const ledAttrsDirty = () => { for (const m of [lens, glow]) for (const k of ['aColor', 'aLevel', 'aHot']) m.geometry.attributes[k].needsUpdate = true; };
  for (const u of units) { ledsOf(u); placeLeds(u); }
  if (nGlow > nLens) {
    const v = new THREE.Vector3();
    decorLeds.forEach((d, j) => {
      v.set(d.l.x * doorW, PLINTH_H + 0.006 + doorH / 2 + d.l.y * doorH, 0.009).applyMatrix4(d.m);
      const i = nLens + j;
      setMat(glow, i, v.x, v.y, v.z, 0.012 + 0.008 * d.l.level);
      setLed(glow, i, new THREE.Color(d.l.color), d.l.level * P.decorGlowK, 0);
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

  // the slid-out unit's lid and the shadow it casts on the panels below it
  const lidPx = [512, Math.round(512 * BODY_D / BODY_W)];
  const lidT = tex(canvas(lidPx[0], lidPx[1]));
  const lid = new THREE.Mesh(own(new THREE.PlaneGeometry(BODY_W - 0.002, BODY_D - 0.002)), std(0xffffff, 0.45, 0.55, { map: lidT }));
  lid.rotation.x = -Math.PI / 2; lid.position.set(0, UNIT_H * 0.475 + 0.0003, -PLATE_T - BODY_D / 2 - 0.0004);
  lid.visible = false;
  const shT = tex(keepCv(shadowTexture()), { linear: true });
  const shadow = new THREE.Mesh(own(new THREE.PlaneGeometry(PANEL_W, 0.075)), own(new THREE.MeshBasicMaterial({ color: 0x000000, alphaMap: shT, transparent: true, opacity: 0, depthWrite: false })));
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
  controls.maxDistance = 5.4;
  controls.minPolarAngle = 0.18;
  controls.maxPolarAngle = Math.PI / 2 + 0.34;
  controls.minAzimuthAngle = -1.38;
  controls.maxAzimuthAngle = 1.38;
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

  function overview() {
    const a = vw() / vh(), t = Math.tan(FOV * DEG / 2), hf = (vh() - topRes()) / vh();
    if (a < 1.05) {
      // a tall screen: R1 whole, the rest of the row going away from it
      const d = Math.max((RACK_H * 1.12) / 2 / (t * hf), (PITCH * 1.3) / 2 / (t * a));
      return { target: new THREE.Vector3(rackX(0) + 0.12, 1.02, -0.2), pos: new THREE.Vector3(rackX(0) - 0.5, 1.45, Math.min(OPP_Z - 0.45, d)) };
    }
    const len = Math.min(rowX1 - rowX0, 3 * PITCH);
    const target = new THREE.Vector3(rowX0 + len * 0.66, 1.0, -0.2);
    const pos = new THREE.Vector3(rowX0 - 1.1, 1.5, Math.min(OPP_Z - 0.45, 2.98 + len * 0.15 + Math.max(0, 1.5 - a) * 1.6));
    return { pos, target };
  }
  function rackView(k) {
    const W = vw(), H = vh(), Hf = H - topRes();
    const t = Math.tan(FOV * DEG / 2);
    const d = Math.max((RACK_H + 0.28) / 2 / (t * Hf / H), (RACK_W + 0.42) / 2 / (t * W / H));
    return { target: new THREE.Vector3(rackX(k), RACK_H / 2 + 0.02, 0), pos: new THREE.Vector3(rackX(k), RACK_H / 2 + 0.16, Math.min(OPP_Z - 0.35, d)) };
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
    const d = Math.max(0.3, (PANEL_W / 2) / (0.74 * tx), 0.11 / (0.8 * ty));
    const yaw = 0.24, el = 0.4;
    const target = new THREE.Vector3(u.x0, u.y0 - 0.004, u.z0 + POP - 0.11);
    const pos = target.clone().add(new THREE.Vector3(Math.sin(yaw) * Math.cos(el), Math.sin(el), Math.cos(yaw) * Math.cos(el)).multiplyScalar(d));
    pos.y = clamp(pos.y, 0.15, 2.95); pos.z = Math.min(pos.z, OPP_Z - 0.35);
    return { pos, target };
  }

  /* tweens: camera moves, slides, the panel's shift */
  const tweens = new Set();
  function tween(dur, step, ease, done) {
    if (reduced || dur <= 0) { step(1); if (done) done(); return null; }
    const tw = { t0: performance.now(), dur, step, ease: ease || easeInOut, done };
    tweens.add(tw); invalidate();
    return tw;
  }
  function runTweens(now) {
    for (const tw of Array.from(tweens)) {
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
  function setSlide(u, s) {
    u.slide = s;
    u.group.position.z = u.z0 + s;
    const vis = s > 0.0006;
    if (vis !== u.plate.visible) u.plate.visible = u.body.visible = u.railL.visible = u.railR.visible = vis;
    placeLeds(u);
    if (shadow.userData.u === u) shadow.material.opacity = 0.42 * clamp01(s / POP);
  }
  function slideTo(u, to, dur, ease, done) {
    if (u.tw) { tweens.delete(u.tw); u.tw = null; }
    const from = u.slide;
    if (Math.abs(to - from) < 1e-5) { if (done) done(); return; }
    u.tw = tween(dur, k => setSlide(u, from + (to - from) * k), ease, () => { u.tw = null; if (done) done(); });
  }

  /* hover, tooltips */
  let hovered = null, popped = null, home = null, aligned = -1, atOverview = true;
  function setHover(u) {
    if (u !== hovered) {
      const prev = hovered;
      hovered = u;
      if (prev) { prev.matFace.emissiveIntensity = P.faceEm; if (prev !== popped) slideTo(prev, 0, 160, easeOut); }
      if (u) { u.matFace.emissiveIntensity = P.faceEmHot; if (u !== popped) slideTo(u, LIFT, 140, easeOut); }
      cv.classList.toggle('hot', !!u);
      invalidate();
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
  function unitTip(u, region) {
    const rc = u.rank <= 3 ? ' r' + u.rank : '';
    if (region && region.kind === 'loc') {
      return '<div class="a3d-tt-h"><span class="a3d-tt-n">' + esc(u.fw) + '</span></div>'
        + '<div class="a3d-tt-s">' + (u.fav ? '<span class="a3d-tt-fav">Locator light is on.</span> Click to turn it off.' : 'Locator light. Click to light it up and mark this entry as a favourite.') + '</div>';
    }
    const meta = [u.lang ? '<i style="background:' + esc(u.langColor) + '"></i>' + esc(u.lang) : '', esc(TYPE_NAMES[u.type] || ''), u.tuned ? 'Tuned' : '', u.fav ? '<span class="a3d-tt-fav">Locator on</span>' : '']
      .filter(Boolean).join('<span aria-hidden="true">·</span>');
    return '<div class="a3d-tt-h"><span class="a3d-tt-r' + rc + '">#' + esc(u.rank) + '</span><span class="a3d-tt-n">' + esc(u.fw) + '</span></div>'
      + (meta ? '<div class="a3d-tt-m">' + meta + '</div>' : '')
      + (u.score ? '<div class="a3d-tt-s">Score <b>' + esc(u.score) + '</b>' + (u.share > 0 ? ' · ' + (u.share * 100).toFixed(u.share >= 0.995 ? 0 : 1) + '% of the leader' : '') + '</div>' : '')
      + '<div class="a3d-tt-k">' + (u === popped ? 'Click to slide it back in' : 'Click to slide it out') + '</div>';
  }
  function showTips(hit, x, y) {
    if (!hit) { hideTips(); return; }
    const { u, region } = hit;
    if (region.kind === 'led' && o.ledTipHtml) {
      const k = u.fw + '|' + region.i;
      if (ledTipEl.dataset.k !== k) {
        let h = null;
        try { h = o.ledTipHtml(u.fw, region.i); } catch (e) { console.error(e); }
        ledTipEl.dataset.k = k;
        ledTipEl.innerHTML = h || '';
        ledTipEl.classList.toggle('on', !!h);
      }
      if (ledTipEl.classList.contains('on')) { tipEl.classList.remove('on'); tipEl.dataset.k = ''; placeTip(ledTipEl, x, y); return; }
    } else { ledTipEl.classList.remove('on'); ledTipEl.dataset.k = ''; }
    const k = u.fw + '|' + region.kind + '|' + u.fav + '|' + (u === popped);
    if (tipEl.dataset.k !== k) { tipEl.innerHTML = unitTip(u, region); tipEl.dataset.k = k; }
    tipEl.classList.add('on');
    placeTip(tipEl, x, y);
  }

  const ray = new THREE.Raycaster(), ndc = new THREE.Vector2();
  function pick(x, y) {
    const r = cv.getBoundingClientRect();
    if (!r.width || !r.height) return null;
    ndc.set(((x - r.left) / r.width) * 2 - 1, -((y - r.top) / r.height) * 2 + 1);
    ray.setFromCamera(ndc, camera);
    const list = faces.concat(lcds);
    for (const u of units) if (u.slide > 0.0006) list.push(u.body, u.plate);
    if (lid.visible) list.push(lid);
    const hits = ray.intersectObjects(list, false);
    if (!hits.length) return null;
    const h = hits[0], u = h.object.userData.u || (h.object === lid && lid.userData.u);
    if (!u) return null;
    let region = { kind: 'unit' };
    if (h.object.userData.part === 'face' && h.uv) {
      const px = h.uv.x * TW, py = (1 - h.uv.y) * TH;
      if (Math.hypot(px - LY.locX, py - LY.cy) < 15) region = { kind: 'loc' };
      else if (nT > 0 && Math.abs(py - LY.cy) < 19 && px >= LY.ledX0 && px < LY.ledX0 + nT * LY.sp) region = { kind: 'led', i: clamp(Math.floor((px - LY.ledX0) / LY.sp), 0, nT - 1) };
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
    slideTo(u, POP, 460, easeBack);
    repaint(lidT, lidPx[0], lidPx[1], c => drawLid(c, u, P)); lid.userData.u = u;
    u.group.add(lid); lid.visible = true;
    shadow.userData.u = u; shadow.visible = true; shadow.material.opacity = 0.42 * clamp01(u.slide / POP);
    shadow.position.set(u.x0, u.y0 - UNIT_H / 2 - 0.0376, FACE_Z + 0.0006);
    let h = '';
    try { h = o.detailHtml ? o.detailHtml(u.fw) : ''; } catch (e) { console.error(e); }
    pbody.innerHTML = h || '';
    pbody.scrollTop = 0;
    panel.classList.add('on'); panel.setAttribute('aria-hidden', 'false');
    updateLoc();
    shiftTo(reserve());
    flyTo(popView(u), 820);
    live.textContent = u.fw + ' slid out of rack R' + (u.rack + 1) + ': rank ' + u.rank + (u.score ? ', score ' + u.score : '') + '.';
    hideTips();
  }
  function slideBack(u) {
    slideTo(u, u === hovered ? LIFT : 0, 380, easeInOut, () => { if (popped !== u) hiRes(u, false); });
  }
  function unpop(restore) {
    const u = popped;
    if (!u) return;
    popped = null;
    slideBack(u);
    lid.visible = false; if (lid.parent) lid.parent.remove(lid);
    shadow.visible = false; shadow.userData.u = null;
    panel.classList.remove('on'); panel.setAttribute('aria-hidden', 'true');
    shiftTo({ x: 0, y: 0 });
    if (restore !== false && home) flyTo(home, 760);
    home = null;
    live.textContent = u.fw + ' slid back into the rack.';
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
  function resetView() {
    if (popped) unpop(false);
    aligned = -1; atOverview = true;
    flyTo(overview(), 1000);
  }
  let hudRack = -2, hudPrev = null, hudNext = null;
  function updateHud() {
    let k = 0, best = Infinity;
    for (let i = 0; i < nR; i++) { const d = Math.abs(rackX(i) - controls.target.x); if (d < best) { best = d; k = i; } }
    if (atOverview) k = -1;
    if (k !== hudRack) { hudRack = k; chipEls.forEach((c, i) => { c.classList.toggle('on', i === k); c.setAttribute('aria-current', i === k ? 'true' : 'false'); }); }
    const p = navIdx(-1) < 0, n = navIdx(1) < 0;
    if (p !== hudPrev) { hudPrev = p; btn.prev.disabled = p; }
    if (n !== hudNext) { hudNext = n; btn.next.disabled = n; }
  }
  const _t0 = new THREE.Vector3(), _c0 = new THREE.Vector3();
  function clampView() {
    const t = controls.target, c = camera.position;
    _t0.copy(t); _c0.copy(c);
    t.x = clamp(t.x, rowX0 - 0.35, rowX1 + 0.35); t.y = clamp(t.y, 0.12, RACK_H + 0.2); t.z = clamp(t.z, -0.3, POP + 0.7);
    c.x = clamp(c.x, rowX0 - 2.3, rowX1 + 2.3); c.y = clamp(c.y, 0.1, CEIL - 0.22); c.z = clamp(c.z, 0.1, OPP_Z - 0.3);
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

  /* the loop: it runs only while something changes */
  let raf = 0, lastT = 0, renders = 0, shiftKey = false;
  // A slow machine finds out in the first second of motion: fewer pixels, no mirror.
  const probe = { n: 0, slow: 0, done: reduced };
  function lighten() {
    if (mirror) { for (const k of mirror.ks) k.value = 0; mirror.rt.dispose(); bin.delete(mirror.rt); mirror = null; }
    renderer.setPixelRatio(Math.max(1, renderer.getPixelRatio() * 0.7));
    renderer.setSize(vw(), vh(), false);
  }
  function invalidate() { if (!raf && !disposed) raf = requestAnimationFrame(frame); }
  function frame(now) {
    raf = 0;
    if (disposed) return;
    const dt = lastT ? Math.min(0.05, (now - lastT) / 1000) : 1 / 60;
    if (!probe.done && lastT && ++probe.n > 10) {
      if (now - lastT > 26) probe.slow++;
      if (probe.n >= 70) { probe.done = true; if (probe.slow > 36) lighten(); }
    }
    lastT = now;
    let more = runTweens(now);
    if (keys.size) { if (walk(dt, shiftKey)) { stopCam(); aligned = -1; atOverview = false; } more = true; }
    if (controls.update()) more = true;
    clampView();
    camera.updateMatrixWorld();
    updateHud();
    if (mirror) renderMirror();
    renderer.render(scene, camera);
    renders++;
    if (more) { if (!raf) raf = requestAnimationFrame(frame); } else lastT = 0;
  }
  controls.addEventListener('change', invalidate);
  controls.addEventListener('start', () => { stopCam(); aligned = -1; atOverview = false; hideTips(); });

  /* input */
  let down = null, pendingMove = null, moveRaf = 0;
  function onDown(e) {
    down = { x: e.clientX, y: e.clientY, t: performance.now(), b: e.button, moved: false };
    hideTips();
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
      setHover(hit ? hit.u : null);
      showTips(hit, pendingMove.x, pendingMove.y);
    });
  }
  function onUp(e) {
    const d = down;
    down = null;
    cv.classList.remove('drag');
    if (!d || d.moved || d.b !== 0 || performance.now() - d.t > 700) return;
    const hit = pick(e.clientX, e.clientY);
    if (!hit) return;
    if (hit.region.kind === 'loc') { toggleFav(hit.u); showTips(hit, e.clientX, e.clientY); return; }
    if (popped === hit.u) unpop(); else pop(hit.u);
  }
  function onLeave() { if (!down) { setHover(null); hideTips(); } }
  function onWheel() { hideTips(); }
  function onKey(e) {
    if (disposed) return;
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
    if (e.key === 'Escape') {
      e.preventDefault(); e.stopImmediatePropagation();
      if (popped) unpop(); else closeSelf();
      return;
    }
    const tg = e.target;
    if (tg && (tg.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(tg.tagName || ''))) return;
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === ']' || e.key === 'PageDown') { e.preventDefault(); e.stopImmediatePropagation(); goRack(navIdx(1)); return; }
    if (e.key === '[' || e.key === 'PageUp') { e.preventDefault(); e.stopImmediatePropagation(); goRack(navIdx(-1)); return; }
    if (e.key === 'Home') { e.preventDefault(); e.stopImmediatePropagation(); resetView(); return; }
    if (MOVE[e.code]) {
      if (tg instanceof Node && panel.contains(tg)) return;   // let the card scroll
      e.preventDefault(); e.stopImmediatePropagation();
      shiftKey = e.shiftKey;
      if (!keys.has(e.code)) { keys.add(e.code); hideTips(); }
      invalidate();
    }
  }
  function onKeyUp(e) { if (keys.delete(e.code)) e.stopImmediatePropagation(); shiftKey = e.shiftKey; }
  function onBlur() { keys.clear(); }
  function onClick(e) {
    const a = e.target.closest('[data-act],[data-rack],[data-close]');
    if (!a || !root.contains(a)) return;
    if (a.hasAttribute('data-close')) { e.preventDefault(); unpop(); return; }
    if (a.hasAttribute('data-rack')) { goRack(+a.getAttribute('data-rack')); return; }
    const act = a.getAttribute('data-act');
    if (act === 'prev') goRack(navIdx(-1));
    else if (act === 'next') goRack(navIdx(1));
    else if (act === 'reset') resetView();
    else if (act === 'close') closeSelf();
    else if (act === 'hidehelp') { helpEl.style.display = 'none'; try { localStorage.setItem('a3d-help', '0'); } catch (err) { /* fine */ } }
  }
  locBtn.addEventListener('click', () => { if (popped) toggleFav(popped); });
  cv.addEventListener('pointerdown', onDown);
  cv.addEventListener('pointermove', onMove);
  cv.addEventListener('pointerup', onUp);
  cv.addEventListener('pointercancel', () => { down = null; cv.classList.remove('drag'); });
  cv.addEventListener('pointerleave', onLeave);
  cv.addEventListener('wheel', onWheel, { passive: true });
  root.addEventListener('click', onClick);
  // the page behind does not scroll under the room; the card scrolls on its own
  const onRootWheel = e => { if (!pbody.contains(e.target)) e.preventDefault(); };
  root.addEventListener('wheel', onRootWheel, { passive: false });
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
    msgEl.textContent = 'The 3D view lost its graphics context. Close it and open it again.';
  });

  /* close */
  function dispose() {
    if (disposed) return;
    disposed = true;
    cancelAnimationFrame(raf); cancelAnimationFrame(moveRaf); raf = moveRaf = 0;
    tweens.clear();
    window.removeEventListener('keydown', onKey, true);
    window.removeEventListener('keyup', onKeyUp, true);
    window.removeEventListener('blur', onBlur);
    ro.disconnect();
    controls.dispose();
    scene.traverse(ob => {
      if (ob.geometry) bin.add(ob.geometry);
      const ms = Array.isArray(ob.material) ? ob.material : ob.material ? [ob.material] : [];
      for (const m of ms) {
        bin.add(m);
        for (const k of Object.keys(m)) { const v = m[k]; if (v && v.isTexture) bin.add(v); }
      }
    });
    for (const u of units) if (u.hi) { bin.add(u.hi.tf); bin.add(u.hi.tl); }
    lid.geometry && bin.add(lid.geometry); bin.add(lid.material);
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
    for (const x of texList) freeImage(x);
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
  applyView();
  const ov = overview();
  if (reduced) { camera.position.copy(ov.pos); controls.target.copy(ov.target); }
  else {
    camera.position.copy(ov.pos).add(new THREE.Vector3(-0.55, 0.45, 0.6));
    controls.target.copy(ov.target).add(new THREE.Vector3(-0.25, 0.1, 0));
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
    focus(fw) { const u = byFw.get(String(fw)); if (u && !disposed) pop(u); },
  };
  // for tests: where a unit's panel is on screen, and how many frames were drawn
  Object.defineProperty(handle, '_debug', {
    enumerable: false,
    value: {
      screenOf(fw, part) {
        const u = byFw.get(String(fw)); if (!u) return null;
        const r = cv.getBoundingClientRect();
        const v = new THREE.Vector3(part === 'loc' ? locX : typeof part === 'number' ? ledX[part] : 0, 0, 0.0002);
        u.group.localToWorld(v); v.project(camera);
        return { x: r.left + (v.x + 1) / 2 * r.width, y: r.top + (1 - v.y) / 2 * r.height };
      },
      view(p, t) { stopCam(); camera.position.set(p[0], p[1], p[2]); controls.target.set(t[0], t[1], t[2]); controls.update(); invalidate(); },
      stats() { return { renders, popped: popped && popped.fw, hovered: hovered && hovered.fw, aligned, tweens: tweens.size, info: renderer.info.render.calls, textures: renderer.info.memory.textures, geometries: renderer.info.memory.geometries }; },
    },
  });
  return handle;
}
