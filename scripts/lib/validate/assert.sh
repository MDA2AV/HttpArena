# scripts/lib/validate/assert.sh — DOCS_BASE, check helpers, wait_h2, static-freshness probe
# Part of the validate.sh suite — sourced by scripts/validate.sh, not run directly.

# ───── Helpers ─────

DOCS_BASE="https://www.http-arena.com/#doc=test-profiles"

fail_with_link() {
    local msg="$1"
    local docs_url="$2"
    echo "  FAIL $msg"
    if [ -n "$docs_url" ]; then
        echo "        → $docs_url"
    fi
    FAIL=$((FAIL + 1))
}

dump_debug() {
    local trace="$1"
    local response="$2"
    if [ -n "$trace" ] && [ -s "$trace" ]; then
        echo "        ─── wire trace ───"
        sed 's/^/        /' "$trace"
    fi
    if [ -n "$response" ]; then
        echo "        ─── response ───"
        printf '%s\n' "$response" | sed 's/^/        /'
    fi
    [ -n "$trace" ] && rm -f "$trace"
}

check() {
    local label="$1"
    local expected_body="$2"
    local docs_url="$3"
    shift 3
    local response trace
    trace=$(mktemp)
    response=$(curl -s --max-time 30 -D- --trace-ascii "$trace" "$@" || true)
    local body
    body=$(echo "$response" | tail -1)

    if [ "$body" = "$expected_body" ]; then
        echo "  PASS [$label]"
        PASS=$((PASS + 1))
        rm -f "$trace"
    else
        fail_with_link "[$label]: expected body '$expected_body', got '$body'" "$docs_url"
        dump_debug "$trace" "$response"
    fi
}

check_status() {
    local label="$1"
    local expected_status="$2"
    local docs_url="$3"
    shift 3
    local http_code trace body_file
    trace=$(mktemp)
    body_file=$(mktemp)
    http_code=$(curl -s --max-time 30 -o "$body_file" -D "$body_file.hdr" -w '%{http_code}' --trace-ascii "$trace" "$@" || true)

    if [ "$http_code" = "$expected_status" ]; then
        echo "  PASS [$label] (HTTP $http_code)"
        PASS=$((PASS + 1))
        rm -f "$trace" "$body_file" "$body_file.hdr"
    else
        fail_with_link "[$label]: expected HTTP $expected_status, got HTTP $http_code" "$docs_url"
        local response=""
        [ -s "$body_file.hdr" ] && response=$(cat "$body_file.hdr")
        [ -s "$body_file" ] && response="${response}$(cat "$body_file")"
        dump_debug "$trace" "$response"
        rm -f "$body_file" "$body_file.hdr"
    fi
}

