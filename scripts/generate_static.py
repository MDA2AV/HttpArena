#!/usr/bin/env python3
"""Generate realistic static files for HttpArena benchmarks."""

import gzip
import hashlib
import json
import os
import random
import struct

try:
    import brotli
    HAS_BROTLI = True
except ImportError:
    HAS_BROTLI = False

OUT = os.path.join(os.path.dirname(__file__), '..', 'data', 'static')
random.seed(42)

# --- Vocabulary for realistic code generation ---

CSS_PROPS = [
    'display', 'position', 'top', 'right', 'bottom', 'left', 'float', 'clear',
    'margin', 'margin-top', 'margin-right', 'margin-bottom', 'margin-left',
    'padding', 'padding-top', 'padding-right', 'padding-bottom', 'padding-left',
    'width', 'height', 'min-width', 'min-height', 'max-width', 'max-height',
    'overflow', 'overflow-x', 'overflow-y', 'font-family', 'font-size',
    'font-weight', 'font-style', 'line-height', 'letter-spacing', 'text-align',
    'text-decoration', 'text-transform', 'color', 'background', 'background-color',
    'background-image', 'background-size', 'background-position', 'border',
    'border-top', 'border-right', 'border-bottom', 'border-left', 'border-radius',
    'box-shadow', 'opacity', 'z-index', 'cursor', 'transition', 'transform',
    'animation', 'flex', 'flex-direction', 'flex-wrap', 'justify-content',
    'align-items', 'align-self', 'gap', 'grid-template-columns', 'grid-template-rows',
    'grid-gap', 'white-space', 'word-break', 'visibility', 'outline', 'box-sizing',
    'vertical-align', 'content', 'list-style', 'pointer-events', 'user-select',
    'will-change', 'backface-visibility', 'perspective', 'filter', 'backdrop-filter',
    'clip-path', 'object-fit', 'object-position', 'scroll-behavior', 'touch-action',
    'appearance', '-webkit-appearance', 'text-overflow', 'resize',
]

CSS_VALUES = {
    'display': ['block', 'inline', 'inline-block', 'flex', 'inline-flex', 'grid', 'none', 'contents', 'table', 'table-cell'],
    'position': ['relative', 'absolute', 'fixed', 'sticky', 'static'],
    'overflow': ['hidden', 'auto', 'scroll', 'visible', 'clip'],
    'text-align': ['left', 'center', 'right', 'justify'],
    'font-weight': ['400', '500', '600', '700', '800', 'normal', 'bold'],
    'cursor': ['pointer', 'default', 'not-allowed', 'grab', 'text', 'move', 'crosshair'],
    'flex-direction': ['row', 'column', 'row-reverse', 'column-reverse'],
    'justify-content': ['flex-start', 'flex-end', 'center', 'space-between', 'space-around', 'space-evenly'],
    'align-items': ['flex-start', 'flex-end', 'center', 'stretch', 'baseline'],
    'text-transform': ['uppercase', 'lowercase', 'capitalize', 'none'],
    'white-space': ['nowrap', 'pre', 'pre-wrap', 'normal', 'break-spaces'],
    'box-sizing': ['border-box', 'content-box'],
    'visibility': ['visible', 'hidden', 'collapse'],
    'object-fit': ['cover', 'contain', 'fill', 'none', 'scale-down'],
}

COLORS = [
    '#1a1a2e', '#16213e', '#0f3460', '#e94560', '#533483', '#2b2d42', '#8d99ae',
    '#edf2f4', '#ef233c', '#d90429', '#f8f9fa', '#dee2e6', '#adb5bd', '#6c757d',
    '#495057', '#343a40', '#212529', '#0d6efd', '#6610f2', '#6f42c1', '#d63384',
    '#dc3545', '#fd7e14', '#ffc107', '#198754', '#20c997', '#0dcaf0', '#fff',
    '#000', 'transparent', 'inherit', 'currentColor', 'rgba(0,0,0,.1)',
    'rgba(0,0,0,.15)', 'rgba(0,0,0,.25)', 'rgba(0,0,0,.5)', 'rgba(0,0,0,.75)',
    'rgba(255,255,255,.1)', 'rgba(255,255,255,.5)', 'rgba(255,255,255,.85)',
    'hsla(220,13%,18%,.95)', 'hsla(0,0%,100%,.08)', 'var(--primary)', 'var(--secondary)',
    'var(--accent)', 'var(--bg)', 'var(--fg)', 'var(--border-color)', 'var(--muted)',
    'var(--surface)', 'var(--surface-hover)', 'var(--danger)', 'var(--success)',
    'var(--warning)', 'var(--info)',
]

UNITS = ['px', 'rem', 'em', '%', 'vh', 'vw', 'ch', 'vmin', 'vmax']
FONT_FAMILIES = [
    'system-ui,-apple-system,sans-serif', '"Inter",sans-serif', '"Roboto",sans-serif',
    '"SF Pro Display",sans-serif', 'monospace', '"JetBrains Mono",monospace',
    '"Segoe UI","Helvetica Neue",Arial,sans-serif', 'var(--font-sans)', 'var(--font-mono)',
    '"Georgia",serif', 'var(--font-heading)',
]
EASING = ['ease', 'ease-in', 'ease-out', 'ease-in-out', 'linear',
          'cubic-bezier(.4,0,.2,1)', 'cubic-bezier(.4,0,1,1)', 'cubic-bezier(0,0,.2,1)',
          'cubic-bezier(.68,-.55,.27,1.55)', 'cubic-bezier(.22,1,.36,1)']
MEDIA_QUERIES = [
    '@media(max-width:576px)', '@media(min-width:576px)', '@media(min-width:768px)',
    '@media(min-width:992px)', '@media(min-width:1200px)', '@media(min-width:1400px)',
    '@media(prefers-color-scheme:dark)', '@media(prefers-reduced-motion:reduce)',
    '@media print', '@media(hover:hover)',
]

COMPONENT_PREFIXES = [
    'btn', 'card', 'modal', 'nav', 'sidebar', 'header', 'footer', 'hero',
    'alert', 'badge', 'toast', 'tooltip', 'popover', 'dropdown', 'tab',
    'accordion', 'breadcrumb', 'pagination', 'progress', 'spinner', 'avatar',
    'chip', 'tag', 'table', 'form', 'input', 'select', 'checkbox', 'radio',
    'switch', 'slider', 'calendar', 'datepicker', 'dialog', 'drawer', 'menu',
    'toolbar', 'stepper', 'timeline', 'carousel', 'gallery', 'grid', 'list',
    'divider', 'skeleton', 'placeholder', 'banner', 'callout', 'panel',
    'widget', 'search', 'filter', 'sort', 'upload', 'preview',
]

COMPONENT_SUFFIXES = [
    '', '-sm', '-md', '-lg', '-xl', '-primary', '-secondary', '-outline',
    '-ghost', '-link', '-icon', '-text', '-header', '-body', '-footer',
    '-title', '-subtitle', '-content', '-wrapper', '-container', '-inner',
    '-overlay', '-backdrop', '-trigger', '-close', '-toggle', '-label',
    '-group', '-item', '-active', '-disabled', '-loading', '-error',
    '-success', '-warning', '-info', '-danger', '-dark', '-light',
    '-rounded', '-flat', '-raised', '-floating', '-sticky', '-fixed',
    '-responsive', '-compact', '-dense', '-expanded', '-collapsed',
]

JS_VAR_PREFIXES = [
    'handle', 'render', 'update', 'create', 'delete', 'fetch', 'parse',
    'validate', 'format', 'transform', 'compute', 'calculate', 'process',
    'init', 'setup', 'configure', 'register', 'subscribe', 'dispatch',
    'emit', 'on', 'get', 'set', 'is', 'has', 'should', 'can', 'will',
    'resolve', 'reject', 'merge', 'clone', 'serialize', 'deserialize',
    'encode', 'decode', 'compress', 'decompress', 'encrypt', 'decrypt',
    'normalize', 'sanitize', 'escape', 'unescape', 'throttle', 'debounce',
    'memoize', 'cache', 'invalidate', 'refresh', 'reload', 'retry',
    'defer', 'delay', 'schedule', 'cancel', 'abort', 'reset', 'clear',
    'filter', 'sort', 'group', 'map', 'reduce', 'find', 'search', 'match',
    'replace', 'split', 'join', 'trim', 'pad', 'truncate', 'wrap',
    'bind', 'apply', 'call', 'invoke', 'execute', 'run', 'start', 'stop',
]

JS_NOUNS = [
    'User', 'Item', 'List', 'Data', 'Config', 'State', 'Props', 'Context',
    'Event', 'Error', 'Result', 'Response', 'Request', 'Query', 'Mutation',
    'Action', 'Reducer', 'Store', 'Cache', 'Buffer', 'Stream', 'Channel',
    'Socket', 'Connection', 'Session', 'Token', 'Auth', 'Permission',
    'Role', 'Profile', 'Account', 'Settings', 'Preferences', 'Theme',
    'Layout', 'Component', 'Element', 'Node', 'Tree', 'Graph', 'Map',
    'Set', 'Queue', 'Stack', 'Heap', 'Pool', 'Registry', 'Factory',
    'Builder', 'Observer', 'Listener', 'Handler', 'Middleware', 'Plugin',
    'Module', 'Package', 'Bundle', 'Chunk', 'Slice', 'Fragment', 'Ref',
    'Hook', 'Effect', 'Memo', 'Callback', 'Promise', 'Timer', 'Interval',
    'Timeout', 'Animation', 'Transition', 'Route', 'Path', 'Params',
    'Schema', 'Model', 'Entity', 'Record', 'Field', 'Column', 'Row',
    'Page', 'View', 'Screen', 'Panel', 'Tab', 'Modal', 'Dialog',
    'Form', 'Input', 'Option', 'Value', 'Label', 'Message', 'Notification',
    'Alert', 'Warning', 'Info', 'Debug', 'Log', 'Metric', 'Counter',
    'Gauge', 'Histogram', 'Summary', 'Trace', 'Span', 'Tag', 'Annotation',
]

