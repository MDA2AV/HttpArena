module ArenaHttpJl

using HTTP, JSON3, StructTypes, CodecZlib, TranscodingStreams
using PrecompileTools: @setup_workload, @compile_workload

# ── dataset ─────────────────────────────────────────────────────────────────

struct Rating
    score::Int
    count::Int
end

struct Item
    id::Int
    name::String
    category::String
    price::Int
    quantity::Int
    active::Bool
    tags::Vector{String}
    rating::Rating
end

# the Item fields plus the computed total, in the order the board expects
struct OutItem
    id::Int
    name::String
    category::String
    price::Int
    quantity::Int
    active::Bool
    tags::Vector{String}
    rating::Rating
    total::Int
end

StructTypes.StructType(::Type{Rating}) = StructTypes.Struct()
StructTypes.StructType(::Type{OutItem}) = StructTypes.Struct()

# written once at startup, read by every thread afterwards
const ITEMS = Item[]

"""
Load the dataset into `ITEMS`. A missing or broken file leaves the list empty:
the server still answers, it just has nothing to serve.
"""
function load_dataset!(path::AbstractString)
    empty!(ITEMS)
    try
        for d in JSON3.read(read(path))
            r = d.rating
            push!(ITEMS, Item(d.id, d.name, d.category, d.price, d.quantity,
                              d.active, String[t for t in d.tags],
                              Rating(r.score, r.count)))
        end
    catch
        empty!(ITEMS)
    end
    return ITEMS
end

function json_body(count::Int, m::Int)
    n = clamp(count, 0, length(ITEMS))
    items = Vector{OutItem}(undef, n)
    @inbounds for i in 1:n
        d = ITEMS[i]
        items[i] = OutItem(d.id, d.name, d.category, d.price, d.quantity,
                           d.active, d.tags, d.rating, d.price * d.quantity * m)
    end
    io = IOBuffer()
    JSON3.write(io, (items = items, count = n))
    return take!(io)
end

# ── request parsing ─────────────────────────────────────────────────────────

# The integer in cu[lo:hi], or nothing if that range is empty or has a non-digit.
function parse_int(cu, lo::Int, hi::Int)
    lo > hi && return nothing
    neg = false
    @inbounds if cu[lo] == UInt8('-')
        neg = true
        lo += 1
    end
    lo > hi && return nothing
    v = 0
    @inbounds for i in lo:hi
        c = cu[i]
        (UInt8('0') <= c <= UInt8('9')) || return nothing
        v = v * 10 + Int(c - UInt8('0'))
    end
    return neg ? -v : v
end

# Sum of every query parameter whose value is an integer.
function sum_query(q::AbstractString)
    cu = codeunits(q)
    n = length(cu)
    total = 0
    i = 1
    while i <= n
        j = i
        @inbounds while j <= n && cu[j] != UInt8('&')
            j += 1
        end
        k = i
        @inbounds while k < j && cu[k] != UInt8('=')
            k += 1
        end
        if k < j
            v = parse_int(cu, k + 1, j - 1)
            v === nothing || (total += v)
        end
        i = j + 1
    end
    return total
end

# ?m=N, defaulting to 1
function query_m(q::AbstractString)
    cu = codeunits(q)
    n = length(cu)
    i = 1
    while i <= n
        j = i
        @inbounds while j <= n && cu[j] != UInt8('&')
            j += 1
        end
        @inbounds if j - i >= 2 && cu[i] == UInt8('m') && cu[i + 1] == UInt8('=')
            v = parse_int(cu, i + 2, j - 1)
            v === nothing || return v
        end
        i = j + 1
    end
    return 1
end

is_space(c::UInt8) = c == UInt8(' ') || c == UInt8('\t') || c == UInt8('\r') || c == UInt8('\n')

function body_int(stream::HTTP.Stream)
    bytes = read(stream)
    lo, hi = 1, length(bytes)
    @inbounds while lo <= hi && is_space(bytes[lo])
        lo += 1
    end
    @inbounds while hi >= lo && is_space(bytes[hi])
        hi -= 1
    end
    v = parse_int(bytes, lo, hi)
    return v === nothing ? 0 : v
end

const UPLOAD_CHUNK = 64 * 1024

# Count the body without keeping it: a 20 MB upload goes through one 64 KB buffer.
function upload_size(stream::HTTP.Stream)
    buf = Vector{UInt8}(undef, UPLOAD_CHUNK)
    total = 0
    while !eof(stream)
        total += readbytes!(stream, buf)
    end
    return total
end

function accepts_gzip(req::HTTP.Request)
    h = HTTP.header(req, "Accept-Encoding")
    cu = codeunits(h)
    n = length(cu)
    n < 4 && return false
    @inbounds for i in 1:(n - 3)
        (cu[i] | 0x20) == UInt8('g') || continue
        (cu[i + 1] | 0x20) == UInt8('z') || continue
        (cu[i + 2] | 0x20) == UInt8('i') || continue
        (cu[i + 3] | 0x20) == UInt8('p') && return true
    end
    return false
end

# ── responses ───────────────────────────────────────────────────────────────