check_fragmented() {
    # Send an HTTP request in multiple TCP writes with small pauses between
    # them so the server's read loop sees partial, incomplete buffers and
    # must reassemble across recv() calls. Exercises HTTP parser correctness
    # under realistic network fragmentation (slow clients, small MTU, etc.).
    #
    # Usage: check_fragmented <label> <expected_body> <docs_url> <frag1> <frag2> [frag3...]
    # Use $'...' literal form in the caller to embed CR/LF inside fragments.
    local label="$1"
    local expected_body="$2"
    local docs_url="$3"
    shift 3
    local body trace
    trace=$(mktemp)
    body=$(PORT="$PORT" TRACE="$trace" python3 -c '
import os, socket, sys, time
port = int(os.environ["PORT"])
trace_path = os.environ.get("TRACE", "")
frags = sys.argv[1:]
sent = b""
buf = b""
wire_error = ""
s = None
try:
    s = socket.create_connection(("localhost", port), timeout=5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)  # no Nagle coalescing
    for i, f in enumerate(frags):
        data = f.encode("latin-1")
        s.sendall(data)
        sent += data
        if i < len(frags) - 1:
            time.sleep(0.03)
    while True:
        chunk = s.recv(4096)
        if not chunk: break
        buf += chunk
except socket.timeout:
    wire_error = "socket.timeout (server never closed; client blocked in recv)"
except Exception as e:
    wire_error = type(e).__name__ + ": " + str(e)
finally:
    if s is not None:
        try: s.close()
        except Exception: pass
    # Always write the trace — even (especially) on failure. Without this
    # the wire dump is empty on the exact error paths where you need it.
    if trace_path:
        try:
            with open(trace_path, "w") as tf:
                tf.write("=> Send (" + str(len(sent)) + " bytes across " + str(len(frags)) + " fragment(s))\n")
                tf.write(sent.decode("latin-1", errors="replace"))
                tf.write("\n<= Recv (" + str(len(buf)) + " bytes)\n")
                tf.write(buf.decode("latin-1", errors="replace"))
                if wire_error:
                    tf.write("\n<!> " + wire_error + "\n")
                else:
                    tf.write("\n")
        except Exception:
            pass
resp = buf.decode("latin-1", errors="replace")
try:
    head, raw = resp.split("\r\n\r\n", 1)
except ValueError:
    sys.stdout.write("")
    sys.exit(0)

# Parse headers (case-insensitive)
hdrs = {}
for line in head.split("\r\n")[1:]:
    if ":" in line:
        k, v = line.split(":", 1)
        hdrs[k.strip().lower()] = v.strip()

# If the response is chunked, decode the frames; otherwise honor Content-Length
# when present, else just return the raw remaining bytes.
if hdrs.get("transfer-encoding", "").lower() == "chunked":
    parts, rest = [], raw
    while rest:
        nl = rest.find("\r\n")
        if nl < 0: break
        try:
            size = int(rest[:nl].split(";", 1)[0], 16)  # ignore chunk extensions
        except ValueError:
            break
        rest = rest[nl+2:]
        if size == 0: break
        parts.append(rest[:size])
        rest = rest[size+2:]  # skip trailing CRLF
    body = "".join(parts)
elif "content-length" in hdrs:
    try:
        body = raw[:int(hdrs["content-length"])]
    except ValueError:
        body = raw
else:
    body = raw

sys.stdout.write(body.strip())
' "$@" 2>/dev/null || echo "")

    if [ "$body" = "$expected_body" ]; then
        echo "  PASS [$label]"
        PASS=$((PASS + 1))
        rm -f "$trace"
    else
        fail_with_link "[$label]: expected body '$expected_body', got '$body'" "$docs_url"
        dump_debug "$trace" ""
    fi
}

check_header() {
    local label="$1"
    local header_name="$2"
    local expected_value="$3"
    local docs_url="$4"
    shift 4
    local headers trace
    trace=$(mktemp)
    headers=$(curl -s --max-time 30 -D- -o /dev/null --trace-ascii "$trace" "$@" || true)
    local value
    value=$(echo "$headers" | grep -i "^${header_name}:" | sed 's/^[^:]*: *//' | tr -d '\r' || true)

    # Normalize: text/javascript and application/javascript are equivalent (RFC 9239)
    local norm_value norm_expected
    norm_value=$(echo "$value" | sed 's|text/javascript|application/javascript|')
    norm_expected=$(echo "$expected_value" | sed 's|text/javascript|application/javascript|')
    if [ "$value" = "$expected_value" ] || [[ "$value" == "$expected_value;"* ]] || [ "$norm_value" = "$norm_expected" ] || [[ "$norm_value" == "$norm_expected;"* ]]; then
        echo "  PASS [$label] ($header_name: $value)"
        PASS=$((PASS + 1))
        rm -f "$trace"
    else
        fail_with_link "[$label]: expected $header_name '$expected_value', got '$value'" "$docs_url"
        dump_debug "$trace" "$headers"
    fi
}

wait_h2() {
    echo "[wait] Waiting for HTTPS port..."
    for i in $(seq 1 15); do
        if curl -sk --max-time 30 --http2 -o /dev/null "https://localhost:$H2PORT/baseline2?a=1&b=1" 2>/dev/null; then
            return 0
        fi
        if [ "$i" -eq 15 ]; then
            echo "  FAIL: HTTPS port $H2PORT not responding"
            FAIL=$((FAIL + 1))
            return 1
        fi
        sleep 1
    done
}


# Static freshness / anti-pre-cache probe. The static rules (standard AND tuned)
# require every static response to reflect the CURRENT file on disk — no
# pre-loading file contents/responses into memory. This probe first primes the
# server with the ORIGINAL file (so a lazy "cache on first request" path is
# populated with the old bytes), then rewrites reset.css and its .gz/.br siblings
# on disk with a unique sentinel WHILE THE SERVER IS RUNNING, and re-requests each
# encoding. A server that reads from disk (or revalidates) serves the new bytes; a
# server that cached the file at startup or on first request serves stale content
# and fails. Originals are restored afterwards (and via the EXIT trap on abort).
#
# Usage: check_static_freshness <label> <docs_url> <base_url> [extra curl args...]
check_static_freshness() {
    local label="$1" docs="$2" base="$3"; shift 3
    # Engine / infrastructure entries are ranked separately and exempt.
    case "$FW_TYPE" in
        engine|infrastructure)
            echo "  SKIP [$label] (type=$FW_TYPE is exempt from the static pre-cache rule)"
            return 0 ;;
    esac
    local sdir="$DATA_DIR/static" f="reset.css"
    if [ ! -f "$sdir/$f" ]; then
        echo "  SKIP [$label] (no $f in static dir)"
        return 0
    fi

    # Prime: fetch the ORIGINAL through every encoding so any lazy first-request
    # cache is populated with the pre-change bytes.
    local e
    for e in identity gzip br; do
        curl -s --max-time 30 "$@" -H "Accept-Encoding: $e" -o /dev/null "$base/static/$f" || true
    done

    # Back up originals, then overwrite identity + precompressed siblings with a
    # unique sentinel so every serving strategy must surface the new bytes.
    STATIC_FRESH_BACKUP=$(mktemp -d)
    local v
    for v in "$f" "$f.gz" "$f.br"; do
        if [ -f "$sdir/$v" ]; then cp -p "$sdir/$v" "$STATIC_FRESH_BACKUP/$v"; fi
    done
    local token="HTTPARENA_FRESHNESS_$$_$(date +%s%N 2>/dev/null || echo x)"
    local marker="/* $token */"
    printf '%s' "$marker" > "$sdir/$f"
    if [ -f "$STATIC_FRESH_BACKUP/$f.gz" ]; then
        printf '%s' "$marker" | gzip -9 -n > "$sdir/$f.gz"
    fi
    if [ -f "$STATIC_FRESH_BACKUP/$f.br" ]; then
        printf '%s' "$marker" | python3 -c 'import sys,brotli; sys.stdout.buffer.write(brotli.compress(sys.stdin.buffer.read()))' > "$sdir/$f.br"
    fi
    sync 2>/dev/null || true

    # Poll until every served encoding reflects the change, or the grace window
    # elapses. A short revalidating cache (e.g. fasthttp.FS, nginx open_file_cache)
    # legitimately reflects on-disk changes after a delay; a permanent pre-cache
    # (startup load / build-time manifest) never does. The window separates them.
    local grace="${STATIC_FRESHNESS_GRACE:-30}"
    local start now fresh=0 detail="" hdr body ce decoded
    start=$(date +%s)
    while :; do
        fresh=1; detail=""
        for e in identity gzip br; do
            if [ "$e" = "gzip" ] && [ ! -f "$STATIC_FRESH_BACKUP/$f.gz" ]; then continue; fi
            if [ "$e" = "br" ]   && [ ! -f "$STATIC_FRESH_BACKUP/$f.br" ]; then continue; fi
            hdr=$(mktemp); body=$(mktemp)
            curl -s --max-time 30 "$@" -H "Accept-Encoding: $e" -D "$hdr" -o "$body" "$base/static/$f" || true
            ce=$(grep -i '^content-encoding:' "$hdr" | sed 's/^[^:]*: *//' | tr -d '\r' | awk '{print tolower($1)}' || true)
            case "$ce" in
                gzip) decoded=$(gzip -dc < "$body" 2>/dev/null || true) ;;
                br)   decoded=$(python3 -c 'import sys,brotli; sys.stdout.buffer.write(brotli.decompress(sys.stdin.buffer.read()))' < "$body" 2>/dev/null || true) ;;
                *)    decoded=$(cat "$body" 2>/dev/null || true) ;;
            esac
            rm -f "$hdr" "$body"
            if [[ "$decoded" != *"$token"* ]]; then
                fresh=0
                detail="$detail [Accept-Encoding:$e -> Content-Encoding:${ce:-none} still stale]"
            fi
        done
        [ "$fresh" = 1 ] && break
        now=$(date +%s); [ "$((now - start))" -ge "$grace" ] && break
        sleep 1
    done
    local elapsed=$(( $(date +%s) - start ))

    # Restore originals.
    for v in "$f" "$f.gz" "$f.br"; do
        if [ -f "$STATIC_FRESH_BACKUP/$v" ]; then cp -f "$STATIC_FRESH_BACKUP/$v" "$sdir/$v"; fi
    done
    rm -rf "$STATIC_FRESH_BACKUP"; STATIC_FRESH_BACKUP=""

    if [ "$fresh" = 1 ]; then
        if [ "$elapsed" -le 1 ]; then
            echo "  PASS [$label] (reflects on-disk changes immediately)"
        else
            echo "  PASS [$label] (reflected on-disk change after ~${elapsed}s — revalidating cache, within ${grace}s window)"
        fi
        PASS=$((PASS + 1))
    else
        fail_with_link "[$label]: static response never reflected the on-disk change within ${grace}s — permanent pre-loading/caching of static files is not allowed (standard or tuned).$detail" "$docs"
    fi
}


# keep `source` exit status 0 so the orchestrator continues (set -e stays active inside)
true
