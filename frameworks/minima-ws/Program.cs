using System.Security.Cryptography;
using System.Text;
using Minima.Utils;

namespace Minima;

/// <summary>
/// minima-ws — a hand-rolled WebSocket echo server on the Minima engine.
///
/// Minima is a from-scratch C# multi-reactor io_uring server (direct io_uring
/// syscalls via libc, multishot accept + multishot recv into a provided buffer
/// ring, one ring per core with SO_REUSEPORT). This entry keeps Minima's engine
/// untouched and replaces only the request handler: the RFC 6455 handshake and
/// the frame parser / masking / echo are written by hand on Minima's raw
/// recv/send API (ReadAsync / TryGetItem / Write / FlushAsync). No WS library.
///
/// Listens on 0.0.0.0:8080, WebSocket on /ws.
/// </summary>
internal static class Program
{
    private static int Main()
    {
        // One reactor per core (respects the container cpuset). Override with
        // MINIMA_REACTORS for local testing.
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
            Incremental       = false,   // shared provided-buffer ring (not per-conn incremental)
            RecvBufferSize    = 16 * 1024,
            BufferRingEntries = 1024,
        };

        Console.WriteLine($"[minima-ws] {config.ReactorCount} reactors on :{config.Port} " +
                          $"(incremental={config.Incremental}) — hand-rolled WebSocket echo");

        Handler.Init(config);

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

/// <summary>
/// Per-connection handler. Minima's reactor calls <see cref="HandleAsync"/> once
/// per accepted connection (see Reactor.Dispatch). We drive a <see cref="WsSession"/>
/// over the raw recv buffers and flush echoes back through the write slab.
/// </summary>
internal static class Handler
{
    private static int _slab = 16 * 1024;

    public static void Init(ServerConfig config) => _slab = config.WriteSlabSize;

    public static async Task HandleAsync(Reactor reactor, Connection conn)
    {
        var ws = new WsSession();
        try
        {
            while (true)
            {
                RecvSnapshot snap = await conn.ReadAsync();

                // Consume every recv buffer in this snapshot; copy bytes into the
                // session (carry) and return the buffer to the ring immediately.
                while (conn.TryGetItem(snap, out SpscRecvRing.Item item))
                {
                    if (item.HasBuffer)
                    {
                        ws.Feed(item.AsSpan());
                        conn.ReturnBuffer(in item);
                    }
                }

                // Flush queued echoes through the write slab, chunked to its size.
                int sent = 0;
                while (sent < ws.OutLen)
                {
                    int chunk = Math.Min(ws.OutLen - sent, _slab);
                    conn.Write(ws.Out.AsSpan(sent, chunk));
                    await conn.FlushAsync();
                    sent += chunk;
                }
                ws.OutLen = 0;

                if (snap.IsClosed || ws.WantClose)
                    return;

                conn.ResetRead();
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[r{reactor.Id}] ws handler crash fd={conn.ClientFd}: {ex}");
        }
        finally
        {
            conn.DecRef();
        }
    }

    // Referenced by Reactor.Dispatch when UsePipe == true. We run UsePipe = false,
    // so this just defers to the raw handler.
    public static Task HandlePipeAsync(Reactor reactor, Connection conn) => HandleAsync(reactor, conn);
}

/// <summary>
/// Hand-rolled RFC 6455 state machine: accumulates inbound bytes, performs the
/// upgrade handshake, then parses/unmasks frames and queues unmasked echoes.
/// All output is appended to <see cref="Out"/> for the handler to flush.
/// </summary>
internal sealed class WsSession
{
    private const string WsGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    private const long MaxFrame = 16L << 20;

    private static readonly byte[] Resp400 =
        "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"u8.ToArray();
    private static readonly byte[] Resp404 =
        "HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"u8.ToArray();

    private bool _wsReady;
    private byte[] _carry = new byte[2048];
    private int _carryLen;

    public byte[] Out = new byte[4096];
    public int OutLen;
    public bool WantClose;

    public void Feed(ReadOnlySpan<byte> data)
    {
        AppendCarry(data);

        if (!_wsReady)
        {
            int he = FindHeaderEnd(_carry.AsSpan(0, _carryLen));
            if (he < 0)
            {
                if (_carryLen > 16384) { AppendOut(Resp400); WantClose = true; }
                return;
            }
            DoHandshake(he);
            if (WantClose) return;
            _wsReady = true;
        }

        DrainFrames();
    }