# SVG icon paths (realistic icon path data)
SVG_ICON_NAMES = [
    'home', 'search', 'user', 'settings', 'bell', 'mail', 'heart', 'star',
    'bookmark', 'share', 'download', 'upload', 'edit', 'delete', 'copy',
    'paste', 'undo', 'redo', 'refresh', 'sync', 'filter', 'sort', 'grid',
    'list', 'menu', 'close', 'check', 'plus', 'minus', 'arrow-up',
    'arrow-down', 'arrow-left', 'arrow-right', 'chevron-up', 'chevron-down',
    'chevron-left', 'chevron-right', 'external-link', 'link', 'unlink',
    'lock', 'unlock', 'eye', 'eye-off', 'calendar', 'clock', 'map-pin',
    'phone', 'camera', 'image', 'video', 'music', 'file', 'folder',
    'archive', 'trash', 'flag', 'tag', 'hash', 'at-sign', 'globe',
    'wifi', 'bluetooth', 'battery', 'cpu', 'monitor', 'smartphone',
    'tablet', 'printer', 'server', 'database', 'cloud', 'sun', 'moon',
    'thermometer', 'droplet', 'wind', 'zap', 'activity', 'trending-up',
    'bar-chart', 'pie-chart', 'layers', 'layout', 'sidebar', 'columns',
    'maximize', 'minimize', 'move', 'crop', 'scissors', 'tool', 'code',
    'terminal', 'git-branch', 'git-commit', 'git-merge', 'git-pull-request',
    'package', 'box', 'shield', 'award', 'target', 'crosshair', 'compass',
    'navigation', 'map', 'anchor', 'life-buoy', 'aperture', 'disc',
    'headphones', 'mic', 'volume', 'speaker', 'radio', 'cast', 'airplay',
    'send', 'inbox', 'message-circle', 'message-square', 'users', 'user-plus',
]

# --- Compressibility-focused palettes ---

# Small palette of reused colors (80% of color picks come from here)
COLOR_PALETTE = [
    'var(--primary)', 'var(--secondary)', 'var(--fg)', 'var(--bg)',
    'var(--border-color)', 'var(--surface)', 'var(--muted)', 'var(--accent)',
]

# Common spacing values reused heavily
COMMON_SPACINGS = ['0', '4px', '8px', '12px', '16px', '24px', '32px', '0.5rem', '1rem', '1.5rem', '2rem']

# Common property-value combos repeated across many rules
COMMON_DECL_BLOCKS = [
    'display:flex;align-items:center',
    'display:flex;justify-content:center',
    'display:flex;align-items:center;justify-content:space-between',
    'display:flex;flex-direction:column',
    'display:flex;align-items:center;gap:8px',
    'display:flex;align-items:center;gap:16px',
    'display:grid;gap:16px',
    'display:grid;gap:24px',
    'position:relative',
    'position:absolute;top:0;left:0',
    'position:absolute;top:0;right:0',
    'position:absolute;inset:0',
    'position:fixed;top:0;left:0;right:0',
    'position:sticky;top:0',
    'overflow:hidden',
    'overflow:hidden;text-overflow:ellipsis;white-space:nowrap',
    'width:100%',
    'width:100%;height:100%',
    'max-width:100%',
    'margin:0 auto',
    'margin:0',
    'padding:0',
    'padding:8px 16px',
    'padding:12px 24px',
    'padding:16px',
    'padding:16px 24px',
    'padding:24px',
    'border:0',
    'border:1px solid var(--border-color)',
    'border-bottom:1px solid var(--border-color)',
    'border-radius:4px',
    'border-radius:8px',
    'border-radius:9999px',
    'box-sizing:border-box',
    'cursor:pointer',
    'color:inherit',
    'color:var(--fg)',
    'color:var(--primary)',
    'background:transparent',
    'background:var(--bg)',
    'background:var(--surface)',
    'font-size:.875rem',
    'font-size:1rem',
    'font-weight:600',
    'line-height:1.5',
    'text-decoration:none',
    'list-style:none',
    'outline:none',
    'transition:all .2s ease',
    'transition:opacity .2s ease',
    'transition:background .15s ease',
    'transition:color .15s ease',
    'opacity:0',
    'opacity:1',
    'visibility:hidden',
    'visibility:visible',
    'pointer-events:none',
    'user-select:none',
    '-webkit-appearance:none',
    'appearance:none',
]

# High-frequency selectors (real apps reuse these)
HIGH_FREQ_SELECTORS = [
    '.btn', '.btn-primary', '.btn-secondary', '.btn-outline', '.btn-sm', '.btn-lg',
    '.btn-icon', '.btn-link', '.btn-ghost', '.btn-group',
    '.card', '.card-header', '.card-body', '.card-footer', '.card-title',
    '.card-text', '.card-img', '.card-overlay',
    '.form-group', '.form-control', '.form-label', '.form-input', '.form-select',
    '.form-check', '.form-text', '.form-error', '.form-row',
    '.nav', '.nav-item', '.nav-link', '.nav-pills', '.nav-tabs',
    '.navbar', '.navbar-brand', '.navbar-nav', '.navbar-toggle',
    '.modal', '.modal-header', '.modal-body', '.modal-footer', '.modal-overlay',
    '.modal-content', '.modal-close', '.modal-title',
    '.dropdown', '.dropdown-toggle', '.dropdown-menu', '.dropdown-item',
    '.alert', '.alert-success', '.alert-danger', '.alert-warning', '.alert-info',
    '.badge', '.badge-primary', '.badge-secondary',
    '.table', '.table-header', '.table-row', '.table-cell', '.table-body',
    '.list', '.list-item', '.list-group',
    '.tab', '.tab-panel', '.tab-list', '.tab-content',
    '.avatar', '.avatar-sm', '.avatar-lg',
    '.tooltip', '.tooltip-inner', '.tooltip-arrow',
    '.container', '.row', '.col',
    '.flex', '.flex-center', '.flex-between',
    '.text-center', '.text-left', '.text-right', '.text-muted',
    '.d-none', '.d-block', '.d-flex', '.d-grid',
    '.m-0', '.m-1', '.m-2', '.m-3', '.m-4',
    '.p-0', '.p-1', '.p-2', '.p-3', '.p-4',
    '.w-100', '.h-100',
    '.sr-only', '.visually-hidden',
    '.skeleton', '.skeleton-text', '.skeleton-circle',
    '.spinner', '.spinner-sm',
    '.divider', '.spacer',
    '.sidebar', '.sidebar-nav', '.sidebar-item',
    '.header', '.header-inner', '.header-logo', '.header-actions',
    '.footer', '.footer-inner', '.footer-links',
    '.hero', '.hero-title', '.hero-subtitle', '.hero-cta',
    '.section', '.section-header', '.section-body',
    '.input', '.input-group', '.input-icon',
    '.search', '.search-input', '.search-results',
    '.tag', '.tag-group', '.chip', '.chip-group',
    '.toast', '.toast-body', '.toast-close',
    '.progress', '.progress-bar',
    '.breadcrumb', '.breadcrumb-item',
    '.pagination', '.pagination-item',
]

# Minified variable names (real minified JS)
JS_MINIFIED_VARS = ['e', 't', 'n', 'r', 'o', 'i', 'a', 's', 'c', 'l',
                    'u', 'd', 'p', 'f', 'h', 'm', 'g', 'v', 'b', 'y']

# Repeated string literals in JS (API paths, event names, DOM queries)
JS_REPEATED_STRINGS = [
    '"/api/v1/users"', '"/api/v1/items"', '"/api/v1/auth/login"',
    '"/api/v1/auth/refresh"', '"/api/v1/config"', '"/api/v1/search"',
    '"/api/v1/data"', '"/api/v2/users"', '"/api/v2/items"', '"/api/v2/search"',
    '"click"', '"change"', '"submit"', '"input"', '"keydown"',
    '"focus"', '"blur"', '"resize"', '"scroll"', '"load"',
    '"mouseover"', '"mouseout"', '"touchstart"', '"touchend"',
    '"application/json"', '"Content-Type"', '"Authorization"',
    '"Bearer "', '"GET"', '"POST"', '"PUT"', '"DELETE"',
    '".btn"', '".card"', '".modal"', '".nav"', '".form-control"',
    '"data-id"', '"data-type"', '"data-state"', '"data-action"',
    '"aria-hidden"', '"aria-expanded"', '"aria-label"', '"aria-selected"',
    '"true"', '"false"', '"undefined"', '"object"', '"string"', '"number"',
]

# Repeated function body patterns (webpack/bundler style)
JS_WEBPACK_PATTERNS = [
    'Object.defineProperty(e,"__esModule",{value:!0})',
    'Object.defineProperty(t,"__esModule",{value:!0})',
    'Object.defineProperty(n,"__esModule",{value:!0})',
    'e.exports=t',
    'e.exports=n',
    'n.d(e,{default:function(){return r}})',
    'n.d(e,{default:function(){return o}})',
    'n.r(e)',
    'n.r(t)',
    'if(typeof e!=="object"||e===null)return e',
    'if(typeof t!=="object"||t===null)return t',
]


