using System.Buffers.Text;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using ioxide.file;
using ioxide.pg;

namespace IoxideArena;

/// <summary>
/// Hand-rolled HTTP/1.1: accumulates inbound bytes, parses complete requests
/// (request line, headers, Content-Length + chunked bodies, keep-alive,
/// pipelining, fragmented reads), and appends responses to <see cref="Out"/>.
/// </summary>
internal sealed unsafe partial class HttpSession
{
    private readonly Dataset _ds;
    private readonly StaticAssets? _assets;
    private readonly Precompressed? _precompressed;
    private byte[] _carry = new byte[2048];
    private int _carryLen;

    public byte[] Out = new byte[4096];
    public int OutLen;
    public bool WantClose;

    // A baked static response sent straight to the connection, bypassing Out. This avoids copying
    // the (up to ~66 KB) asset into the per-connection Out buffer and stops Out from ballooning to
    // the largest asset under load (which was inflating CPU + memory on the static profile). Set
    // only when it's the first response of a batch (OutLen == 0); otherwise the asset rides Out so
    // pipelined ordering is preserved. Either a managed buffer (precompressed) or a native span
    // (ioxide.file's identity baked response).
    public byte[]? DirectBytes;
    public nint DirectPtr;
    public int DirectLen;
    public bool HasDirect => DirectLen > 0;
    public void ClearDirect() { DirectBytes = null; DirectPtr = 0; DirectLen = 0; }

    public HttpSession(Dataset ds, StaticAssets? assets, Precompressed? precompressed)
    {
        _ds = ds;
        _assets = assets;
        _precompressed = precompressed;
    }

    // /async-db parks the parser here; the handler runs the query and resumes.
    public bool PendingDb;
    public bool PendingDbClose;
    private long _dbMin = 10, _dbMax = 50;
    private int _dbLimit = 50;
    private int _dbClOff;
    private bool _dbFirstRow;
    private int _dbRows;

    // /upload streams its body: bytes are counted as they arrive, never buffered whole.
    public long PendingUploadRemaining;
    private long _uploadTotal;
    private bool _uploadClose;

    public void ResumeFeed() => Pump();

    public void Feed(ReadOnlySpan<byte> data)
    {
        // While draining a large upload, count the bytes and drop them - the body is never buffered.
        if (PendingUploadRemaining > 0)
        {
            int take = (int)Math.Min(PendingUploadRemaining, (long)data.Length);
            PendingUploadRemaining -= take;
            if (PendingUploadRemaining > 0) return;   // more body still to come; nothing buffered
            FinishUpload();                           // last byte counted - write the byte-count response
            data = data[take..];                      // any remainder is the start of the next request
            if (data.IsEmpty) return;
        }
        AppendCarry(data);
        Pump();
    }

    // The streamed upload's body is fully counted; emit the 200 with the total byte count.
    private void FinishUpload()
    {
        Span<byte> num = stackalloc byte[20];
        Utf8Formatter.TryFormat(_uploadTotal, num, out int n);
        WriteResp(num[..n], _uploadClose);
        if (_uploadClose) WantClose = true;
    }

    private void Pump()
    {
        int pos = 0;
        while (!PendingDb && PendingUploadRemaining == 0
               && TryOne(_carry.AsSpan(pos, _carryLen - pos), out int consumed, out bool close))
        {
            pos += consumed;
            if (close && !PendingDb) { WantClose = true; break; }
        }
        if (pos > 0)
        {
            int rem = _carryLen - pos;
            if (rem > 0) Array.Copy(_carry, pos, _carry, 0, rem);
            _carryLen = rem;
        }
    }