    // ── handshake ────────────────────────────────────────────────────────────
    private void DoHandshake(int he)
    {
        string head = Encoding.ASCII.GetString(_carry, 0, he);

        // Drop the request bytes (incl. the trailing CRLFCRLF); keep any frames.
        int consume = he + 4;
        _carryLen -= consume;
        if (_carryLen > 0) Array.Copy(_carry, consume, _carry, 0, _carryLen);

        string[] lines = head.Split("\r\n");
        string[] reqParts = (lines.Length > 0 ? lines[0] : "").Split(' ');
        string path = reqParts.Length > 1 ? reqParts[1] : "";

        string? key = null;
        bool upgrade = false;
        for (int i = 1; i < lines.Length; i++)
        {
            int c = lines[i].IndexOf(':');
            if (c < 0) continue;
            string name = lines[i][..c].Trim();
            string val = lines[i][(c + 1)..].Trim();
            if (name.Equals("Sec-WebSocket-Key", StringComparison.OrdinalIgnoreCase))
                key = val;
            else if (name.Equals("Upgrade", StringComparison.OrdinalIgnoreCase) &&
                     val.Equals("websocket", StringComparison.OrdinalIgnoreCase))
                upgrade = true;
        }

        if (path != "/ws") { AppendOut(Resp404); WantClose = true; return; }
        if (key is null || !upgrade) { AppendOut(Resp400); WantClose = true; return; }

        string accept = Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(key + WsGuid)));
        AppendOut(Encoding.ASCII.GetBytes(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" +
            $"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"));
    }

    // ── frames ───────────────────────────────────────────────────────────────
    private void DrainFrames()
    {
        int off = 0;
        while (true)
        {
            int consumed = ParseOne(_carry, off, _carryLen - off, out bool stop);
            if (consumed == 0) break;                       // incomplete
            if (consumed < 0) { WantClose = true; break; }  // protocol error
            off += consumed;
            if (stop) { WantClose = true; break; }          // close frame
        }
        int rem = _carryLen - off;
        if (rem > 0 && off > 0) Array.Copy(_carry, off, _carry, 0, rem);
        _carryLen = rem;
    }

    // Parse one frame at b[off..off+avail). Unmasks in place. Returns bytes
    // consumed, 0 if incomplete, -1 on protocol error. Echo appended to Out.
    private int ParseOne(byte[] b, int off, int avail, out bool stop)
    {
        stop = false;
        if (avail < 2) return 0;

        int b0 = b[off], b1 = b[off + 1];
        bool masked = (b1 & 0x80) != 0;
        long plen = b1 & 0x7F;
        int hdr = 2;

        if (plen == 126)
        {
            if (avail < 4) return 0;
            plen = (b[off + 2] << 8) | b[off + 3];
            hdr = 4;
        }
        else if (plen == 127)
        {
            if (avail < 10) return 0;
            plen = 0;
            for (int i = 0; i < 8; i++) plen = (plen << 8) | b[off + 2 + i];
            if (plen > MaxFrame) return -1;
            hdr = 10;
        }
        if (plen > MaxFrame) return -1;

        int maskOff = off + hdr;
        if (masked) { if (avail < hdr + 4) return 0; hdr += 4; }
        if (avail < hdr + plen) return 0;

        int payOff = off + hdr;
        int len = (int)plen;
        if (masked)
            for (int i = 0; i < len; i++) b[payOff + i] ^= b[maskOff + (i & 3)];

        int op = b0 & 0x0F;
        bool fin = (b0 & 0x80) != 0;
        if (op <= 0x2)            Emit(fin, op, b, payOff, len);   // cont / text / binary
        else if (op == 0x9)       Emit(true, 0xA, b, payOff, len); // ping → pong
        else if (op == 0x8)     { Emit(true, 0x8, b, payOff, len); stop = true; } // close
        // pong / reserved → ignore

        return hdr + len;
    }

    private void Emit(bool fin, int op, byte[] src, int srcOff, int len)
    {
        Span<byte> h = stackalloc byte[10];
        int k;
        h[0] = (byte)((fin ? 0x80 : 0) | (op & 0x0F));
        if (len < 126) { h[1] = (byte)len; k = 2; }
        else if (len <= 0xFFFF) { h[1] = 126; h[2] = (byte)(len >> 8); h[3] = (byte)len; k = 4; }
        else { h[1] = 127; ulong L = (ulong)len; for (int i = 0; i < 8; i++) h[2 + i] = (byte)(L >> (8 * (7 - i))); k = 10; }
        AppendOut(h[..k]);
        AppendOut(src.AsSpan(srcOff, len));
    }

    // ── buffers ──────────────────────────────────────────────────────────────
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

    private static int FindHeaderEnd(ReadOnlySpan<byte> b)
    {
        for (int i = 0; i + 3 < b.Length; i++)
            if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10)
                return i;
        return -1;
    }
}
