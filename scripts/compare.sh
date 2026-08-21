#!/usr/bin/env bash
# Compare benchmark results for a framework against published data on main.
#
# Usage: ./scripts/compare.sh <framework> [profile] [--compare <framework>]
#
# By default the baseline is the same framework's own published results, which
# answers "did my change help?". --compare swaps in another framework's
# published results instead, which answers "how does this tuned build stack up
# against the entry it derives from?" — e.g.
#
#     ./scripts/compare.sh genhttp-11 --compare genhttp-11-kestrel
#
# Output: Markdown table with deltas (suitable for PR comments)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

FRAMEWORK=""
PROFILE_FILTER=""
COMPARE_FRAMEWORK=""
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --compare)   COMPARE_FRAMEWORK="${2:-}"; shift ;;
        --compare=*) COMPARE_FRAMEWORK="${1#*=}" ;;
        *)           POSITIONAL+=("$1") ;;
    esac
    shift
done
FRAMEWORK="${POSITIONAL[0]:-}"
PROFILE_FILTER="${POSITIONAL[1]:-}"

if [ -z "$FRAMEWORK" ]; then
    echo "Usage: $0 <framework> [profile] [--compare <framework>]" >&2
    exit 1
fi

# Read display name from meta.json
META_FILE="$ROOT_DIR/frameworks/$FRAMEWORK/meta.json"
DISPLAY_NAME="$FRAMEWORK"
if [ -f "$META_FILE" ]; then
    dn=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('display_name',sys.argv[2]))" "$META_FILE" "$FRAMEWORK" 2>/dev/null)
    [ -n "$dn" ] && DISPLAY_NAME="$dn"
fi

# The baseline is looked up in site/data by display_name, so resolve the
# comparison framework's the same way. A directory that doesn't exist is a
# typo worth reporting rather than silently comparing against nothing.
COMPARE_DISPLAY=""
if [ -n "$COMPARE_FRAMEWORK" ]; then
    COMPARE_META="$ROOT_DIR/frameworks/$COMPARE_FRAMEWORK/meta.json"
    if [ ! -f "$COMPARE_META" ]; then
        echo "No such framework to compare against: \`$COMPARE_FRAMEWORK\` (frameworks/$COMPARE_FRAMEWORK/meta.json not found)"
        exit 0
    fi
    COMPARE_DISPLAY=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('display_name',sys.argv[2]))" "$COMPARE_META" "$COMPARE_FRAMEWORK" 2>/dev/null)
    [ -n "$COMPARE_DISPLAY" ] || COMPARE_DISPLAY="$COMPARE_FRAMEWORK"
fi

# Find new results (just benchmarked)
RESULTS_DIR="$ROOT_DIR/results"
SITE_DATA="$ROOT_DIR/site/data"

# Collect all profiles with results for this framework
python3 -c "
import json, os, re, sys, glob

framework = sys.argv[1]
display_name = sys.argv[2]
results_dir = sys.argv[3]
site_data = sys.argv[4]
profile_filter = sys.argv[5] if len(sys.argv) > 5 else ''
compare_display = sys.argv[6] if len(sys.argv) > 6 else ''

# Baseline: this framework's own published results by default, another
# framework's when --compare was given.
baseline_name = compare_display or display_name
cross = bool(compare_display)

# Find new results
new_results = {}
for result_file in sorted(glob.glob(f'{results_dir}/*/{framework}.json') + glob.glob(f'{results_dir}/*/*/{framework}.json')):
    parts = result_file.replace(results_dir + '/', '').split('/')
    if len(parts) == 2:
        profile, _ = parts[0], parts[1]
        conns = 'best'
    elif len(parts) == 3:
        profile, conns_str, _ = parts
        conns = conns_str
    else:
        continue

    if profile_filter and profile != profile_filter:
        continue

    try:
        with open(result_file) as f:
            data = json.load(f)
        key = f'{profile}/{conns}'
        new_results[key] = data
    except:
        continue

if not new_results:
    print(f'No results found for \`{framework}\`')
    sys.exit(0)

# Find old results from site/data (published on main). Results are one file
# per framework keyed by <profile>-<conns> (#751), so this is a single read.
def _slug(name):
    return (re.sub(r'[^A-Za-z0-9._-]+', '-', name).strip('-') or 'unnamed').lower()