    /// Parse one request from buf; append its response to Out. Returns false if
    /// the request isn't fully buffered yet.
    private bool TryOne(ReadOnlySpan<byte> buf, out int consumed, out bool close)
    {
        consumed = 0;
        close = false;
        bool acceptBr = false;
        bool acceptGzip = false;

        int he = buf.IndexOf("\r\n\r\n"u8);
        if (he < 0) return false;
        ReadOnlySpan<byte> head = buf[..he];

        int rlEnd = head.IndexOf("\r\n"u8);
        if (rlEnd < 0) rlEnd = head.Length;
        ReadOnlySpan<byte> reqLine = head[..rlEnd];

        ReadOnlySpan<byte> method = default;
        ReadOnlySpan<byte> target = default;
        int sp1 = reqLine.IndexOf((byte)' ');
        if (sp1 >= 0)
        {
            method = reqLine[..sp1];
            ReadOnlySpan<byte> rest = reqLine[(sp1 + 1)..];
            int sp2 = rest.IndexOf((byte)' ');
            target = sp2 >= 0 ? rest[..sp2] : rest;
        }

        // A POST /upload body is streamed (counted), not buffered - detect it before reading the body.
        int qix = target.IndexOf((byte)'?');
        bool isUpload = method.SequenceEqual("POST"u8)
            && (qix >= 0 ? target[..qix] : target).SequenceEqual("/upload"u8);

        int contentLength = -1;
        bool chunked = false;
        ReadOnlySpan<byte> hdrs = head[Math.Min(rlEnd + 2, head.Length)..];
        while (hdrs.Length > 0)
        {
            int nl = hdrs.IndexOf("\r\n"u8);
            ReadOnlySpan<byte> line = nl >= 0 ? hdrs[..nl] : hdrs;
            int colon = line.IndexOf((byte)':');
            if (colon >= 0)
            {
                ReadOnlySpan<byte> name = line[..colon];
                ReadOnlySpan<byte> val = Trim(line[(colon + 1)..]);
                if (CiEq(name, "content-length"u8))
                {
                    if (Utf8Parser.TryParse(val, out int cl, out _)) contentLength = cl;
                }
                else if (CiEq(name, "transfer-encoding"u8) && CiContains(val, "chunked"u8))
                {
                    chunked = true;
                }
                else if (CiEq(name, "connection"u8) && CiEq(val, "close"u8))
                {
                    close = true;
                }
                else if (CiEq(name, "accept-encoding"u8))
                {
                    if (CiContains(val, "br"u8)) acceptBr = true;
                    if (CiContains(val, "gzip"u8)) acceptGzip = true;
                }
            }
            if (nl < 0) break;
            hdrs = hdrs[(nl + 2)..];
        }

        int bodyStart = he + 4;
        long bodyInt;
        int total;
        ReadOnlySpan<byte> body = default;
        int bodyLen = 0;
        if (chunked)
        {
            if (!DecodeChunked(buf[bodyStart..], out bodyInt, out int used)) return false;
            total = bodyStart + used;
        }
        else if (contentLength > 0)
        {
            if (isUpload && buf.Length < bodyStart + contentLength)
            {
                // Stream it: count the body bytes already here, then drain the rest across reads so
                // memory stays bounded regardless of upload size (genhttp does the same). Defer the
                // close and the response until the body is fully counted.
                _uploadTotal = contentLength;
                PendingUploadRemaining = contentLength - (buf.Length - bodyStart);
                _uploadClose = close;
                close = false;
                consumed = buf.Length;
                return true;
            }
            if (buf.Length < bodyStart + contentLength) return false;
            body = buf.Slice(bodyStart, contentLength);
            bodyLen = contentLength;
            bodyInt = ParseLoose(body);
            total = bodyStart + contentLength;
        }
        else
        {
            bodyInt = 0;
            total = bodyStart;
        }

        Respond(method, target, body, bodyLen, bodyInt, close, acceptBr, acceptGzip);
        consumed = total;
        return true;
    }

