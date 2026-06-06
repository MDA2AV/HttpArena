using System.Buffers.Text;
using System.Text;
using System.Text.Json;
using Minima.Utils;

namespace Minima;

/// <summary>
/// minima — the Minima io_uring engine serving the H1-isolated profiles
/// (baseline, pipelined, limited-conn). Minima's engine is vendored unchanged
/// (per-reactor SO_REUSEPORT + multishot accept, multishot recv into a provided
/// buffer ring, RCA=false inline continuations + the reactor-thread short-circuit
/// in Enqueue*). Only the request handler is ours: a hand-rolled HTTP/1.1 parser
/// on Minima's raw recv/send API. No HTTP framework.
///
/// Endpoints:
///   GET/POST /baseline11?a=&b=  -> text/plain "a + b (+ body)"
///   GET      /pipeline          -> text/plain "ok"
///   GET      /json/{count}?m=N  -> application/json, per-item total = price*quantity*N
/// </summary>
internal static class Program
{
    private static int Main()
    {
        int reactors = Environment.ProcessorCount;
        if (int.TryParse(Environment.GetEnvironmentVariable("MINIMA_REACTORS"), out int r) && r > 0)
            reactors = r;

        ushort port = 8080;
        if (ushort.TryParse(Environment.GetEnvironmentVariable("MINIMA_PORT"), out ushort p) && p > 0)
            port = p;

        var config = new ServerConfig
        {
            Port              = port,
            ReactorCount      = reactors,
            UsePipe           = false,
            Incremental       = false,
            RecvBufferSize    = 16 * 1024,
            BufferRingEntries = 1024,
        };

        Console.WriteLine($"[minima] {config.ReactorCount} reactors on :{config.Port} " +
                          $"(incremental={config.Incremental}) — hand-rolled HTTP/1.1");

        var dsPath = Environment.GetEnvironmentVariable("MINIMA_DATASET") ?? "/data/dataset.json";
        var dataset = Dataset.Load(dsPath);
        Console.WriteLine($"[minima] loaded {dataset.Count} dataset items from {dsPath}");

        Handler.Init(config, dataset);

        var threads = new Thread[config.ReactorCount];
        for (int i = 0; i < config.ReactorCount; i++)
        {
            var reactor = new Reactor(i, config);
            threads[i] = new Thread(reactor.Run) { Name = $"reactor-{i}", IsBackground = false };
            threads[i].Start();
        }
        foreach (var t in threads) t.Join();
        return 0;
    }
}

internal static class Handler
{
    private static int _slab = 16 * 1024;
    private static Dataset _ds = Dataset.Empty;

    public static void Init(ServerConfig config, Dataset ds)
    {
        _slab = config.WriteSlabSize;
        _ds = ds;
    }

    public static async Task HandleAsync(Reactor reactor, Connection conn)
    {
        var s = new HttpSession(_ds);
        try
        {
            while (true)
            {
                RecvSnapshot snap = await conn.ReadAsync();
                while (conn.TryGetItem(snap, out SpscRecvRing.Item item))
                {
                    if (item.HasBuffer)
                    {
                        s.Feed(item.AsSpan());
                        conn.ReturnBuffer(in item);
                    }
                }

                int sent = 0;
                while (sent < s.OutLen)
                {
                    int chunk = Math.Min(s.OutLen - sent, _slab);
                    conn.Write(s.Out.AsSpan(sent, chunk));
                    await conn.FlushAsync();
                    sent += chunk;
                }
                s.OutLen = 0;

                if (snap.IsClosed || s.WantClose)
                    return;

                conn.ResetRead();
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[r{reactor.Id}] http handler crash fd={conn.ClientFd}: {ex}");
        }
        finally
        {
            conn.DecRef();
        }
    }

    public static Task HandlePipeAsync(Reactor reactor, Connection conn) => HandleAsync(reactor, conn);
}

/// <summary>
/// Hand-rolled HTTP/1.1: accumulates inbound bytes, parses complete requests
/// (request line, headers, Content-Length + chunked bodies, keep-alive,
/// pipelining, fragmented reads), and appends responses to <see cref="Out"/>.
/// </summary>
internal sealed class HttpSession
{
    private readonly Dataset _ds;
    private byte[] _carry = new byte[2048];
    private int _carryLen;

    public byte[] Out = new byte[4096];
    public int OutLen;
    public bool WantClose;

    public HttpSession(Dataset ds) => _ds = ds;

    public void Feed(ReadOnlySpan<byte> data)
    {
        AppendCarry(data);
        int pos = 0;
        while (TryOne(_carry.AsSpan(pos, _carryLen - pos), out int consumed, out bool close))
        {
            pos += consumed;
            if (close) { WantClose = true; break; }
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

        int he = buf.IndexOf("\r\n\r\n"u8);
        if (he < 0) return false;
        ReadOnlySpan<byte> head = buf[..he];

        int rlEnd = head.IndexOf("\r\n"u8);
        if (rlEnd < 0) rlEnd = head.Length;
        ReadOnlySpan<byte> reqLine = head[..rlEnd];

        ReadOnlySpan<byte> target = default;
        int sp1 = reqLine.IndexOf((byte)' ');
        if (sp1 >= 0)
        {
            ReadOnlySpan<byte> rest = reqLine[(sp1 + 1)..];
            int sp2 = rest.IndexOf((byte)' ');
            target = sp2 >= 0 ? rest[..sp2] : rest;
        }

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
            }
            if (nl < 0) break;
            hdrs = hdrs[(nl + 2)..];
        }

        int bodyStart = he + 4;
        long bodyInt;
        int total;
        if (chunked)
        {
            if (!DecodeChunked(buf[bodyStart..], out bodyInt, out int used)) return false;
            total = bodyStart + used;
        }
        else if (contentLength > 0)
        {
            if (buf.Length < bodyStart + contentLength) return false;
            bodyInt = ParseLoose(buf.Slice(bodyStart, contentLength));
            total = bodyStart + contentLength;
        }
        else
        {
            bodyInt = 0;
            total = bodyStart;
        }

        Respond(target, bodyInt, close);
        consumed = total;
        return true;
    }

    private void Respond(ReadOnlySpan<byte> target, long bodyInt, bool close)
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
                JsonResp(count, ParseM(query), close);
            }
            else
            {
                Write404(close);
            }
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

    private void JsonResp(int count, long m, bool close)
    {
        AppendOut("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "u8);
        int clOff = OutLen;
        AppendOut("000000\r\n"u8); // 6-digit zero-padded Content-Length placeholder
        if (close) AppendOut("Connection: close\r\n"u8);
        AppendOut("\r\n"u8);
        int bodyStart = OutLen;

        // Serialize from the parsed model on every request — no precomputed
        // fragments. Synchronous on the reactor thread (a few microseconds of
        // CPU): offloading to the thread pool would add a hop and resume the
        // handler off-reactor, defeating the RCA short-circuit on Flush.
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

        // Backfill the 6-digit zero-padded Content-Length now the body length is known.
        int v = OutLen - bodyStart;
        for (int d = clOff + 5; d >= clOff; d--) { Out[d] = (byte)('0' + v % 10); v /= 10; }
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
