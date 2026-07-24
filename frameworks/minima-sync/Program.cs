using System.Buffers.Text;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using static Minima.Native;

namespace Minima;

/// <summary>
/// minima-sync — a synchronous single-issuer io_uring HTTP/1.1 server, built on
/// Minima's io_uring bindings (Native.cs / Ring.cs) but with zeemo's reactor
/// architecture for maximum throughput on the H1-isolated profiles:
///
///   * one reactor thread per core, each pinned (sched_setaffinity), own ring
///     (SINGLE_ISSUER | DEFER_TASKRUN) + own SO_REUSEPORT listener
///   * multishot accept; single-shot recv into a per-connection buffer,
///     parse-in-place; responses serialized straight into the connection's send
///     buffer; one batched send per drain — recv↔send alternate, fully inline
///   * no async/IValueTaskSource, no MPSC queues, no eventfd — the reactor
///     thread is the sole, synchronous issuer
///   * zero hot-path allocation (pooled connections + native buffers)
///   * compiled with NativeAOT
///
/// Endpoints: /baseline11?a=&b= -> a+b(+body); /pipeline -> ok;
///            /json/{count}?m=N -> application/json (serialized per request).
/// </summary>
internal static unsafe class Program
{
    internal const uint RING_ENTRIES = 4096;
    internal const int MAX_FD = 1 << 16;
    internal const int RECV_BUF = 8 * 1024;
    internal const int WRITE_BUF = 16 * 1024;
    internal const int POOL_MAX = 4096;
    internal const uint MSG_NOSIGNAL = 0x4000;

    internal static Dataset Ds = Dataset.Empty;

    [DllImport("libc", SetLastError = true)]
    private static extern int sched_setaffinity(int pid, nuint cpusetsize, byte* mask);
    [DllImport("libc", SetLastError = true)]
    private static extern int sched_getaffinity(int pid, nuint cpusetsize, byte* mask);

    private static int Main()
    {
        ushort port = 8080;
        if (ushort.TryParse(Environment.GetEnvironmentVariable("MINIMA_PORT"), out ushort p) && p > 0)
            port = p;

        var dsPath = Environment.GetEnvironmentVariable("MINIMA_DATASET") ?? "/data/dataset.json";
        Ds = Dataset.Load(dsPath);

        // Discover the cgroup-allowed CPUs (HttpArena pins the container cpuset).
        const int MASK = 128; // 1024 cpus
        byte* mask = stackalloc byte[MASK];
        int ncpu = 0;
        Span<int> cpus = stackalloc int[256];
        if (sched_getaffinity(0, MASK, mask) == 0)
        {
            for (int b = 0; b < MASK && ncpu < cpus.Length; b++)
                for (int bit = 0; bit < 8 && ncpu < cpus.Length; bit++)
                    if ((mask[b] & (1 << bit)) != 0) cpus[ncpu++] = b * 8 + bit;
        }
        if (ncpu == 0) { cpus[0] = -1; ncpu = 1; }

        int reactors = ncpu;
        if (int.TryParse(Environment.GetEnvironmentVariable("MINIMA_REACTORS"), out int r) && r > 0)
            reactors = r;

        Console.WriteLine($"[minima-sync] {reactors} synchronous reactors on :{port} " +
                          $"({Ds.Count} dataset items)");

        var threads = new Thread[reactors];
        for (int i = 0; i < reactors; i++)
        {
            int cpu = cpus[i % ncpu];
            var reactor = new Reactor(i, port, cpu);
            threads[i] = new Thread(reactor.Run) { Name = $"reactor-{i}", IsBackground = false };
            threads[i].Start();
        }
        foreach (var t in threads) t.Join();
        return 0;
    }

    internal static void Pin(int cpu)
    {
        if (cpu < 0) return;
        const int MASK = 128;
        byte* m = stackalloc byte[MASK];
        for (int i = 0; i < MASK; i++) m[i] = 0;
        m[cpu / 8] = (byte)(1 << (cpu % 8));
        sched_setaffinity(0, MASK, m); // pid 0 = calling thread
    }
}

// ─────────────────────────────────────────────────────────────────────────────

internal sealed unsafe class Conn
{
    public int Fd;
    public byte* Recv;
    public int RecvLen;
    public byte* Write;
    public int WriteLen;
    public int WriteSent;
    public bool CloseAfter;