    private void Respond(ReadOnlySpan<byte> method, ReadOnlySpan<byte> target, ReadOnlySpan<byte> body, int bodyLen, long bodyInt, bool close, bool acceptBr, bool acceptGzip)
    {
        int q = target.IndexOf((byte)'?');
        ReadOnlySpan<byte> path = q >= 0 ? target[..q] : target;
        ReadOnlySpan<byte> query = q >= 0 ? target[(q + 1)..] : default;

        if (path.SequenceEqual("/pipeline"u8))
        {
            WriteResp("ok"u8, close);
        }
        else if (path.StartsWith("/json/"u8))
        {
            ReadOnlySpan<byte> tail = path[6..];
            if (Utf8Parser.TryParse(tail, out int count, out int used) && used == tail.Length
                && count >= 1 && count <= _ds.Count)
            {
                JsonResp(count, ParseM(query), close, acceptBr);
            }
            else
            {
                Write404(close);
            }
        }
        else if (path.StartsWith("/static/"u8))
        {
            // Content negotiation is HTTP, so it lives here: serve the best precompressed
            // variant the client accepts (br > gzip), else ioxide.file's identity baked response,
            // else 404. Precompressed responses already carry Content-Encoding and Vary.
            byte[]? pre = _precompressed?.Negotiate(path[7..], acceptBr, acceptGzip);
            if (pre != null)
            {
                if (OutLen == 0 && !HasDirect) { DirectBytes = pre; DirectLen = pre.Length; }
                else AppendOut(pre);
            }
            else if (_assets != null && _assets.TryGet(path[7..], out AssetCache.Asset asset) && asset.Response != 0)
            {
                if (OutLen == 0 && !HasDirect) { DirectPtr = asset.Response; DirectLen = asset.ResponseLength; }
                else AppendOut(new ReadOnlySpan<byte>((void*)asset.Response, asset.ResponseLength));
            }
            else
            {
                Write404(close);
            }
        }
        else if (path.SequenceEqual("/async-db"u8))
        {
            ParseDbParams(query);
            PendingDb = true;
            PendingDbClose = close;
        }
        else if (path.SequenceEqual("/upload"u8))
        {
            Span<byte> num = stackalloc byte[16];
            Utf8Formatter.TryFormat(bodyLen, num, out int n);
            WriteResp(num[..n], close);
        }
        else if (path.StartsWith("/crud/items"u8))
        {
            RouteCrud(method, path, query, body, close);
        }
        else
        {
            long sum = SumAB(query) + bodyInt;
            Span<byte> num = stackalloc byte[24];
            Utf8Formatter.TryFormat(sum, num, out int n);
            WriteResp(num[..n], close);
        }
    }

    private void WriteResp(ReadOnlySpan<byte> body, bool close)
    {
        AppendOut("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: "u8);
        Span<byte> num = stackalloc byte[16];
        Utf8Formatter.TryFormat(body.Length, num, out int n);
        AppendOut(num[..n]);
        AppendOut(close ? "\r\nConnection: close\r\n\r\n"u8 : "\r\n\r\n"u8);
        AppendOut(body);
    }

    private byte[]? _jsonScratch;
    private byte[]? _brotli;

    private void JsonResp(int count, long m, bool close, bool acceptBr)
    {
        _jsonScratch ??= new byte[16 * 1024];   // allocated on first /json, not per connection

        // Build the body first (into the scratch) so headers carry an exact length.
        byte[] savedOut = Out;
        int savedLen = OutLen;
        Out = _jsonScratch;
        OutLen = 0;
        WriteJsonBody(count, m);
        _jsonScratch = Out;          // may have been resized by AppendOut
        int bodyLen = OutLen;
        Out = savedOut;
        OutLen = savedLen;

        AppendOut("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"u8);

        if (acceptBr)
        {
            // json-comp: per-request brotli (fast quality) - never compressed
            // without Accept-Encoding, per the anti-cheat check.
            int max = BrotliEncoder.GetMaxCompressedLength(bodyLen);
            _brotli ??= new byte[16 * 1024];
            if (_brotli.Length < max)
                Array.Resize(ref _brotli, Math.Max(max, _brotli.Length * 2));
            BrotliEncoder.TryCompress(_jsonScratch.AsSpan(0, bodyLen), _brotli, out int written,
                                      quality: 1, window: 22);

            AppendOut("Content-Encoding: br\r\nContent-Length: "u8);
            AppendLong(written);
            AppendOut(close ? "\r\nConnection: close\r\n\r\n"u8 : "\r\n\r\n"u8);
            AppendOut(_brotli.AsSpan(0, written));
        }
        else
        {
            AppendOut("Content-Length: "u8);
            AppendLong(bodyLen);
            AppendOut(close ? "\r\nConnection: close\r\n\r\n"u8 : "\r\n\r\n"u8);
            AppendOut(_jsonScratch.AsSpan(0, bodyLen));
        }
    }