def pick_color():
    """Pick a color, 80% from palette, 20% from full list."""
    if random.random() < 0.80:
        return random.choice(COLOR_PALETTE)
    return random.choice(COLORS)


def pick_spacing():
    """Pick a spacing value from the common set."""
    return random.choice(COMMON_SPACINGS)


def css_value(prop):
    """Generate a realistic CSS value for a given property."""
    if prop in CSS_VALUES:
        return random.choice(CSS_VALUES[prop])
    if 'color' in prop or prop == 'background' and random.random() < 0.5:
        return pick_color()
    if 'font-family' in prop:
        return random.choice(FONT_FAMILIES)
    if 'shadow' in prop:
        x, y, b, s = [random.choice([0,1,2,4,8,12,16,24]) for _ in range(4)]
        return f'{x}px {y}px {b}px {s}px rgba(0,0,0,.{random.randint(5,30)})'
    if 'transition' in prop:
        p = random.choice(['all','opacity','transform','color','background','border','box-shadow'])
        d = random.choice(['.15s','.2s','.25s','.3s','.35s','.4s','150ms','200ms','250ms','300ms'])
        return f'{p} {d} {random.choice(EASING)}'
    if 'transform' in prop:
        t = random.choice(['translateX','translateY','translate','scale','rotate','skewX','skewY'])
        if t == 'rotate': return f'rotate({random.randint(-180,180)}deg)'
        if t == 'scale': return f'scale({random.choice([".95",".98","1","1.02","1.05","1.1"])})'
        v = random.choice(['-100%','-50%','-8px','-4px','0','4px','8px','50%','100%'])
        return f'{t}({v})'
    if 'radius' in prop:
        v = random.choice([0,2,3,4,6,8,12,16,24,9999])
        return f'{v}px' if v != 9999 else '9999px'
    if 'z-index' in prop:
        return str(random.choice([1,2,5,10,50,100,999,1000,9999,10000]))
    if prop == 'opacity':
        return str(random.choice([0,.05,.1,.15,.2,.25,.3,.4,.5,.6,.7,.75,.8,.85,.9,.95,1]))
    if any(x in prop for x in ['margin','padding','top','right','bottom','left','gap','width','height']):
        if random.random() < 0.15:
            return 'auto' if 'margin' in prop else '100%'
        return pick_spacing()
    if 'font-size' in prop:
        v = random.choice([10,11,12,13,14,15,16,18,20,22,24,28,32,36,40,48,56,64])
        return f'{v}px'
    if 'line-height' in prop:
        return str(random.choice([1,1.15,1.25,1.35,1.4,1.5,1.6,1.75,2]))
    if 'letter-spacing' in prop:
        return random.choice(['-.05em','-.025em','0','0.025em','.05em','.1em','.15em'])
    if 'border' in prop and 'radius' not in prop:
        w = random.choice([1,2,3])
        s = random.choice(['solid','dashed','dotted','none'])
        return f'{w}px {s} {pick_color()}'
    if 'animation' in prop:
        name = random.choice(['fadeIn','fadeOut','slideIn','slideOut','pulse','bounce','spin','shake'])
        d = random.choice(['.2s','.3s','.5s','.8s','1s','1.5s','2s'])
        return f'{name} {d} {random.choice(EASING)}'
    if 'filter' in prop or 'backdrop' in prop:
        f = random.choice(['blur','brightness','contrast','saturate','grayscale','sepia'])
        if f == 'blur': return f'blur({random.choice([1,2,4,8,12,16,20,24])}px)'
        return f'{f}({random.choice([".5",".75",".9","1","1.1","1.25","1.5","2"])})'
    return pick_color()


def gen_css_rule():
    """Generate a single CSS rule with 2-6 declarations."""
    # 60% chance: use a high-frequency selector, 40%: generated selector
    if random.random() < 0.60:
        selector = random.choice(HIGH_FREQ_SELECTORS)
        pseudo = random.choice(['', '', '', ':hover', ':focus', ':active',
                               ':first-child', ':last-child', '::before', '::after',
                               ':focus-visible', ':disabled', ':not(:last-child)'])
        selector = selector + pseudo
    else:
        prefix = random.choice(COMPONENT_PREFIXES)
        suffix = random.choice(COMPONENT_SUFFIXES)
        pseudo = random.choice(['', ':hover', ':focus', ':active', ':first-child', ':last-child',
                               '::before', '::after', ':focus-visible', ':not(:last-child)',
                               ':nth-child(2n)', ':disabled', '[aria-expanded="true"]', ':checked',
                               ':placeholder-shown', '::placeholder', ':focus-within', ':empty'])
        combinator = random.choice(['', ' ', ' > ', ' + ', ' ~ '])
        child = ''
        if combinator.strip():
            child = random.choice([f'.{random.choice(COMPONENT_PREFIXES)}{random.choice(COMPONENT_SUFFIXES)}',
                                   'span', 'div', 'a', 'p', 'svg', 'img', 'input', 'button', 'label',
                                   '[role="button"]', '[data-active]', '*'])
        selector = f'.{prefix}{suffix}{combinator}{child}{pseudo}'

    # 40% chance: use a common declaration block (high repetition), then add 0-2 extras
    if random.random() < 0.40:
        base = random.choice(COMMON_DECL_BLOCKS)
        extras = []
        for _ in range(random.randint(0, 2)):
            p = random.choice(CSS_PROPS)
            extras.append(f'{p}:{css_value(p)}')
        decls = base + (';' + ';'.join(extras) if extras else '')
    else:
        props = random.sample(CSS_PROPS, random.randint(2, 6))
        decls = ';'.join(f'{p}:{css_value(p)}' for p in props)
    return f'{selector}{{{decls}}}'


def gen_css_keyframe():
    """Generate a CSS keyframe animation."""
    name = random.choice(['fadeIn','fadeOut','slideInUp','slideInDown','slideInLeft','slideInRight',
                          'pulse','bounce','spin','shake','grow','shrink','blink','swing','wobble',
                          'flash','rubberBand','jello','heartBeat','flipInX','flipInY','zoomIn','zoomOut',
                          'rollIn','lightSpeedIn','rotateIn','jackInTheBox','hinge','backInUp'])
    steps = random.choice([
        ['from', 'to'],
        ['0%', '50%', '100%'],
        ['0%', '25%', '50%', '75%', '100%'],
    ])
    rules = []
    for step in steps:
        props = random.sample(['opacity', 'transform', 'visibility', 'filter', 'color'], random.randint(1, 3))
        decls = ';'.join(f'{p}:{css_value(p)}' for p in props)
        rules.append(f'{step}{{{decls}}}')
    return f'@keyframes {name}{{{"".join(rules)}}}'


def gen_css_custom_props():
    """Generate CSS custom properties block."""
    props = [
        ('--primary', random.choice(COLORS)),
        ('--secondary', random.choice(COLORS)),
        ('--accent', random.choice(COLORS)),
        ('--bg', random.choice(['#fff','#fafafa','#f5f5f5','#1a1a2e','#0f0f1a'])),
        ('--fg', random.choice(['#212529','#1a1a2e','#e8e8e8','#f5f5f5'])),
        ('--border-color', random.choice(['#dee2e6','#e5e7eb','rgba(0,0,0,.1)','rgba(255,255,255,.1)'])),
        ('--radius-sm', random.choice(['2px','3px','4px'])),
        ('--radius-md', random.choice(['6px','8px'])),
        ('--radius-lg', random.choice(['12px','16px'])),
        ('--shadow-sm', f'0 1px 2px rgba(0,0,0,.{random.randint(5,15)})'),
        ('--shadow-md', f'0 4px 6px -1px rgba(0,0,0,.{random.randint(8,20)})'),
        ('--shadow-lg', f'0 10px 15px -3px rgba(0,0,0,.{random.randint(10,25)})'),
        ('--font-sans', random.choice(FONT_FAMILIES)),
        ('--font-mono', '"JetBrains Mono",monospace'),
        ('--font-size-xs', '.75rem'),
        ('--font-size-sm', '.875rem'),
        ('--font-size-md', '1rem'),
        ('--font-size-lg', '1.125rem'),
        ('--font-size-xl', '1.25rem'),
        ('--transition-fast', '.15s ease'),
        ('--transition-normal', '.25s ease'),
        ('--transition-slow', '.4s ease'),
        ('--z-dropdown', '1000'),
        ('--z-sticky', '1020'),
        ('--z-fixed', '1030'),
        ('--z-modal-backdrop', '1040'),
        ('--z-modal', '1050'),
        ('--z-popover', '1060'),
        ('--z-tooltip', '1070'),
        ('--surface', random.choice(['#fff','#fafafa','#f8f9fa','#1e1e2e'])),
        ('--surface-hover', random.choice(['#f5f5f5','#f0f0f0','#2a2a3e'])),
        ('--muted', random.choice(['#6c757d','#8d99ae','#adb5bd'])),
        ('--danger', random.choice(['#dc3545','#e94560','#d90429'])),
        ('--success', random.choice(['#198754','#20c997'])),
        ('--warning', random.choice(['#ffc107','#fd7e14'])),
        ('--info', random.choice(['#0dcaf0','#0d6efd'])),
    ]
    decls = ';'.join(f'{k}:{v}' for k, v in props)
    return f':root{{{decls}}}'


def gen_css_media_block():
    """Generate a media query block with rules inside (responsive overrides)."""
    mq = random.choice(MEDIA_QUERIES)
    # Real CSS has lots of rules inside media queries; generate 3-10
    inner_parts = []
    for _ in range(random.randint(3, 10)):
        inner_parts.append(gen_css_rule())
    return f'{mq}{{{"".join(inner_parts)}}}'


