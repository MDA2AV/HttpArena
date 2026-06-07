using System.Buffers.Text;
using Shrike;

// ReSharper disable SuggestVarOrType_BuiltInTypes

/// <summary>
/// shrike-minima — an epoll engine with an IVTS-backed, RCA=true async handler loop,
/// using Minima's SPSC recv handoff: the worker thread recv's into POOLED buffers and
/// enqueues them on a per-connection SPSC ring; the per-connection handler resumes on
/// the THREAD POOL, dequeues the chunks, copies them into its own parse buffer, and
/// returns the buffers to the pool. The worker and handler never share a buffer, so
/// there is no driver/handler race — and recv can pipeline with parse (the worker keeps
/// pumping while the handler works). FlushAsync sends directly, so the off-worker
/// handler needs no handoff. A fully async-work-ready architecture.
///
/// Serves the H1-isolated profiles: baseline, pipelined, limited-conn.
///   GET/POST /baseline11?a=&b=  -> text/plain  a + b (+ body)
///   GET      /pipeline          -> text/plain  ok
/// </summary>
internal static class Program
{
    [System.Runtime.InteropServices.DllImport("libc", SetLastError = true)]
    private static extern int shutdown(int fd, int how);
    private const int SHUT_WR = 1;

    private static void Main()
    {
        int port = 8080;
        if (int.TryParse(Environment.GetEnvironmentVariable("SHRIKE_PORT"), out int p) && p > 0)
            port = p;

        int workers = Math.Max(1, Environment.ProcessorCount / 2);
        if (int.TryParse(Environment.GetEnvironmentVariable("SHRIKE_WORKERS"), out int w) && w > 0)
            workers = w;

        ShrikeEngine.CreateBuilder()
            .SetPort(port)
            .SetBacklog(16384)
            .SetMaxEventsPerWake(512)
            .SetMaxNumberConnectionsPerWorker(8192)
            .SetSlabSizes(64 * 1024, 32 * 1024)   // parse buffer holds a 16K recv chunk + partial
            .SetNWorkersSolver(() => workers)
            .InjectHandler(HandleAsync)
            .Build()
            .Run();
    }

    /// <summary>
    /// Per-connection handler. RCA=true → each <c>await</c> resumes on the thread pool.
    /// ReadAsync waits for a recv signal; the handler then drains the SPSC ring (copying
    /// chunks into its own parse buffer) and parses. Only this thread touches the buffer.
    /// </summary>
    private static async Task HandleAsync(Connection conn)
    {
        while (true)
        {
            if (await conn.ReadAsync())        // wait for a recv signal (true => peer closed)
                return;

            bool wrote = DrainRing(conn, out bool close);

            if (wrote)
                await conn.FlushAsync();

            if (close)
            {
                // Connection: close — half-close to send a FIN now (the worker
                // recycles the fd on the peer's EPOLLRDHUP). The handler thread
                // can issue this directly (epoll, thread-safe), like the send().
                shutdown(conn.Fd, SHUT_WR);
                return;
            }
        }
    }

    /// <summary>
    /// Dequeue every recv chunk the worker handed over, copy it into the connection's
    /// own parse buffer (returning the pooled buffer), and parse complete requests after
    /// each chunk. Only the handler thread touches the parse buffer.
    /// </summary>
    private static unsafe bool DrainRing(Connection conn, out bool close)
    {
        close = false;
        bool wrote = false;
        int cap = conn.InCapacity;
        while (conn.RecvRing.TryDequeue(out byte* ptr, out int len))
        {
            if (conn.Tail + len > cap) { RecvPool.Return(ptr); close = true; break; } // oversized request
            Buffer.MemoryCopy(ptr, conn.ReceiveBuffer + conn.Tail, cap - conn.Tail, len);
            conn.Tail += len;
            RecvPool.Return(ptr);
            wrote |= DrainRequests(conn, out close);   // parse + compact after each chunk
            if (close) break;
        }
        while (conn.RecvRing.TryDequeue(out byte* p, out _)) RecvPool.Return(p); // return any leftovers
        return wrote;
    }

    /// <summary>Parse every complete request in the recv window, write each response into the write buffer.</summary>
    private static unsafe bool DrainRequests(Connection conn, out bool close)
    {
        close = false;
        bool wrote = false;
        int pos = conn.Head;
        while (pos < conn.Tail)
        {
            var buf = new ReadOnlySpan<byte>(conn.ReceiveBuffer + pos, conn.Tail - pos);
            int consumed = ParseOne(buf, conn.WriteBuffer, out bool reqClose);
            if (consumed == 0) break;               // incomplete request — wait for more
            if (consumed < 0) { close = true; break; }
            pos += consumed;
            wrote = true;
            if (reqClose) { close = true; break; }
        }
        conn.Head = pos;
        conn.Compact();                              // reclaim consumed bytes, slide partial to front
        return wrote;
    }