    // Serialize from the parsed model on every request - no precomputed fragments.
    private void WriteJsonBody(int count, long m)
    {
        AppendOut("{\"items\":["u8);
        for (int i = 0; i < count; i++)
        {
            if (i > 0) AppendOut(","u8);
            ref readonly Item it = ref _ds.Items[i];
            AppendOut("{\"id\":"u8);
            AppendLong(it.Id);
            AppendOut(",\"name\":\""u8);
            AppendOut(it.Name);
            AppendOut("\",\"category\":\""u8);
            AppendOut(it.Category);
            AppendOut("\",\"price\":"u8);
            AppendLong(it.Price);
            AppendOut(",\"quantity\":"u8);
            AppendLong(it.Quantity);
            AppendOut(it.Active ? ",\"active\":true,\"tags\":["u8 : ",\"active\":false,\"tags\":["u8);
            for (int t = 0; t < it.Tags.Length; t++)
            {
                if (t > 0) AppendOut(","u8);
                AppendOut("\""u8);
                AppendOut(it.Tags[t]);
                AppendOut("\""u8);
            }
            AppendOut("],\"rating\":{\"score\":"u8);
            AppendLong(it.Score);
            AppendOut(",\"count\":"u8);
            AppendLong(it.RatingCount);
            AppendOut("},\"total\":"u8);
            AppendLong(it.Price * it.Quantity * m);
            AppendOut("}"u8);
        }
        AppendOut("],\"count\":"u8);
        AppendLong(count);
        AppendOut("}"u8);
    }

    private void Write404(bool close)
    {
        AppendOut("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n"u8);
        if (close) AppendOut("Connection: close\r\n"u8);
        AppendOut("\r\nNot Found"u8);
    }

    private void AppendLong(long v)
    {
        Span<byte> num = stackalloc byte[20];
        Utf8Formatter.TryFormat(v, num, out int n);
        AppendOut(num[..n]);
    }

    private static long ParseM(ReadOnlySpan<byte> query)
    {
        while (query.Length > 0)
        {
            int amp = query.IndexOf((byte)'&');
            ReadOnlySpan<byte> kv = amp >= 0 ? query[..amp] : query;
            if (kv.Length >= 2 && kv[0] == (byte)'m' && kv[1] == (byte)'=')
            {
                Utf8Parser.TryParse(kv[2..], out long m, out _);
                return m;
            }
            if (amp < 0) break;
            query = query[(amp + 1)..];
        }
        return 1;
    }

    private static long SumAB(ReadOnlySpan<byte> query)
    {
        long a = 0, b = 0;
        while (query.Length > 0)
        {
            int amp = query.IndexOf((byte)'&');
            ReadOnlySpan<byte> kv = amp >= 0 ? query[..amp] : query;
            int eq = kv.IndexOf((byte)'=');
            if (eq >= 0)
            {
                ReadOnlySpan<byte> k = kv[..eq];
                ReadOnlySpan<byte> v = kv[(eq + 1)..];
                if (k.SequenceEqual("a"u8)) a = ParseLoose(v);
                else if (k.SequenceEqual("b"u8)) b = ParseLoose(v);
            }
            if (amp < 0) break;
            query = query[(amp + 1)..];
        }
        return a + b;
    }

    /// Decode a chunked body into an integer. Returns false if the terminating
    /// 0-chunk isn't fully buffered. Bodies in these profiles are tiny.
    private static bool DecodeChunked(ReadOnlySpan<byte> buf, out long bodyInt, out int used)
    {
        bodyInt = 0;
        used = 0;
        Span<byte> body = stackalloc byte[256];
        int blen = 0;
        int pos = 0;
        while (true)
        {
            int nl = buf[pos..].IndexOf("\r\n"u8);
            if (nl < 0) return false;
            if (!ParseHex(buf.Slice(pos, nl), out int size)) return false;
            pos += nl + 2;
            if (size == 0)
            {
                int end = buf[pos..].IndexOf("\r\n"u8); // final CRLF (no trailers)
                if (end < 0) return false;
                used = pos + end + 2;
                bodyInt = ParseLoose(body[..blen]);
                return true;
            }
            if (buf.Length < pos + size + 2) return false;
            if (blen + size <= body.Length)
            {
                buf.Slice(pos, size).CopyTo(body[blen..]);
                blen += size;
            }
            pos += size;
            if (!buf.Slice(pos, 2).SequenceEqual("\r\n"u8)) return false;
            pos += 2;
        }
    }