def generate_css(target_kb, include_vars=False, include_keyframes=False, include_media=False):
    """Generate CSS content targeting approximately target_kb kilobytes."""
    parts = []
    if include_vars:
        parts.append(gen_css_custom_props())
    target_bytes = target_kb * 1024
    while len(''.join(parts)) < target_bytes:
        r = random.random()
        if include_keyframes and r < 0.04:
            parts.append(gen_css_keyframe())
        elif include_media and r < 0.25:
            # Media query block with more rules (responsive overrides are very common)
            parts.append(gen_css_media_block())
        else:
            parts.append(gen_css_rule())
    return ''.join(parts)[:target_bytes]


# --- JavaScript generation ---

def gen_js_string():
    """Generate a realistic JS string literal."""
    # 50% chance: use a repeated string for compressibility
    if random.random() < 0.50:
        return random.choice(JS_REPEATED_STRINGS)
    templates = [
        lambda: f'"{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}"',
        lambda: f'"/{"/".join(random.choice(["api","v1","v2","auth","users","items","data","config","search","admin"]) for _ in range(random.randint(1,3)))}"',
        lambda: f'"application/{random.choice(["json","xml","octet-stream","x-www-form-urlencoded","pdf"])}"',
        lambda: f'"{random.choice(["GET","POST","PUT","PATCH","DELETE","HEAD","OPTIONS"])}"',
        lambda: f'"data-{random.choice(["id","type","state","index","key","value","action","target","source","ref"])}"',
        lambda: f'"aria-{random.choice(["label","hidden","expanded","selected","disabled","live","role","controls","describedby","labelledby"])}"',
        lambda: f'`{random.choice(["Error","Warning","Info","Debug","Trace"])}: ${{{random.choice(JS_MINIFIED_VARS)}}}`',
        lambda: f'"{random.choice(["click","submit","change","input","focus","blur","keydown","keyup","resize","scroll","load","error","mouseover","mouseout","touchstart","touchend","pointerdown","pointerup","dragstart","drop"])}"',
    ]
    return random.choice(templates)()


def gen_js_var():
    """Pick a minified variable name (reuses the small pool heavily)."""
    return random.choice(JS_MINIFIED_VARS)


def gen_js_function(depth=0):
    """Generate a realistic JS function."""
    name = f'{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}'
    params = ','.join(random.sample(JS_MINIFIED_VARS, random.randint(0, 4)))
    body_parts = []
    num_statements = random.randint(3, 12)
    for _ in range(num_statements):
        body_parts.append(gen_js_statement(depth))
    body = ';'.join(body_parts)
    style = random.choice(['function', 'const', 'export'])
    if style == 'function':
        return f'function {name}({params}){{{body}}}'
    elif style == 'const':
        return f'const {name}=({params})=>{{{body}}}'
    else:
        return f'export function {name}({params}){{{body}}}'


def gen_js_component_function():
    """Generate a repetitive component-style function (like React components in a bundle)."""
    name = f'{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}'
    v1 = gen_js_var()
    v2 = gen_js_var()
    v3 = gen_js_var()
    # Repeated pattern: component wrapper with props/state/render
    body_parts = [
        f'var {v1}=this.props||{{}}',
        f'var {v2}=this.state||{{}}',
        f'if(!{v1})return null',
        f'{v2}.loading&&(this.setState({{loading:!1}}))',
    ]
    # Add repeated event handler registrations
    for _ in range(random.randint(2, 5)):
        evt = random.choice(['"click"', '"change"', '"submit"', '"input"', '"keydown"', '"focus"', '"blur"'])
        body_parts.append(f'{v1}.addEventListener({evt},{v3})')
    # Add repeated DOM manipulations
    for _ in range(random.randint(1, 3)):
        cls = random.choice(['"btn"', '"card"', '"modal"', '"active"', '"hidden"', '"loading"'])
        body_parts.append(f'{v1}.classList.add({cls})')
    body_parts.append(f'return {v2}')
    body = ';'.join(body_parts)
    return f'function {name}({v1},{v2},{v3}){{{body}}}'


def gen_js_webpack_module():
    """Generate a webpack-style module wrapper (highly repetitive in real bundles)."""
    module_id = random.randint(100, 9999)
    v1 = gen_js_var()
    v2 = gen_js_var()
    v3 = gen_js_var()
    inner_parts = [random.choice(JS_WEBPACK_PATTERNS) for _ in range(random.randint(2, 5))]
    # Add some statements
    for _ in range(random.randint(2, 6)):
        inner_parts.append(gen_js_statement(0))
    body = ';'.join(inner_parts)
    return f'__webpack_modules__[{module_id}]=function({v1},{v2},{v3}){{{body}}}'


def gen_js_define_property_block():
    """Generate repeated Object.defineProperty calls (very common in bundled code)."""
    obj = gen_js_var()
    props = random.sample([f'{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}' for _ in range(10)],
                          random.randint(4, 8))
    parts = []
    for prop in props:
        val = random.choice([gen_js_var(), gen_js_string(), 'null', 'void 0', '!0', '!1'])
        parts.append(f'Object.defineProperty({obj},"{prop}",{{enumerable:!0,get:function(){{return {val}}}}})')
    return ';'.join(parts)


def gen_js_statement(depth=0):
    """Generate a single JS statement."""
    r = random.random()
    v1 = gen_js_var()
    v2 = gen_js_var()

    if r < 0.15:
        # Variable declaration
        val = random.choice([
            gen_js_string(),
            str(random.randint(0, 9999)),
            random.choice(['!0', '!1', 'null', 'void 0', '""', '[]', '{}', 'new Map', 'new Set', 'Object.create(null)']),
            f'{v2}.{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}',
            f'{v2}[{gen_js_string()}]',
            f'document.querySelector({gen_js_string()})',
        ])
        return f'var {v1}={val}'
    elif r < 0.25:
        # If statement
        cond = random.choice([
            f'{v1}', f'!{v1}', f'{v1}==null', f'{v1}!==null', f'typeof {v1}==="undefined"',
            f'{v1}.length>0', f'{v1}&&{v1}.{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}',
            f'Array.isArray({v1})', f'{v1} instanceof Error', f'{v1}>{random.randint(0,100)}',
        ])
        then = gen_js_statement(depth+1)
        if random.random() < 0.3 and depth < 2:
            el = gen_js_statement(depth+1)
            return f'if({cond}){{{then}}}else{{{el}}}'
        return f'if({cond}){{{then}}}'
    elif r < 0.32:
        # Try/catch
        try_body = gen_js_statement(depth+1)
        return f'try{{{try_body}}}catch({v2}){{console.error({v2})}}'
    elif r < 0.4:
        # Method call chain
        obj = random.choice([v1, v2, 'this', 'self', 'window', 'document', 'globalThis'])
        methods = []
        for _ in range(random.randint(1, 4)):
            m = f'{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}'
            args = ','.join(random.choice([gen_js_string(), str(random.randint(0,99)), '!0', 'null', v1, v2])
                          for _ in range(random.randint(0, 2)))
            methods.append(f'.{m}({args})')
        return f'{obj}{"".join(methods)}'
    elif r < 0.48:
        # Array operation
        op = random.choice(['map', 'filter', 'reduce', 'forEach', 'find', 'some', 'every', 'flatMap', 'sort'])
        if op == 'reduce':
            return f'{v1}.{op}(({v2},n)=>{v2}+n,0)'
        elif op == 'sort':
            return f'{v1}.{op}((a,b)=>a-b)'
        else:
            return f'{v1}.{op}({v2}=>{v2}.{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)})'
    elif r < 0.55:
        # Object destructuring/spread
        keys = random.sample([f'{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}' for _ in range(8)], random.randint(2, 5))
        return f'var {{{",".join(keys)}}}={v1}'
    elif r < 0.62:
        # Promise/async
        return random.choice([
            f'await {random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}({v1})',
            'return new Promise((resolve,reject)=>{setTimeout(()=>resolve(' + v1 + '),' + str(random.choice([0,10,50,100,500])) + ')})',
            f'{v1}.then({v2}=>{v2}).catch(err=>console.error(err))',
        ])
    elif r < 0.68:
        # DOM operation
        return random.choice([
            f'{v1}.addEventListener({gen_js_string()},{v2})',
            f'{v1}.classList.{random.choice(["add","remove","toggle"])}({gen_js_string()})',
            f'{v1}.setAttribute({gen_js_string()},{gen_js_string()})',
            f'{v1}.style.{random.choice(CSS_PROPS[:20])}={gen_js_string()}',
            f'{v1}.innerHTML={gen_js_string()}',
            f'{v1}.textContent={gen_js_string()}',
            f'{v1}.appendChild(document.createElement({gen_js_string()}))',
        ])
    elif r < 0.74:
        # Return
        return random.choice([
            f'return {v1}',
            f'return{{{",".join(f"{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}:{random.choice([v1,v2,"null","!0",str(random.randint(0,99))])}" for _ in range(random.randint(2,5)))}}}',
            f'return {v1}?{v2}:null',
        ])
    elif r < 0.80:
        # Switch
        cases = ''.join(f'case {gen_js_string()}:{gen_js_statement(depth+1)};break;' for _ in range(random.randint(2, 4)))
        return f'switch({v1}){{{cases}default:break}}'
    elif r < 0.86:
        # For loop
        return f'for(var {v2}=0;{v2}<{v1}.length;{v2}++){{{gen_js_statement(depth+1)}}}'
    elif r < 0.92:
        # Ternary assignment
        return f'var {v2}={v1}?{gen_js_string()}:{gen_js_string()}'
    else:
        # Console/logging
        level = random.choice(['log','warn','error','debug','info','trace'])
        return f'console.{level}({gen_js_string()},{v1})'