    /// <summary>Parse one request from <paramref name="buf"/>, write its response into <paramref name="wb"/>.
    /// Returns bytes consumed, 0 if incomplete, -1 on error/no room.</summary>
    private static int ParseOne(ReadOnlySpan<byte> buf, FixedBufferWriter wb, out bool close)
    {
        close = false;
        int he = buf.IndexOf("\r\n\r\n"u8);
        if (he < 0) return 0;
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
        bool reqClose = false;
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
                if (CiEq(name, "content-length"u8)) { if (Utf8Parser.TryParse(val, out int cl, out _)) contentLength = cl; }
                else if (CiEq(name, "transfer-encoding"u8) && CiContains(val, "chunked"u8)) chunked = true;
                else if (CiEq(name, "connection"u8) && CiEq(val, "close"u8)) reqClose = true;
            }
            if (nl < 0) break;
            hdrs = hdrs[(nl + 2)..];
        }

        int bodyStart = he + 4;
        long bodyInt;
        int total;
        if (chunked)
        {
            if (!DecodeChunked(buf[bodyStart..], out bodyInt, out int used)) return 0;
            total = bodyStart + used;
        }
        else if (contentLength > 0)
        {
            if (buf.Length < bodyStart + contentLength) return 0;
            bodyInt = ParseLoose(buf.Slice(bodyStart, contentLength));
            total = bodyStart + contentLength;
        }
        else { bodyInt = 0; total = bodyStart; }

        Span<byte> w = wb.GetSpan(256);
        int pos = 0;
        if (!Respond(w, ref pos, target, bodyInt, reqClose)) return -1;
        wb.Advance(pos);
        close = reqClose;
        return total;
    }

    private static bool Respond(Span<byte> w, ref int pos, ReadOnlySpan<byte> target, long bodyInt, bool close)
    {
        int q = target.IndexOf((byte)'?');
        ReadOnlySpan<byte> path = q >= 0 ? target[..q] : target;
        ReadOnlySpan<byte> query = q >= 0 ? target[(q + 1)..] : default;

        if (path.SequenceEqual("/pipeline"u8))
            return WriteText(w, ref pos, "ok"u8, close);

        long sum = SumAB(query) + bodyInt;
        Span<byte> num = stackalloc byte[24];
        Utf8Formatter.TryFormat(sum, num, out int n);
        return WriteText(w, ref pos, num[..n], close);
    }

    private static bool WriteText(Span<byte> w, ref int pos, ReadOnlySpan<byte> body, bool close)
    {
        if (w.Length - pos < body.Length + 96) return false;
        Wr(w, ref pos, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: "u8);
        WrInt(w, ref pos, body.Length);
        Wr(w, ref pos, close ? "\r\nConnection: close\r\n\r\n"u8 : "\r\n\r\n"u8);
        Wr(w, ref pos, body);
        return true;
    }

    private static void Wr(Span<byte> w, ref int pos, ReadOnlySpan<byte> src) { src.CopyTo(w[pos..]); pos += src.Length; }
    private static void WrInt(Span<byte> w, ref int pos, int v) { Utf8Formatter.TryFormat(v, w[pos..], out int n); pos += n; }

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
                if (k.SequenceEqual("a"u8)) a = ParseLoose(kv[(eq + 1)..]);
                else if (k.SequenceEqual("b"u8)) b = ParseLoose(kv[(eq + 1)..]);
            }
            if (amp < 0) break;
            query = query[(amp + 1)..];
        }
        return a + b;
    }

    private static bool DecodeChunked(ReadOnlySpan<byte> buf, out long bodyInt, out int used)
    {
        bodyInt = 0; used = 0;
        Span<byte> body = stackalloc byte[256];
        int blen = 0, pos = 0;
        while (true)
        {
            int nl = buf[pos..].IndexOf("\r\n"u8);
            if (nl < 0) return false;
            if (!ParseHex(buf.Slice(pos, nl), out int size)) return false;
            pos += nl + 2;
            if (size == 0)
            {
                int end = buf[pos..].IndexOf("\r\n"u8);
                if (end < 0) return false;
                used = pos + end + 2;
                bodyInt = ParseLoose(body[..blen]);
                return true;
            }
            if (buf.Length < pos + size + 2) return false;
            if (blen + size <= body.Length) { buf.Slice(pos, size).CopyTo(body[blen..]); blen += size; }
            pos += size;
            if (!buf.Slice(pos, 2).SequenceEqual("\r\n"u8)) return false;
            pos += 2;
        }
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
        for (int i = 0; i < a.Length; i++) if (Low(a[i]) != Low(b[i])) return false;
        return true;
    }

    private static bool CiContains(ReadOnlySpan<byte> h, ReadOnlySpan<byte> n)
    {
        if (n.Length == 0 || h.Length < n.Length) return false;
        for (int i = 0; i + n.Length <= h.Length; i++) if (CiEq(h.Slice(i, n.Length), n)) return true;
        return false;
    }

    private static byte Low(byte c) => (byte)(c >= 'A' && c <= 'Z' ? c + 32 : c);

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
        val = 0; bool any = false;
        foreach (byte c in b)
        {
            int d;
            if (c >= '0' && c <= '9') d = c - '0';
            else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
            else if (c == ';' || c == ' ') break;
            else return any;
            val = val * 16 + d; any = true;
        }
        return any;
    }
}