    // ── /async-db ────────────────────────────────────────────────────────────

    private void ParseDbParams(ReadOnlySpan<byte> query)
    {
        _dbMin = 10; _dbMax = 50; _dbLimit = 50;
        while (query.Length > 0)
        {
            int amp = query.IndexOf((byte)'&');
            ReadOnlySpan<byte> kv = amp >= 0 ? query[..amp] : query;
            int eq = kv.IndexOf((byte)'=');
            if (eq >= 0)
            {
                ReadOnlySpan<byte> k = kv[..eq];
                ReadOnlySpan<byte> v = kv[(eq + 1)..];
                if (k.SequenceEqual("min"u8)) _dbMin = ParseLoose(v);
                else if (k.SequenceEqual("max"u8)) _dbMax = ParseLoose(v);
                else if (k.SequenceEqual("limit"u8)) _dbLimit = Math.Clamp((int)ParseLoose(v), 1, 50);
            }
            if (amp < 0) break;
            query = query[(amp + 1)..];
        }
    }

    public string PendingDbSql() =>
        $"SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
        $"FROM items WHERE price BETWEEN {_dbMin} AND {_dbMax} LIMIT {_dbLimit}";

    public void BeginDbResponse()
    {
        AppendOut("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "u8);
        _dbClOff = OutLen;
        AppendOut("000000\r\n"u8);
        if (PendingDbClose) AppendOut("Connection: close\r\n"u8);
        AppendOut("\r\n"u8);
        _dbBodyStart = OutLen;
        AppendOut("{\"items\":["u8);
        _dbFirstRow = true;
        _dbRows = 0;
    }

    private int _dbBodyStart;

    // Streams straight from the driver's receive buffer: numbers and the JSONB
    // tags array are already valid JSON text, so they append verbatim.
    public void AppendDbRow(PgRow row)
    {
        if (!_dbFirstRow) AppendOut(","u8);
        _dbFirstRow = false;
        _dbRows++;

        AppendOut("{\"id\":"u8);          AppendOut(row.Field(0));
        AppendOut(",\"name\":\""u8);      AppendOut(row.Field(1));
        AppendOut("\",\"category\":\""u8); AppendOut(row.Field(2));
        AppendOut("\",\"price\":"u8);     AppendOut(row.Field(3));
        AppendOut(",\"quantity\":"u8);    AppendOut(row.Field(4));
        AppendOut(row.Field(5).SequenceEqual("t"u8) ? ",\"active\":true"u8 : ",\"active\":false"u8);
        AppendOut(",\"tags\":"u8);        AppendOut(row.Field(6));
        AppendOut(",\"rating\":{\"score\":"u8); AppendOut(row.Field(7));
        AppendOut(",\"count\":"u8);       AppendOut(row.Field(8));
        AppendOut("}}"u8);
    }

    public void EndDbResponse()
    {
        AppendOut("],\"count\":"u8);
        AppendLong(_dbRows);
        AppendOut("}"u8);

        int v = OutLen - _dbBodyStart;
        for (int d = _dbClOff + 5; d >= _dbClOff; d--) { Out[d] = (byte)('0' + v % 10); v /= 10; }
    }

    public void WriteDbUnavailable()
    {
        AppendOut("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n"u8);
        if (PendingDbClose) WantClose = true;
    }

    // ── byte helpers ─────────────────────────────────────────────────────────
    private void AppendCarry(ReadOnlySpan<byte> d)
    {
        if (_carry.Length < _carryLen + d.Length)
            Array.Resize(ref _carry, Math.Max(_carryLen + d.Length, _carry.Length * 2));
        d.CopyTo(_carry.AsSpan(_carryLen));
        _carryLen += d.Length;
    }

    private void AppendOut(ReadOnlySpan<byte> d)
    {
        if (Out.Length < OutLen + d.Length)
            Array.Resize(ref Out, Math.Max(OutLen + d.Length, Out.Length * 2));
        d.CopyTo(Out.AsSpan(OutLen));
        OutLen += d.Length;
    }