def gen_js_class():
    """Generate a JS class."""
    name = random.choice(JS_NOUNS)
    parent = random.choice(['', f' extends {random.choice(JS_NOUNS)}'])
    methods = []
    # Constructor
    params = ','.join(random.sample(JS_MINIFIED_VARS[:10], random.randint(1, 4)))
    ctor_body = ';'.join(f'this.{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}={gen_js_var()}' for _ in range(random.randint(2, 5)))
    methods.append(f'constructor({params}){{{ctor_body}}}')
    # Regular methods
    for _ in range(random.randint(3, 8)):
        mname = f'{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}'
        mparams = ','.join(random.sample(JS_MINIFIED_VARS[:10], random.randint(0, 3)))
        mbody = ';'.join(gen_js_statement(0) for _ in range(random.randint(2, 6)))
        prefix = random.choice(['', 'async ', 'static ', 'get '])
        methods.append(f'{prefix}{mname}({mparams}){{{mbody}}}')
    return f'class {name}{parent}{{{"".join(methods)}}}'


def gen_js_object_literal():
    """Generate a large object literal (like a config or constants object)."""
    name = f'{random.choice(["DEFAULT","INITIAL","BASE","APP","CONFIG","CONSTANTS","DEFAULTS","OPTIONS","SETTINGS"])}_{random.choice(JS_NOUNS).upper()}'
    entries = []
    for _ in range(random.randint(8, 20)):
        key = f'{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}'
        val = random.choice([
            gen_js_string(),
            str(random.randint(0, 9999)),
            random.choice(['!0', '!1', 'null']),
            f'[{",".join(gen_js_string() for _ in range(random.randint(2,5)))}]',
            f'{{{",".join(f"{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}:{gen_js_string()}" for _ in range(random.randint(2,4)))}}}',
        ])
        entries.append(f'{key}:{val}')
    return f'var {name}={{{",".join(entries)}}}'


def generate_js(target_kb):
    """Generate JS content targeting approximately target_kb kilobytes."""
    parts = []
    # Larger, more repetitive import section
    import_modules = [
        './utils', './helpers', './api', './config', './constants', './types',
        './hooks', './store', './services', './components', './lib',
        './router', './middleware', './validators', './formatters', './cache',
        '@app/core', '@app/ui', '@app/data', '@app/auth', '@app/router',
        '@app/state', '@app/i18n', '@app/theme', '@app/logger', '@app/analytics',
        '@app/events', '@app/dom', '@app/http', '@app/storage', '@app/crypto',
    ]
    for mod in import_modules:
        names = ','.join(random.sample([f'{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}' for _ in range(8)], random.randint(1, 4)))
        parts.append(f'import{{{names}}}from"{mod}"')

    # Webpack runtime preamble (very repetitive, compresses well)
    parts.append('var __webpack_modules__={}')
    parts.append('var __webpack_module_cache__={}')
    parts.append('function __webpack_require__(e){var t=__webpack_module_cache__[e];if(t!==void 0)return t.exports;var n=__webpack_module_cache__[e]={exports:{}};return __webpack_modules__[e](n,n.exports,__webpack_require__),n.exports}')
    parts.append('__webpack_require__.d=function(e,t){for(var n in t)Object.prototype.hasOwnProperty.call(t,n)&&!Object.prototype.hasOwnProperty.call(e,n)&&Object.defineProperty(e,n,{enumerable:!0,get:t[n]})}')
    parts.append('__webpack_require__.r=function(e){typeof Symbol!=="undefined"&&Symbol.toStringTag&&Object.defineProperty(e,Symbol.toStringTag,{value:"Module"}),Object.defineProperty(e,"__esModule",{value:!0})}')

    target_bytes = target_kb * 1024
    while len(';'.join(parts)) < target_bytes:
        r = random.random()
        if r < 0.20:
            parts.append(gen_js_function())
        elif r < 0.30:
            parts.append(gen_js_class())
        elif r < 0.40:
            parts.append(gen_js_object_literal())
        elif r < 0.52:
            # Webpack module wrapper (very repetitive across bundles)
            parts.append(gen_js_webpack_module())
        elif r < 0.62:
            # Component-style function (repetitive pattern)
            parts.append(gen_js_component_function())
        elif r < 0.72:
            # Object.defineProperty block (repetitive)
            parts.append(gen_js_define_property_block())
        elif r < 0.82:
            # IIFE (module pattern)
            body = ';'.join(gen_js_statement(0) for _ in range(random.randint(5, 15)))
            parts.append(f'(function(){{{body}}})()')
        else:
            # Repeated module registration pattern
            mod_id = str(random.randint(100, 9999))
            v = gen_js_var()
            inner = ';'.join(gen_js_statement(0) for _ in range(random.randint(3, 8)))
            parts.append(f'__webpack_require__.r({v}=__webpack_require__({mod_id}));{inner}')
    return ';'.join(parts)[:target_bytes]


# --- HTML generation ---

HTML_TAGS = ['div', 'span', 'p', 'a', 'button', 'img', 'input', 'label', 'section',
             'article', 'aside', 'nav', 'main', 'header', 'footer', 'ul', 'li',
             'h1', 'h2', 'h3', 'h4', 'form', 'select', 'option', 'textarea',
             'table', 'thead', 'tbody', 'tr', 'th', 'td', 'figure', 'figcaption',
             'details', 'summary', 'dialog', 'picture', 'source', 'video', 'time',
             'strong', 'em', 'small', 'mark', 'code', 'pre', 'blockquote', 'hr',
             'progress', 'meter', 'output', 'template', 'slot']

HTML_ATTRS = [
    lambda: f'class="{random.choice(COMPONENT_PREFIXES)}{random.choice(COMPONENT_SUFFIXES)}"',
    lambda: f'id="{random.choice(COMPONENT_PREFIXES)}-{random.randint(1,999)}"',
    lambda: f'data-{random.choice(["id","type","state","index","action","target","ref","key","value"])}="{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}"',
    lambda: f'aria-{random.choice(["label","hidden","expanded","selected","disabled","live","controls"])}="{random.choice(["true","false",random.choice(JS_NOUNS)])}"',
    lambda: f'role="{random.choice(["button","dialog","alert","tab","tabpanel","menu","menuitem","navigation","banner","complementary","contentinfo","main","search","form","group","list","listitem","region","status","timer","tooltip","tree","treeitem"])}"',
    lambda: f'tabindex="{random.choice(["0","-1","1"])}"',
    lambda: f'style="{random.choice(CSS_PROPS[:10])}:{css_value(random.choice(CSS_PROPS[:10]))}"',
    lambda: f'title="{random.choice(JS_VAR_PREFIXES)} {random.choice(JS_NOUNS).lower()}"',
]

HTML_TEXTS = [
    'Dashboard Overview', 'Settings & Preferences', 'Account Management',
    'User Profile', 'Notifications', 'Search Results', 'Recent Activity',
    'Quick Actions', 'Data Analytics', 'System Status', 'Performance Metrics',
    'Resource Monitor', 'Event Timeline', 'Audit Log', 'Access Control',
    'Integration Hub', 'API Documentation', 'Release Notes', 'Change History',
    'Team Management', 'Project Overview', 'Task Board', 'Sprint Planning',
    'Code Review', 'Deploy Pipeline', 'Error Tracking', 'Incident Response',
    'Service Health', 'Network Status', 'Storage Usage', 'Billing Summary',
    'Feature Flags', 'A/B Testing', 'Content Management', 'Media Library',
    'Email Templates', 'Notification Rules', 'Webhook Config', 'OAuth Settings',
    'Two-Factor Auth', 'Session Management', 'API Keys', 'Rate Limiting',
    'Caching Policy', 'CDN Configuration', 'SSL Certificates', 'DNS Records',
    'Load Balancer', 'Auto Scaling', 'Container Orchestration', 'Log Aggregation',
]

# Common inline SVG icons reused across HTML (like heroicons/feather)
INLINE_SVG_ICONS = [
    '<svg class="icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 12h18M3 6h18M3 18h18"/></svg>',
    '<svg class="icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><path d="M21 21l-4.35-4.35"/></svg>',
    '<svg class="icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M6 9l6 6 6-6"/></svg>',
    '<svg class="icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M5 12h14M12 5l7 7-7 7"/></svg>',
    '<svg class="icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>',
    '<svg class="icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 6L9 17l-5-5"/></svg>',
    '<svg class="icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 5v14M5 12h14"/></svg>',
    '<svg class="icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M19 12H5M12 19l-7-7 7-7"/></svg>',
    '<svg class="icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 010 2.83 2 2 0 01-2.83 0l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 01-4 0v-.09A1.65 1.65 0 009 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 01-2.83-2.83l.06-.06A1.65 1.65 0 004.68 15a1.65 1.65 0 00-1.51-1H3a2 2 0 010-4h.09A1.65 1.65 0 004.6 9a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 012.83-2.83l.06.06A1.65 1.65 0 009 4.68a1.65 1.65 0 001-1.51V3a2 2 0 014 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 012.83 2.83l-.06.06A1.65 1.65 0 0019.4 9a1.65 1.65 0 001.51 1H21a2 2 0 010 4h-.09a1.65 1.65 0 00-1.51 1z"/></svg>',
    '<svg class="icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 8A6 6 0 006 8c0 7-3 9-3 9h18s-3-2-3-9M13.73 21a2 2 0 01-3.46 0"/></svg>',
]