    public Conn()
    {
        Recv = (byte*)NativeMemory.Alloc(Program.RECV_BUF);
        Write = (byte*)NativeMemory.Alloc(Program.WRITE_BUF);
    }

    public void Reset(int fd)
    {
        Fd = fd;
        RecvLen = 0;
        WriteLen = 0;
        WriteSent = 0;
        CloseAfter = false;
    }

    public void FreeNative()
    {
        NativeMemory.Free(Recv);
        NativeMemory.Free(Write);
    }
}

// ─────────────────────────────────────────────────────────────────────────────

internal sealed unsafe class Reactor
{
    private const uint OP_ACCEPT = 1, OP_RECV = 2, OP_SEND = 3;

    private readonly int _id;
    private readonly ushort _port;
    private readonly int _cpu;
    private Ring _ring = null!;
    private int _listenFd;
    private readonly Conn?[] _slots = new Conn?[Program.MAX_FD];
    private readonly Stack<Conn> _pool = new();

    public Reactor(int id, ushort port, int cpu) { _id = id; _port = port; _cpu = cpu; }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static ulong Ud(uint op, int fd) => ((ulong)op << 32) | (uint)fd;

    private IoUringSqe* Sqe()
    {
        IoUringSqe* sqe = _ring.GetSqe();
        if (sqe == null) { _ring.SubmitAndWait(0); sqe = _ring.GetSqe(); }
        Unsafe.InitBlockUnaligned(sqe, 0, 64);
        return sqe;
    }

    public void Run()
    {
        Program.Pin(_cpu);
        _listenFd = MakeListener(_port);
        _ring = Ring.Create(Program.RING_ENTRIES);
        ArmAccept();

        while (true)
        {
            _ring.SubmitAndWait(1);
            uint n = _ring.CqReady();
            for (uint i = 0; i < n; i++)
            {
                ref readonly IoUringCqe cqe = ref _ring.CqeAt(i);
                Dispatch(cqe.user_data, cqe.res, cqe.flags);
            }
            _ring.CqAdvance(n);
        }
    }

    private void Dispatch(ulong ud, int res, uint flags)
    {
        uint op = (uint)(ud >> 32);
        int fd = (int)(ud & 0xffffffff);
        switch (op)
        {
            case OP_ACCEPT: OnAccept(res, flags); break;
            case OP_RECV: OnRecv(fd, res); break;
            case OP_SEND: OnSend(fd, res); break;
        }
    }