    private static ReadOnlySpan<byte> Trim(ReadOnlySpan<byte> b)
    {
        int s = 0, e = b.Length;
        while (s < e && (b[s] == (byte)' ' || b[s] == (byte)'\t')) s++;
        while (e > s && (b[e - 1] == (byte)' ' || b[e - 1] == (byte)'\t')) e--;
        return b[s..e];
    }

    private static bool CiEq(ReadOnlySpan<byte> a, ReadOnlySpan<byte> b)
    {
        if (a.Length != b.Length) return false;
        for (int i = 0; i < a.Length; i++)
            if (Lower(a[i]) != Lower(b[i])) return false;
        return true;
    }

    private static bool CiContains(ReadOnlySpan<byte> h, ReadOnlySpan<byte> n)
    {
        if (n.Length == 0 || h.Length < n.Length) return false;
        for (int i = 0; i + n.Length <= h.Length; i++)
            if (CiEq(h.Slice(i, n.Length), n)) return true;
        return false;
    }

    private static byte Lower(byte c) => (byte)(c >= 'A' && c <= 'Z' ? c + 32 : c);

    private static long ParseLoose(ReadOnlySpan<byte> s)
    {
        int i = 0;
        while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) i++;
        bool neg = false;
        if (i < s.Length && s[i] == '-') { neg = true; i++; }
        long n = 0;
        while (i < s.Length && s[i] >= '0' && s[i] <= '9') { n = n * 10 + (s[i] - '0'); i++; }
        return neg ? -n : n;
    }

    private static bool ParseHex(ReadOnlySpan<byte> b, out int val)
    {
        val = 0;
        bool any = false;
        foreach (byte c in b)
        {
            int d;
            if (c >= '0' && c <= '9') d = c - '0';
            else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
            else if (c == ';' || c == ' ') break;
            else return any;
            val = val * 16 + d;
            any = true;
        }
        return any;
    }
}

/// <summary>
/// A dataset item parsed into its model fields (string values stored as UTF-8).
/// The json handler serializes these field-by-field on every request.
/// </summary>
internal readonly struct Item
{
    public readonly long Id, Price, Quantity, Score, RatingCount;
    public readonly bool Active;
    public readonly byte[] Name, Category;
    public readonly byte[][] Tags;

    public Item(long id, byte[] name, byte[] category, long price, long quantity,
                bool active, byte[][] tags, long score, long ratingCount)
    {
        Id = id; Name = name; Category = category; Price = price; Quantity = quantity;
        Active = active; Tags = tags; Score = score; RatingCount = ratingCount;
    }
}

/// <summary>
/// Dataset for the json profile — items parsed into model fields at startup so
/// the handler serializes the full JSON from the model on every request (no
/// precomputed / cached response fragments). Read-only after load, shared across
/// reactor threads. String values are clean ASCII in the bench dataset, so the
/// handler emits them without escaping.
/// </summary>
internal sealed class Dataset
{
    public readonly Item[] Items;
    public int Count => Items.Length;

    public static readonly Dataset Empty = new(Array.Empty<Item>());

    private Dataset(Item[] items) { Items = items; }

    public static Dataset Load(string path)
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllBytes(path));
            JsonElement root = doc.RootElement;
            int n = root.GetArrayLength();
            var items = new Item[n];
            int i = 0;
            foreach (JsonElement e in root.EnumerateArray())
            {
                JsonElement rating = e.GetProperty("rating");
                JsonElement tagsEl = e.GetProperty("tags");
                var tags = new byte[tagsEl.GetArrayLength()][];
                int t = 0;
                foreach (JsonElement tag in tagsEl.EnumerateArray())
                    tags[t++] = Encoding.UTF8.GetBytes(tag.GetString() ?? "");
                items[i++] = new Item(
                    e.GetProperty("id").GetInt64(),
                    Encoding.UTF8.GetBytes(e.GetProperty("name").GetString() ?? ""),
                    Encoding.UTF8.GetBytes(e.GetProperty("category").GetString() ?? ""),
                    e.GetProperty("price").GetInt64(),
                    e.GetProperty("quantity").GetInt64(),
                    e.GetProperty("active").GetBoolean(),
                    tags,
                    rating.GetProperty("score").GetInt64(),
                    rating.GetProperty("count").GetInt64());
            }
            return new Dataset(items);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[minima] dataset load failed ({path}): {ex.Message}");
            return Empty;
        }
    }
}