# Repeated class name combos (real HTML uses the same class combos everywhere)
COMMON_CLASS_COMBOS = [
    'class="btn btn-primary"',
    'class="btn btn-secondary"',
    'class="btn btn-outline"',
    'class="btn btn-sm"',
    'class="btn btn-icon"',
    'class="card"',
    'class="card-header"',
    'class="card-body"',
    'class="card-footer"',
    'class="form-group"',
    'class="form-control"',
    'class="form-label"',
    'class="nav-item"',
    'class="nav-link"',
    'class="nav-link active"',
    'class="list-item"',
    'class="list-group"',
    'class="d-flex align-items-center"',
    'class="d-flex justify-content-between"',
    'class="d-flex align-items-center gap-2"',
    'class="d-flex flex-column"',
    'class="d-none d-md-block"',
    'class="text-muted"',
    'class="text-center"',
    'class="container"',
    'class="row"',
    'class="col"',
    'class="col-md-6"',
    'class="col-lg-4"',
    'class="mt-2"',
    'class="mt-3"',
    'class="mb-2"',
    'class="mb-3"',
    'class="p-3"',
    'class="p-4"',
    'class="badge badge-primary"',
    'class="badge badge-secondary"',
    'class="alert alert-success"',
    'class="alert alert-danger"',
    'class="avatar avatar-sm"',
    'class="tooltip"',
    'class="dropdown-menu"',
    'class="dropdown-item"',
    'class="modal-overlay"',
    'class="modal-content"',
    'class="sr-only"',
    'class="skeleton skeleton-text"',
    'class="spinner spinner-sm"',
    'class="table-row"',
    'class="table-cell"',
    'class="tab-panel"',
    'class="tab-list"',
    'class="section-header"',
    'class="section-body"',
    'class="sidebar-item"',
    'class="header-inner d-flex align-items-center"',
    'class="footer-inner"',
]


def gen_html_attr():
    """Generate HTML attributes, heavily reusing common class combos."""
    if random.random() < 0.60:
        # Use a common class combo
        combo = random.choice(COMMON_CLASS_COMBOS)
        extras = []
        if random.random() < 0.4:
            extras.append(f'data-{random.choice(["id","type","state","action"])}="{random.choice(JS_VAR_PREFIXES)}{random.choice(JS_NOUNS)}"')
        if random.random() < 0.2:
            extras.append(f'aria-{random.choice(["label","hidden","expanded"])}="{random.choice(["true","false"])}"')
        return combo + (' ' + ' '.join(extras) if extras else '')
    else:
        return ' '.join(random.choice(HTML_ATTRS)() for _ in range(random.randint(1, 4)))


def gen_html_element(depth=0, max_depth=4):
    """Generate an HTML element with optional nesting."""
    tag = random.choice(HTML_TAGS)
    attrs = gen_html_attr()
    void_tags = {'img', 'input', 'hr', 'br', 'source', 'meta', 'link'}
    if tag in void_tags:
        return f'<{tag} {attrs}/>'
    if depth >= max_depth or random.random() < 0.3:
        text = random.choice(HTML_TEXTS)
        return f'<{tag} {attrs}>{text}</{tag}>'
    children = ''.join(gen_html_element(depth+1, max_depth) for _ in range(random.randint(1, 4)))
    return f'<{tag} {attrs}>{children}</{tag}>'


def gen_html_card():
    """Generate a repeating card component (very common in real apps)."""
    icon = random.choice(INLINE_SVG_ICONS)
    title = random.choice(HTML_TEXTS)
    text = random.choice(HTML_TEXTS)
    badge_cls = random.choice(['"badge badge-primary"', '"badge badge-secondary"', '"badge"'])
    return (
        f'<div class="card">'
        f'<div class="card-header d-flex align-items-center">{icon}<span class="card-title">{title}</span>'
        f'<span class={badge_cls}>{random.randint(1,99)}</span></div>'
        f'<div class="card-body"><p class="text-muted">{text}</p></div>'
        f'<div class="card-footer d-flex justify-content-between">'
        f'<button class="btn btn-sm btn-outline">{icon} Edit</button>'
        f'<button class="btn btn-sm btn-primary">View</button></div></div>'
    )


def gen_html_table_rows(count):
    """Generate repeated table rows."""
    rows = []
    for i in range(count):
        cells = []
        cells.append(f'<td class="table-cell">{i+1}</td>')
        cells.append(f'<td class="table-cell">{random.choice(JS_NOUNS)}</td>')
        cells.append(f'<td class="table-cell text-muted">{random.choice(HTML_TEXTS)}</td>')
        cells.append(f'<td class="table-cell"><span class="badge badge-{random.choice(["primary","secondary","success","danger"])}">{random.choice(["Active","Inactive","Pending","Error"])}</span></td>')
        cells.append(f'<td class="table-cell"><button class="btn btn-sm btn-icon">{random.choice(INLINE_SVG_ICONS)}</button></td>')
        rows.append(f'<tr class="table-row">{"".join(cells)}</tr>')
    return ''.join(rows)


def gen_html_list_items(count):
    """Generate repeated list items."""
    items = []
    for _ in range(count):
        icon = random.choice(INLINE_SVG_ICONS)
        text = random.choice(HTML_TEXTS)
        items.append(
            f'<li class="list-item d-flex align-items-center">'
            f'{icon}<span class="list-item-text">{text}</span>'
            f'<span class="text-muted">{random.randint(0,999)}</span></li>'
        )
    return ''.join(items)


def gen_html_nav():
    """Generate a navigation section with repeated links."""
    links = []
    for _ in range(random.randint(5, 12)):
        icon = random.choice(INLINE_SVG_ICONS)
        text = random.choice(HTML_TEXTS).split()[0]
        active = ' active' if random.random() < 0.15 else ''
        links.append(f'<a class="nav-link{active}" href="#">{icon}<span>{text}</span></a>')
    return f'<nav class="nav"><div class="nav-list">{"".join(links)}</div></nav>'


def generate_html(target_kb, kind='header'):
    """Generate HTML content targeting approximately target_kb kilobytes."""
    parts = ['<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">']
    parts.append('<meta name="viewport" content="width=device-width,initial-scale=1">')
    parts.append(f'<title>{random.choice(HTML_TEXTS)}</title>')
    # Link tags (repeated)
    for css_file in ['reset', 'layout', 'theme', 'components', 'utilities']:
        parts.append(f'<link rel="stylesheet" href="/static/{css_file}.css">')
    parts.append('<link rel="icon" href="/static/logo.svg" type="image/svg+xml">')
    parts.append('<link rel="manifest" href="/static/manifest.json">')
    parts.append('</head><body>')

    target_bytes = target_kb * 1024
    while len(''.join(parts)) < target_bytes - 100:
        r = random.random()
        if r < 0.20:
            # Card components (repeating)
            parts.append('<div class="row">')
            for _ in range(random.randint(2, 4)):
                parts.append(f'<div class="col-lg-4 col-md-6">{gen_html_card()}</div>')
            parts.append('</div>')
        elif r < 0.35:
            # Table with repeated rows
            parts.append('<div class="table-wrapper"><table class="table"><thead class="table-header"><tr>')
            for h in ['#', 'Name', 'Description', 'Status', 'Actions']:
                parts.append(f'<th class="table-cell">{h}</th>')
            parts.append('</tr></thead><tbody class="table-body">')
            parts.append(gen_html_table_rows(random.randint(5, 15)))
            parts.append('</tbody></table></div>')
        elif r < 0.50:
            # List with repeated items
            parts.append(f'<div class="section"><div class="section-header"><h2>{random.choice(HTML_TEXTS)}</h2></div>')
            parts.append(f'<ul class="list-group">{gen_html_list_items(random.randint(5, 12))}</ul></div>')
        elif r < 0.60:
            # Navigation (repeated structure)
            parts.append(gen_html_nav())
        elif r < 0.70:
            # Form with repeated form groups
            parts.append('<form class="form">')
            for _ in range(random.randint(3, 6)):
                label = random.choice(HTML_TEXTS).split()[0]
                parts.append(
                    f'<div class="form-group"><label class="form-label">{label}</label>'
                    f'<input class="form-control" type="{random.choice(["text","email","password","number"])}" '
                    f'placeholder="{label}"/>'
                    f'<span class="form-text text-muted">Enter your {label.lower()}</span></div>'
                )
            parts.append('<button class="btn btn-primary" type="submit">Submit</button></form>')
        else:
            # Generic nested elements
            parts.append(gen_html_element(0, 5))

    # Script tags at bottom (repeated pattern)
    for js_file in ['vendor', 'app', 'analytics', 'helpers', 'router']:
        parts.append(f'<script src="/static/{js_file}.js" defer></script>')

    parts.append('</body></html>')
    return ''.join(parts)[:target_bytes]


# --- SVG generation ---

# Reusable path data fragments (real icon sets share similar path structures)
SVG_COMMON_PATHS = [
    'M3 12h18', 'M3 6h18', 'M3 18h18',  # menu lines
    'M12 5v14', 'M5 12h14',  # plus/cross arms
    'M6 9l6 6 6-6', 'M18 15l-6-6-6 6',  # chevrons
    'M5 12h14M12 5l7 7-7 7',  # arrow right
    'M19 12H5M12 19l-7-7 7-7',  # arrow left
    'M18 6L6 18M6 6l12 12',  # close X
    'M20 6L9 17l-5-5',  # check
    'M4 4h16v16H4z',  # square
    'M4 4l16 16M4 20L20 4',  # X mark
    'M12 2L2 7l10 5 10-5-10-5z',  # diamond top
    'M2 17l10 5 10-5',  # diamond bottom
    'M12 22V12', 'M12 2v10',  # vertical lines
    'M2 12h10', 'M12 12h10',  # horizontal halves
]