old_results = {}
baseline_file = f'{site_data}/results/{_slug(baseline_name)}.json'
if os.path.exists(baseline_file):
    try:
        with open(baseline_file) as f:
            published = (json.load(f).get('results') or {})
        for key in new_results:
            profile, conns = key.split('/')
            entry = published.get(f'{profile}-{conns}')
            if entry:
                old_results[key] = entry
    except:
        pass

# Format helpers
def fmt_num(n):
    if n is None or n == 0:
        return '—'
    if isinstance(n, float):
        return f'{n:,.1f}'
    return f'{int(n):,}'

def fmt_rps(n):
    if n >= 1_000_000:
        return f'{n/1_000_000:.2f}M'
    if n >= 1_000:
        return f'{n/1_000:.1f}K'
    return str(int(n))

def delta_pct(new_val, old_val):
    if old_val is None or old_val == 0 or new_val is None:
        return 'n/a' if cross else 'NEW'
    pct = ((new_val - old_val) / old_val) * 100
    if abs(pct) < 0.1:
        return '~0%'
    sign = '+' if pct > 0 else ''
    return f'{sign}{pct:.1f}%'

def parse_latency_us(s):
    if not s or s == '—' or s == '\u2014':
        return None
    s = str(s).strip()
    if s.endswith('us'):
        return float(s[:-2])
    if s.endswith('ms'):
        return float(s[:-2]) * 1000
    if s.endswith('s'):
        return float(s[:-1]) * 1_000_000
    try:
        return float(s)
    except:
        return None

def parse_mem_mb(s):
    if not s or s == '—' or s == '\u2014':
        return None
    s = str(s).strip()
    if 'GiB' in s or 'GB' in s:
        return float(s.replace('GiB','').replace('GB','').strip()) * 1024
    if 'MiB' in s or 'MB' in s:
        return float(s.replace('MiB','').replace('MB','').strip())
    if 'KiB' in s or 'KB' in s:
        return float(s.replace('KiB','').replace('KB','').strip()) / 1024
    try:
        return float(s)
    except:
        return None

def parse_cpu(s):
    if not s or s == '—' or s == '\u2014':
        return None
    return float(str(s).replace('%','').strip())

# Group by profile
profiles = {}
for key in sorted(new_results.keys()):
    profile, conns = key.split('/')
    if profile not in profiles:
        profiles[profile] = []
    profiles[profile].append(conns)

# Output markdown
has_comparison = bool(old_results)

if cross:
    if has_comparison:
        print(f'Deltas are against **{baseline_name}** published on \`main\`, not against '
              f'\`{display_name}\`\'s own results.')
    else:
        print(f'**{baseline_name}** has no published results for these profiles - nothing to compare against.')
    print()

for profile, conns_list in profiles.items():
    print(f'### {profile}')
    print()

    # Table header
    header = '| Metric |'
    separator = '|--------|'
    for conns in conns_list:
        header += f' {conns}c |  |'
        separator += '------|--|'
    print(header)
    print(separator)

    # Rows: RPS, p99, CPU, Memory
    metrics = [
        ('RPS', lambda d: d.get('rps', 0), fmt_rps),
        ('p99', lambda d: parse_latency_us(d.get('p99_latency')), lambda v: f'{v:.0f}us' if v and v < 1000 else (f'{v/1000:.2f}ms' if v else '—')),
        ('CPU', lambda d: parse_cpu(d.get('cpu')), lambda v: f'{v:.0f}%' if v else '—'),
        ('Memory', lambda d: parse_mem_mb(d.get('memory')), lambda v: f'{v:.0f}MB' if v else '—'),
    ]

    for label, extract, fmt in metrics:
        row = f'| **{label}** |'
        for conns in conns_list:
            key = f'{profile}/{conns}'
            new = new_results.get(key)
            old = old_results.get(key)

            new_val = extract(new) if new else None
            old_val = extract(old) if old else None

            formatted = fmt(new_val) if new_val is not None else '—'
            d = delta_pct(new_val, old_val)

            row += f' {formatted} | {d} |'
        print(row)

    print()
" "$FRAMEWORK" "$DISPLAY_NAME" "$RESULTS_DIR" "$SITE_DATA" "$PROFILE_FILTER" "$COMPARE_DISPLAY"