# Content-Length up front is what puts HTTP.jl on its fixed-length path, where
# head and body leave in a single write instead of chunked framing.
@inline function respond(stream::HTTP.Stream, ctype::String, body)
    HTTP.setstatus(stream, 200)
    HTTP.setheader(stream, "Content-Type" => ctype)
    HTTP.setheader(stream, "Content-Length" => string(sizeof(body)))
    HTTP.startwrite(stream)
    write(stream, body)
    return nothing
end

@inline function respond_gzip(stream::HTTP.Stream, body::Vector{UInt8})
    HTTP.setstatus(stream, 200)
    HTTP.setheader(stream, "Content-Type" => "application/json")
    HTTP.setheader(stream, "Content-Encoding" => "gzip")
    HTTP.setheader(stream, "Vary" => "Accept-Encoding")
    HTTP.setheader(stream, "Content-Length" => string(length(body)))
    HTTP.startwrite(stream)
    write(stream, body)
    return nothing
end

@inline function respond_404(stream::HTTP.Stream)
    HTTP.setstatus(stream, 404)
    HTTP.setheader(stream, "Content-Length" => "0")
    HTTP.startwrite(stream)
    return nothing
end

# ── handler ─────────────────────────────────────────────────────────────────

# HTTP.jl ships no compression middleware, so json-comp is gzipped by hand with
# CodecZlib. The compressors are pooled because deflateInit allocates a few
# hundred KB of zlib state, too much to redo on every request; one per thread is
# enough since a handler holds one only for the length of a transcode call.
struct App
    gzip::Channel{GzipCompressor}
end

function make_app(pool_size::Int = max(2, Threads.maxthreadid()))
    pool = Channel{GzipCompressor}(pool_size)
    for _ in 1:pool_size
        codec = GzipCompressor()
        TranscodingStreams.initialize(codec)
        put!(pool, codec)
    end
    return App(pool)
end

function gzip_body(app::App, bytes::Vector{UInt8})
    codec = take!(app.gzip)
    try
        return transcode(codec, bytes)
    finally
        put!(app.gzip, codec)
    end
end

function (app::App)(stream::HTTP.Stream)
    req = stream.message
    target = req.target
    cu = codeunits(target)
    n = length(cu)
    q = 0
    @inbounds for i in 1:n
        if cu[i] == UInt8('?')
            q = i
            break
        end
    end
    plen = q == 0 ? n : q - 1
    path = SubString(target, 1, plen)
    query = q == 0 ? SubString(target, n + 1) : SubString(target, q + 1)

    if path == "/pipeline"
        respond(stream, "text/plain", "ok")
    elseif path == "/baseline11"
        total = sum_query(query)
        if req.method == "POST"
            total += body_int(stream)
        end
        respond(stream, "text/plain", string(total))
    elseif plen > 6 && startswith(path, "/json/")
        count = parse_int(cu, 7, plen)
        body = json_body(count === nothing ? 0 : count, query_m(query))
        if accepts_gzip(req)
            respond_gzip(stream, gzip_body(app, body))
        else
            respond(stream, "application/json", body)
        end
    elseif path == "/upload" && req.method == "POST"
        respond(stream, "text/plain", string(upload_size(stream)))
    else
        respond_404(stream)
    end
    return nothing
end

# ── server ──────────────────────────────────────────────────────────────────

"""
HTTP.jl 2 runs every connection as a task on Julia's `:interactive` thread pool,
so one process uses every core it is given. start.sh sizes that pool.
"""
function main(port::Int = 8080)
    load_dataset!(get(ENV, "DATASET_PATH", "/data/dataset.json"))
    return HTTP.listen(make_app(), "0.0.0.0", port; backlog = 4096)
end

# ── precompilation ──────────────────────────────────────────────────────────
#
# Serves real requests over a real socket at build time, so the package image
# carries native code for the whole request path. Without it the first requests
# pay for the Julia compiler.

@setup_workload begin
    sample = """
    [{"id":1,"name":"Alpha Widget","category":"electronics","price":328,
      "quantity":15,"active":true,"tags":["sale","popular"],
      "rating":{"score":48,"count":53}}]
    """
    try
        mktemp() do path, io
            write(io, sample)
            close(io)
            load_dataset!(path)
        end
        app = make_app(2)
        server = HTTP.listen!(app, "127.0.0.1", 58080; listenany = true)
        base = "http://127.0.0.1:$(HTTP.port(server))"
        try
            @compile_workload begin
                HTTP.get("$base/pipeline")
                HTTP.get("$base/baseline11?a=13&b=42")
                HTTP.post("$base/baseline11?a=13&b=42", [], "20")
                HTTP.get("$base/json/1?m=3")
                HTTP.get("$base/json/1?m=3", ["Accept-Encoding" => "gzip"]; decompress = false)
                HTTP.post("$base/upload", [], rand(UInt8, 128 * 1024))
                HTTP.get("$base/nope"; status_exception = false)
            end
        finally
            HTTP.forceclose(server)
            empty!(ITEMS)
        end
    catch e
        @info "precompile workload skipped" exception = (e, catch_backtrace())
    end
end

end # module