SVG_COMMON_ATTRS = [
    'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"',
    'fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"',
    'fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"',
    'fill="currentColor"',
    'fill="currentColor" opacity=".5"',
    'fill="none" stroke="currentColor" stroke-width="2"',
]


def gen_svg_path():
    """Generate a realistic SVG path data string."""
    cmds = []
    x, y = random.randint(2, 20), random.randint(2, 20)
    cmds.append(f'M{x} {y}')
    for _ in range(random.randint(5, 20)):
        cmd = random.choice(['L', 'l', 'C', 'c', 'Q', 'q', 'A', 'a', 'H', 'h', 'V', 'v', 'Z'])
        if cmd in ('Z', 'z'):
            cmds.append('Z')
            break
        elif cmd in ('H', 'h'):
            cmds.append(f'{cmd}{random.randint(-10, 10)}')
        elif cmd in ('V', 'v'):
            cmds.append(f'{cmd}{random.randint(-10, 10)}')
        elif cmd in ('L', 'l'):
            cmds.append(f'{cmd}{random.randint(0, 22)} {random.randint(0, 22)}')
        elif cmd in ('C', 'c'):
            pts = ' '.join(f'{random.randint(0, 24)} {random.randint(0, 24)}' for _ in range(3))
            cmds.append(f'{cmd}{pts}')
        elif cmd in ('Q', 'q'):
            pts = ' '.join(f'{random.randint(0, 24)} {random.randint(0, 24)}' for _ in range(2))
            cmds.append(f'{cmd}{pts}')
        elif cmd in ('A', 'a'):
            rx, ry = random.randint(2, 12), random.randint(2, 12)
            cmds.append(f'{cmd}{rx} {ry} 0 {random.choice([0,1])} {random.choice([0,1])} {random.randint(0, 22)} {random.randint(0, 22)}')
    if cmds[-1] != 'Z':
        cmds.append('Z')
    return ''.join(cmds)


def gen_svg_icon(name):
    """Generate an SVG icon symbol."""
    parts = []
    attrs = random.choice(SVG_COMMON_ATTRS)
    # 40% chance: include a common reusable path fragment
    if random.random() < 0.40:
        common_path = random.choice(SVG_COMMON_PATHS)
        parts.append(f'<path d="{common_path}" {attrs}/>')
    # Add 1-3 unique paths
    for _ in range(random.randint(1, 3)):
        parts.append(f'<path d="{gen_svg_path()}" {attrs}/>')
    # Extra shapes with repeated attributes
    if random.random() < 0.3:
        cx, cy, r = random.randint(4, 20), random.randint(4, 20), random.randint(2, 8)
        parts.append(f'<circle cx="{cx}" cy="{cy}" r="{r}" {attrs}/>')
    if random.random() < 0.2:
        x, y, w, h = random.randint(2, 8), random.randint(2, 8), random.randint(6, 16), random.randint(6, 16)
        rx = random.choice([0, 1, 2, 3])
        parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" {attrs}/>')
    if random.random() < 0.15:
        pts = ' '.join(f'{random.randint(2,22)},{random.randint(2,22)}' for _ in range(random.randint(3, 6)))
        parts.append(f'<polygon points="{pts}" {attrs}/>')
    return f'<symbol id="{name}" viewBox="0 0 24 24">{"".join(parts)}</symbol>'