    private void OnAccept(int res, uint flags)
    {
        if (res >= 0)
        {
            int cfd = res;
            if (cfd < Program.MAX_FD)
            {
                int one = 1;
                setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(int));
                Conn c = _pool.Count > 0 ? _pool.Pop() : new Conn();
                c.Reset(cfd);
                _slots[cfd] = c;
                ArmRecv(c);
            }
            else { close(cfd); }
        }
        if ((flags & IORING_CQE_F_MORE) == 0) ArmAccept(); // re-arm if multishot ended
    }

    private void OnRecv(int fd, int res)
    {
        Conn? c = _slots[fd];
        if (c == null) return;
        if (res <= 0) { Close(c); return; }
        c.RecvLen += res;
        try { DrainAndSend(c); }
        catch { Close(c); }
    }

    private void OnSend(int fd, int res)
    {
        Conn? c = _slots[fd];
        if (c == null) return;
        if (res <= 0) { Close(c); return; }
        c.WriteSent += res;
        if (c.WriteSent < c.WriteLen) { SubmitSend(c); return; } // partial
        c.WriteLen = 0;
        c.WriteSent = 0;
        if (c.CloseAfter) { Close(c); return; }
        try { DrainAndSend(c); }
        catch { Close(c); }
    }

    /// Parse every complete request currently buffered, serialize each response
    /// into the connection's write buffer, then submit one batched send (or
    /// re-arm recv if nothing is ready). Recv and send alternate per connection.
    private void DrainAndSend(Conn c)
    {
        int off = 0;
        bool close = false;
        while (off < c.RecvLen)
        {
            var buf = new ReadOnlySpan<byte>(c.Recv + off, c.RecvLen - off);
            int consumed = Handle(c, buf, ref close);
            if (consumed == 0) break;              // incomplete
            if (consumed < 0) { close = true; break; } // protocol error / write full
            off += consumed;
            if (close) break;
        }

        if (off > 0)
        {
            int rem = c.RecvLen - off;
            if (rem > 0) Buffer.MemoryCopy(c.Recv + off, c.Recv, Program.RECV_BUF, rem);
            c.RecvLen = rem;
        }

        if (c.WriteLen > 0) { c.CloseAfter = close; SubmitSend(c); }
        else if (close) Close(c);
        else if (c.RecvLen >= Program.RECV_BUF) Close(c); // request larger than the buffer
        else ArmRecv(c);
    }

    /// Parse one request from buf and serialize its response into c.Write.
    /// Returns bytes consumed, 0 if incomplete, -1 on error / no write space.
    private int Handle(Conn c, ReadOnlySpan<byte> buf, ref bool close)
    {
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

        var w = new Span<byte>(c.Write, Program.WRITE_BUF);
        int pos = c.WriteLen;
        if (!Respond(w, ref pos, target, bodyInt, reqClose)) return -1; // out of write space
        c.WriteLen = pos;
        close = reqClose; // only propagate close once the request is actually complete
        return total;
    }

    // ── io_uring submitters ──────────────────────────────────────────────────
    private void ArmAccept()
    {
        IoUringSqe* sqe = Sqe();
        sqe->opcode = IORING_OP_ACCEPT;
        sqe->ioprio = IORING_ACCEPT_MULTISHOT;
        sqe->fd = _listenFd;
        sqe->user_data = Ud(OP_ACCEPT, _listenFd);
    }

    private void ArmRecv(Conn c)
    {
        IoUringSqe* sqe = Sqe();
        sqe->opcode = IORING_OP_RECV;
        sqe->fd = c.Fd;
        sqe->addr = (ulong)(c.Recv + c.RecvLen);
        sqe->len = (uint)(Program.RECV_BUF - c.RecvLen);
        sqe->user_data = Ud(OP_RECV, c.Fd);
    }

    private void SubmitSend(Conn c)
    {
        IoUringSqe* sqe = Sqe();
        sqe->opcode = IORING_OP_SEND;
        sqe->fd = c.Fd;
        sqe->addr = (ulong)(c.Write + c.WriteSent);
        sqe->len = (uint)(c.WriteLen - c.WriteSent);
        sqe->op_flags = Program.MSG_NOSIGNAL;
        sqe->user_data = Ud(OP_SEND, c.Fd);
    }

    private void Close(Conn c)
    {
        int fd = c.Fd;
        close(fd);
        _slots[fd] = null;
        if (_pool.Count < Program.POOL_MAX) _pool.Push(c); else c.FreeNative();
    }

    private static int MakeListener(ushort port)
    {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(int));
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(int));
        sockaddr_in addr = default;
        addr.sin_family = AF_INET;
        addr.sin_port = Htons(port);
        addr.sin_addr.s_addr = 0;
        if (bind(fd, &addr, (uint)sizeof(sockaddr_in)) < 0) throw new InvalidOperationException("bind failed");
        if (listen(fd, 1024) < 0) throw new InvalidOperationException("listen failed");
        return fd;
    }

    // ── HTTP response serialization (into the write span) ───────────────────
    private static bool Respond(Span<byte> w, ref int pos, ReadOnlySpan<byte> target, long bodyInt, bool close)
    {
        int q = target.IndexOf((byte)'?');
        ReadOnlySpan<byte> path = q >= 0 ? target[..q] : target;
        ReadOnlySpan<byte> query = q >= 0 ? target[(q + 1)..] : default;

        if (path.SequenceEqual("/pipeline"u8))
        {
            return WriteText(w, ref pos, "ok"u8, close);
        }
        if (path.StartsWith("/json/"u8))
        {
            ReadOnlySpan<byte> tail = path[6..];
            if (Utf8Parser.TryParse(tail, out int count, out int used) && used == tail.Length
                && count >= 1 && count <= Program.Ds.Count)
                return WriteJson(w, ref pos, count, ParseM(query), close);
            return Write404(w, ref pos, close);
        }
        long sum = SumAB(query) + bodyInt;
        Span<byte> num = stackalloc byte[24];
        Utf8Formatter.TryFormat(sum, num, out int n);
        return WriteText(w, ref pos, num[..n], close);
    }

    private static bool WriteText(Span<byte> w, ref int pos, ReadOnlySpan<byte> body, bool close)
    {
        if (Program.WRITE_BUF - pos < body.Length + 96) return false;
        Wr(w, ref pos, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: "u8);
        WrInt(w, ref pos, body.Length);
        Wr(w, ref pos, close ? "\r\nConnection: close\r\n\r\n"u8 : "\r\n\r\n"u8);
        Wr(w, ref pos, body);
        return true;
    }

    private static bool Write404(Span<byte> w, ref int pos, bool close)
    {
        if (Program.WRITE_BUF - pos < 128) return false;
        Wr(w, ref pos, "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n"u8);
        if (close) Wr(w, ref pos, "Connection: close\r\n"u8);
        Wr(w, ref pos, "\r\nNot Found"u8);
        return true;
    }

    private static bool WriteJson(Span<byte> w, ref int pos, int count, long m, bool close)
    {
        if (Program.WRITE_BUF - pos < count * 256 + 160) return false;

        Wr(w, ref pos, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "u8);
        int clOff = pos;
        Wr(w, ref pos, "000000\r\n"u8);
        if (close) Wr(w, ref pos, "Connection: close\r\n"u8);
        Wr(w, ref pos, "\r\n"u8);
        int bodyStart = pos;

        Wr(w, ref pos, "{\"items\":["u8);
        Item[] items = Program.Ds.Items;
        for (int i = 0; i < count; i++)
        {
            if (i > 0) Wr(w, ref pos, ","u8);
            ref readonly Item it = ref items[i];
            Wr(w, ref pos, "{\"id\":"u8); WrLong(w, ref pos, it.Id);
            Wr(w, ref pos, ",\"name\":\""u8); Wr(w, ref pos, it.Name);
            Wr(w, ref pos, "\",\"category\":\""u8); Wr(w, ref pos, it.Category);
            Wr(w, ref pos, "\",\"price\":"u8); WrLong(w, ref pos, it.Price);
            Wr(w, ref pos, ",\"quantity\":"u8); WrLong(w, ref pos, it.Quantity);
            Wr(w, ref pos, it.Active ? ",\"active\":true,\"tags\":["u8 : ",\"active\":false,\"tags\":["u8);
            byte[][] tags = it.Tags;
            for (int t = 0; t < tags.Length; t++)
            {
                if (t > 0) Wr(w, ref pos, ","u8);
                Wr(w, ref pos, "\""u8); Wr(w, ref pos, tags[t]); Wr(w, ref pos, "\""u8);
            }
            Wr(w, ref pos, "],\"rating\":{\"score\":"u8); WrLong(w, ref pos, it.Score);
            Wr(w, ref pos, ",\"count\":"u8); WrLong(w, ref pos, it.RatingCount);
            Wr(w, ref pos, "},\"total\":"u8); WrLong(w, ref pos, it.Price * it.Quantity * m);
            Wr(w, ref pos, "}"u8);
        }
        Wr(w, ref pos, "],\"count\":"u8); WrLong(w, ref pos, count); Wr(w, ref pos, "}"u8);

        int bodyLen = pos - bodyStart;
        for (int d = clOff + 5; d >= clOff; d--) { w[d] = (byte)('0' + bodyLen % 10); bodyLen /= 10; }
        return true;
    }

    // ── tiny writers / parsers ──────────────────────────────────────────────
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void Wr(Span<byte> w, ref int pos, ReadOnlySpan<byte> src) { src.CopyTo(w[pos..]); pos += src.Length; }
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void WrInt(Span<byte> w, ref int pos, int v) { Utf8Formatter.TryFormat(v, w[pos..], out int n); pos += n; }
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void WrLong(Span<byte> w, ref int pos, long v) { Utf8Formatter.TryFormat(v, w[pos..], out int n); pos += n; }

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

// ─────────────────────────────────────────────────────────────────────────────

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
            var items = new Item[root.GetArrayLength()];
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
            Console.Error.WriteLine($"[minima-sync] dataset load failed ({path}): {ex.Message}");
            return Empty;
        }
    }
}