def generate_icon_sprite(target_kb):
    """Generate an SVG icon sprite sheet."""
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" style="display:none">']
    parts.append('<defs>')
    target_bytes = target_kb * 1024
    icon_counter = 0
    # Generate multiple variants of each icon name (real icon sets have many variants)
    variants = ['', '-alt', '-filled', '-outlined', '-rounded', '-sharp', '-thin', '-bold',
                '-solid', '-light', '-duotone', '-sm', '-lg', '-xl']
    while len(''.join(parts)) < target_bytes - 200:
        base_name = SVG_ICON_NAMES[icon_counter % len(SVG_ICON_NAMES)]
        variant = variants[icon_counter // len(SVG_ICON_NAMES) % len(variants)]
        name = base_name + variant
        parts.append(gen_svg_icon(name))
        icon_counter += 1
    parts.append('</defs></svg>')
    return ''.join(parts)[:target_bytes]


def generate_logo_svg(target_kb):
    """Generate a detailed SVG logo."""
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 60">']
    # Background
    parts.append(f'<rect width="200" height="60" rx="8" fill="{random.choice(COLORS)}"/>')
    target_bytes = target_kb * 1024
    # Add reusable defs for gradients and filters (compresses well due to repetition)
    parts.append('<defs>')
    for i in range(5):
        c1, c2 = pick_color(), pick_color()
        parts.append(f'<linearGradient id="g{i}" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="{c1}"/><stop offset="100%" stop-color="{c2}"/></linearGradient>')
    parts.append('</defs>')

    while len(''.join(parts)) < target_bytes - 50:
        r = random.random()
        if r < 0.25:
            grad = f'url(#g{random.randint(0,4)})' if random.random() < 0.5 else pick_color()
            parts.append(f'<path d="{gen_svg_path()}" fill="{grad}" opacity="{random.choice([".3",".5",".7",".8","1"])}"/>')
        elif r < 0.45:
            cx, cy, rx, ry = random.randint(10, 190), random.randint(5, 55), random.randint(3, 20), random.randint(3, 15)
            parts.append(f'<ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="{pick_color()}" opacity=".6"/>')
        elif r < 0.65:
            x, y = random.randint(10, 150), random.randint(10, 50)
            parts.append(f'<text x="{x}" y="{y}" font-family="sans-serif" font-size="{random.randint(10, 28)}" font-weight="{random.choice(["400","600","700","800"])}" fill="{pick_color()}">{random.choice(["Arena","HTTP","Web","App","Hub","Dev","Pro","Lab"])}</text>')
        elif r < 0.80:
            x, y, w, h = random.randint(5, 160), random.randint(5, 45), random.randint(10, 40), random.randint(5, 20)
            parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{random.randint(0,6)}" fill="{pick_color()}" opacity=".5"/>')
        else:
            # Repeated decorative circles (compresses well)
            cx, cy, r2 = random.randint(5, 195), random.randint(5, 55), random.randint(1, 8)
            parts.append(f'<circle cx="{cx}" cy="{cy}" r="{r2}" fill="{pick_color()}" opacity=".4"/>')
    parts.append('</svg>')
    return ''.join(parts)[:target_bytes]


def generate_manifest(target_kb):
    """Generate a web app manifest."""
    icons = [{"src": f"/icons/icon-{s}x{s}.png", "sizes": f"{s}x{s}", "type": "image/png", "purpose": random.choice(["any","maskable","any maskable"])}
             for s in [48, 72, 96, 128, 144, 152, 192, 256, 384, 512]]
    shortcuts = [{"name": t, "short_name": t.split()[0], "url": f"/{t.lower().replace(' ','-')}", "description": f"Go to {t}"}
                 for t in random.sample(HTML_TEXTS, 6)]
    screenshots = [{"src": f"/screenshots/screen-{i}.png", "sizes": f"{random.choice(['1280x720','1920x1080','750x1334'])}",
                    "type": "image/png", "form_factor": random.choice(["wide","narrow"])} for i in range(4)]
    manifest = {
        "name": "HttpArena Web Application",
        "short_name": "HttpArena",
        "description": "A comprehensive HTTP framework benchmarking platform for comparing web server performance across multiple protocols and configurations",
        "start_url": "/",
        "scope": "/",
        "display": "standalone",
        "orientation": "any",
        "theme_color": "#1a1a2e",
        "background_color": "#ffffff",
        "categories": ["developer tools", "productivity", "utilities"],
        "lang": "en-US",
        "dir": "ltr",
        "icons": icons,
        "shortcuts": shortcuts,
        "screenshots": screenshots,
        "prefer_related_applications": False,
        "related_applications": [
            {"platform": "play", "url": "https://play.google.com/store/apps/details?id=com.httparena.app", "id": "com.httparena.app"},
            {"platform": "itunes", "url": "https://apps.apple.com/app/httparena/id123456789"}
        ],
        "protocol_handlers": [
            {"protocol": "web+httparena", "url": "/protocol?uri=%s"}
        ],
        "share_target": {
            "action": "/share",
            "method": "POST",
            "enctype": "multipart/form-data",
            "params": {"title": "title", "text": "text", "url": "url"}
        }
    }
    return json.dumps(manifest, separators=(',', ':'))


# --- Binary file generation ---

def generate_webp(target_kb):
    """Generate a valid WebP file of approximately target_kb."""
    # WebP file format: RIFF header + VP8 lossy bitstream
    target_bytes = target_kb * 1024
    # Use VP8L (lossless) format which is simpler to generate
    # RIFF header
    data = bytearray()

    # For a valid but simple WebP, we'll create a VP8 (lossy) container
    # with enough filler data to reach our target size
    width = random.randint(800, 1920)
    height = random.randint(400, 1080)

    # VP8 bitstream - minimal valid frame
    vp8_data = bytearray()
    # Frame tag (keyframe)
    frame_tag = (0 & 0x1) | ((0 & 0x7) << 1) | ((1 & 0x1) << 4)  # keyframe, version 0, show_frame
    size_part = len(b'\x9d\x01\x2a') + 4  # start code + dimensions placeholder
    vp8_data.append(frame_tag & 0xff)
    vp8_data.append((frame_tag >> 8) & 0xff)
    vp8_data.append((frame_tag >> 16) & 0xff)
    # VP8 start code
    vp8_data.extend(b'\x9d\x01\x2a')
    # Width and height (little-endian, 14 bits each + scale)
    vp8_data.extend(struct.pack('<H', width & 0x3fff))
    vp8_data.extend(struct.pack('<H', height & 0x3fff))
    # Fill with random data to simulate compressed image data
    remaining = target_bytes - 20 - len(vp8_data)  # 20 = RIFF(4) + size(4) + WEBP(4) + VP8_(4) + chunk_size(4)
    vp8_data.extend(random.randbytes(max(remaining, 100)))

    # Build RIFF container
    chunk_data = b'VP8 ' + struct.pack('<I', len(vp8_data)) + bytes(vp8_data)
    riff_data = b'WEBP' + chunk_data
    data = b'RIFF' + struct.pack('<I', len(riff_data)) + riff_data

    return bytes(data[:target_bytes])


def generate_woff2(target_kb):
    """Generate a realistic-sized binary blob mimicking woff2 structure."""
    target_bytes = target_kb * 1024
    # WOFF2 header
    data = bytearray()
    data.extend(b'wOF2')  # signature
    data.extend(struct.pack('>I', 0x00010000))  # flavor (TrueType)
    data.extend(struct.pack('>I', target_bytes))  # length
    data.extend(struct.pack('>H', 9))  # numTables
    data.extend(struct.pack('>H', 0))  # reserved
    data.extend(struct.pack('>I', target_bytes))  # totalSfntSize
    data.extend(struct.pack('>I', 0))  # totalCompressedSize
    data.extend(struct.pack('>H', 1))  # majorVersion
    data.extend(struct.pack('>H', 0))  # minorVersion
    data.extend(struct.pack('>I', 0))  # metaOffset
    data.extend(struct.pack('>I', 0))  # metaLength
    data.extend(struct.pack('>I', 0))  # metaOrigLength
    data.extend(struct.pack('>I', 0))  # privOffset
    data.extend(struct.pack('>I', 0))  # privLength
    # Fill remaining with random data
    remaining = target_bytes - len(data)
    data.extend(random.randbytes(max(remaining, 0)))
    return bytes(data[:target_bytes])


def add_entropy(content, target_ratio=0.33):
    """Inject unique tokens into content to reduce compressibility toward target_ratio.
    target_ratio is compressed/original (e.g. 0.33 means compressed is 1/3 of original).
    """
    if isinstance(content, str):
        data = content.encode('utf-8')
    else:
        data = content
    original_size = len(data)

    # Check current ratio
    current_br = len(brotli.compress(data, quality=11))
    current_ratio = current_br / original_size
    if current_ratio >= target_ratio:
        return content  # already at or above target

    # Binary search for the right amount of entropy to inject
    # Strategy: replace random positions with unique hex strings
    text = content if isinstance(content, str) else content.decode('utf-8', errors='replace')
    best = text
    # Inject unique comments/tokens at regular intervals
    inject_pct = 0.0
    step = 0.05
    while inject_pct < 0.8:
        inject_pct += step
        # Generate unique tokens
        num_injections = int(original_size * inject_pct / 16)
        positions = sorted(random.sample(range(max(1, len(text) - 1)), min(num_injections, len(text) - 1)))
        parts = []
        prev = 0
        uid = 0
        for pos in positions:
            parts.append(text[prev:pos])
            # Inject a unique hex token that won't compress well
            parts.append(f'{uid:04x}{random.getrandbits(32):08x}')
            uid += 1
            prev = pos
        parts.append(text[prev:])
        candidate = ''.join(parts)[:original_size]
        # Pad to original size if needed
        while len(candidate.encode('utf-8')) < original_size:
            candidate += f'{random.getrandbits(64):016x}'
        candidate = candidate.encode('utf-8')[:original_size].decode('utf-8', errors='ignore')

        br_size = len(brotli.compress(candidate.encode('utf-8'), quality=11))
        ratio = br_size / len(candidate.encode('utf-8'))
        if ratio >= target_ratio * 0.9:  # within 10% of target
            return candidate
    return best


# --- Main generation ---

def compress_and_save(filepath, content):
    """Save file and its compressed variants."""
    if isinstance(content, str):
        data = content.encode('utf-8')
    else:
        data = content
    with open(filepath, 'wb') as f:
        f.write(data)
    # gzip level 9
    gz_path = filepath + '.gz'
    with open(gz_path, 'wb') as f:
        f.write(gzip.compress(data, compresslevel=9))
    # brotli level 11
    if HAS_BROTLI:
        br_path = filepath + '.br'
        with open(br_path, 'wb') as f:
            f.write(brotli.compress(data, quality=11))
    orig_size = len(data)
    gz_size = os.path.getsize(gz_path)
    br_size = os.path.getsize(br_path) if HAS_BROTLI else 0
    gz_ratio = (1 - gz_size / orig_size) * 100 if orig_size else 0
    br_ratio = (1 - br_size / orig_size) * 100 if orig_size and HAS_BROTLI else 0
    name = os.path.basename(filepath)
    print(f'  {name:30s} {orig_size:>8,}  gz:{gz_size:>8,} ({gz_ratio:.0f}%)  br:{br_size:>8,} ({br_ratio:.0f}%)')


def save_binary(filepath, content):
    """Save binary file without compression."""
    with open(filepath, 'wb') as f:
        f.write(content)
    name = os.path.basename(filepath)
    print(f'  {name:30s} {len(content):>8,}  (binary, no pre-compression)')


def main():
    os.makedirs(OUT, exist_ok=True)
    if not HAS_BROTLI:
        print('WARNING: brotli module not found, .br files will not be generated')
        print('  Install with: pip install brotli')
        return

    print('Generating static files...\n')
    print(f'  {"File":30s} {"Original":>8s}  {"Gzip-9":>14s}  {"Brotli-11":>14s}')
    print(f'  {"-"*30} {"-"*8}  {"-"*14}  {"-"*14}')

    # CSS files — realistic spread: reset is tiny, components is big
    compress_and_save(os.path.join(OUT, 'reset.css'),
                      generate_css(8, include_vars=True))            # ~1.5 KB br
    compress_and_save(os.path.join(OUT, 'layout.css'),
                      generate_css(25, include_media=True))          # ~4 KB br
    compress_and_save(os.path.join(OUT, 'theme.css'),
                      generate_css(18, include_vars=True, include_keyframes=True))  # ~3 KB br
    compress_and_save(os.path.join(OUT, 'components.css'),
                      generate_css(200, include_media=True, include_keyframes=True)) # ~35 KB br
    compress_and_save(os.path.join(OUT, 'utilities.css'),
                      generate_css(60, include_media=True))          # ~10 KB br

    # JS files — vendor is huge, analytics is small
    compress_and_save(os.path.join(OUT, 'analytics.js'), generate_js(12))   # ~3 KB br
    compress_and_save(os.path.join(OUT, 'helpers.js'), generate_js(22))     # ~5 KB br
    compress_and_save(os.path.join(OUT, 'app.js'), generate_js(200))         # ~48 KB br
    compress_and_save(os.path.join(OUT, 'vendor.js'), generate_js(300))     # ~72 KB br
    compress_and_save(os.path.join(OUT, 'router.js'), generate_js(35))      # ~8 KB br

    # HTML files — header is bigger than footer
    compress_and_save(os.path.join(OUT, 'header.html'), generate_html(120, 'header'))  # ~6 KB br
    compress_and_save(os.path.join(OUT, 'footer.html'), generate_html(55, 'footer'))   # ~3 KB br

    # SVG files — icon sprite is bigger than logo
    compress_and_save(os.path.join(OUT, 'icon-sprite.svg'), generate_icon_sprite(70))  # ~11 KB br
    compress_and_save(os.path.join(OUT, 'logo.svg'), generate_logo_svg(15))            # ~2 KB br

    # JSON manifest — small PWA config
    compress_and_save(os.path.join(OUT, 'manifest.json'), generate_manifest(2))        # ~0.7 KB br

    # Binary files — hero is big, thumbs are small
    save_binary(os.path.join(OUT, 'hero.webp'), generate_webp(45))      # 45 KB
    save_binary(os.path.join(OUT, 'thumb1.webp'), generate_webp(8))     # 8 KB
    save_binary(os.path.join(OUT, 'thumb2.webp'), generate_webp(6))     # 6 KB
    save_binary(os.path.join(OUT, 'regular.woff2'), generate_woff2(18)) # 18 KB
    save_binary(os.path.join(OUT, 'bold.woff2'), generate_woff2(22))    # 22 KB

    # Summary
    print()
    text_total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT)
                     if not f.endswith(('.gz', '.br', '.webp', '.woff2')))
    binary_total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT)
                       if f.endswith(('.webp', '.woff2')) and not f.endswith(('.gz', '.br')))
    gz_total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT) if f.endswith('.gz'))
    br_total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT) if f.endswith('.br'))
    print(f'  Text total:   {text_total:>10,} bytes ({text_total/1024:.0f} KB)')
    print(f'  Binary total: {binary_total:>10,} bytes ({binary_total/1024:.0f} KB)')
    print(f'  Grand total:  {(text_total+binary_total):>10,} bytes ({(text_total+binary_total)/1024:.0f} KB)')
    print(f'  Gzip total:   {gz_total:>10,} bytes ({gz_total/1024:.0f} KB) — {(1-gz_total/text_total)*100:.0f}% reduction')
    print(f'  Brotli total: {br_total:>10,} bytes ({br_total/1024:.0f} KB) — {(1-br_total/text_total)*100:.0f}% reduction')


if __name__ == '__main__':
    main()
