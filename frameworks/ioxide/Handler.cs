using System.Runtime.InteropServices;

using ioxide;
using ioxide.file;
using ioxide.pg;
using ioxide.tls;
using ioxide.http2;
using ioxide.utils;

namespace IoxideArena;

internal static class Handler
{
    // Connection: close is an HTTP decision, so honouring it is this entry's job
    // rather than the transport's -- ioxide moves bytes and knows nothing about
    // HTTP. It hands out the accepted descriptor, which is all that is needed:
    // half-close the write side and the peer sees EOF.
    //
    // SHUT_WR rather than close(2) on purpose. The descriptor's lifetime belongs
    // to ioxide, which closes it when the refcount drops in DecRef below;
    // closing it here would free a number the reactor still holds and the next
    // accept could hand the same integer to somebody else. Shutting down the
    // write side sends the FIN without touching ownership.
    private const int ShutWr = 1;

    [DllImport("libc", EntryPoint = "shutdown", SetLastError = true)]
    private static extern int Shutdown(int fd, int how);

    private static int _slab = 16 * 1024;
    private static Dataset _dataSet = Dataset.Empty;
    private static StaticAssets? _staticAssets;
    private static Precompressed? _precompressed;
    private static bool _hasPg;
    private static bool _hasTls;
    private static bool _hasCache;

    public static void Init(ServerConfig config, Dataset ds, StaticAssets? assets, Precompressed? precompressed, bool hasPg, bool hasTls, bool hasCache)
    {
        _slab = config.Tcp!.WriteSlabSize;
        _dataSet = ds;
        _staticAssets = assets;
        _precompressed = precompressed;
        _hasPg = hasPg;
        _hasTls = hasTls;
        _hasCache = hasCache;
    }

    public static async Task HandleAsync(Reactor reactor, TcpConnection conn)
    {
        if (conn.ListenerPort == 8443)
        {
            await ServeH2Async(reactor, conn);
            return;
        }

        var httpSession = new HttpSession(_dataSet, _staticAssets, _precompressed);
        PgPool? pool = _hasPg ? reactor.GetService<PgPool>() : null;
        ICrudCache? cache = _hasCache ? reactor.GetService<ICrudCache>() : null;
        PgRowHandler rowSink = httpSession.AppendDbRow;       // async-db rows
        PgRowHandler listSink = httpSession.AppendCrudRow;    // crud list rows
        PgRowHandler itemSink = httpSession.CaptureCrudItem;  // crud single item
        TlsSession? tls = null;

        try
        {
            if (_hasTls && conn.ListenerPort == 8081)
            {
                // Handshake over the ring, then kTLS TX: outbound writes below are plaintext
                // and the kernel produces the records. Inbound stays userspace: each slice
                // decrypts through the session. The client's first request can ride in with its
                // Finished flight, so feed it before the loop parks on a read.
                tls = await reactor.GetService<TlsService>().AcceptAsync(conn);
                httpSession.Feed(tls.DrainPlaintext());
            }

            // Send-first: respond to whatever is already parsed (a request bundled
            // with the TLS handshake, or a prior read) before parking on the next
            // read. A read-first loop would deadlock on the bundled-request case.
            while (true)
            {
                // /async-db parks the parser: run the query (inline on this reactor's
                // ring via ioxide.pg), stream rows into Out, then resume the carry -
                // pipelined requests behind it are served in order.
                while (httpSession.PendingDb)
                {
                    httpSession.PendingDb = false;
                    if (pool != null)
                    {
                        httpSession.BeginDbResponse();
                        await pool.QueryRowsAsync(httpSession.PendingDbSql(), rowSink);
                        httpSession.EndDbResponse();
                    }
                    else
                    {
                        httpSession.WriteDbUnavailable();
                    }

                    if (httpSession.PendingDbClose) httpSession.WantClose = true;
                    else httpSession.ResumeFeed();
                }

                while (httpSession.PendingCrud != CrudKind.None)
                {
                    CrudKind kind = httpSession.PendingCrud;
                    httpSession.PendingCrud = CrudKind.None;

                    if (pool == null)
                    {
                        httpSession.WriteCrudUnavailable();
                    }
                    else switch (kind)
                    {
                        case CrudKind.List:
                            httpSession.BeginCrudList();
                            await httpSession.SubmitCrudList(pool, listSink);
                            httpSession.EndCrudList();
                            break;

                        case CrudKind.GetOne:
                            string key = httpSession.CacheKey();
                            string? cached = cache != null ? await cache.GetAsync(key) : null;
                            if (cached != null)
                            {
                                httpSession.WriteCrudItemResponse(System.Text.Encoding.UTF8.GetBytes(cached), cacheHit: true);
                            }
                            else
                            {
                                httpSession.ResetCrudItem();
                                await httpSession.SubmitCrudItem(pool, itemSink);
                                if (httpSession.CrudItemFound)
                                {
                                    if (cache != null)
                                        await cache.SetExAsync(key, System.Text.Encoding.UTF8.GetString(httpSession.CrudItemBody()), 1);
                                    httpSession.WriteCrudItemResponse(httpSession.CrudItemBody(), cacheHit: false);
                                }
                                else
                                {
                                    httpSession.WriteCrud404();
                                }
                            }
                            break;

                        case CrudKind.Create:
                            await httpSession.SubmitCrudInsert(pool);
                            httpSession.WriteCrudStatus("HTTP/1.1 201 Created\r\nContent-Length: 0\r\n"u8);
                            break;

                        case CrudKind.Update:
                            await httpSession.SubmitCrudUpdate(pool);
                            if (cache != null) await cache.DelAsync(httpSession.CacheKey());
                            httpSession.WriteCrudStatus("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n"u8);
                            break;
                    }

                    if (httpSession.PendingCrudClose) httpSession.WantClose = true;
                    else httpSession.ResumeFeed();
                }

                // Baked static responses go straight to the wire (not through Out) - no extra copy,
                // and Out never grows to the largest asset, so per-connection memory stays flat
                // under load. Sent before Out, which preserves order (Direct is only set when it was
                // the first response of the batch).
                if (httpSession.HasDirect)
                {
                    int dsent = 0;
                    while (dsent < httpSession.DirectLen)
                    {
                        int dchunk = Math.Min(httpSession.DirectLen - dsent, _slab);
                        WriteDirect(conn, httpSession, dsent, dchunk);
                        await conn.FlushAsync();
                        dsent += dchunk;
                    }
                    httpSession.ClearDirect();
                }

                int sent = 0;
                while (sent < httpSession.OutLen)
                {
                    int chunk = Math.Min(httpSession.OutLen - sent, _slab);
                    conn.Write(httpSession.Out.AsSpan(sent, chunk));

                    // The static header is the tail of Out, so the file goes into the slab right
                    // behind it and header + body leave in ONE flush - no reader buffer and no
                    // copy of the body, which is the whole point of ReadFileAsync. The slab grows
                    // to fit; ioxide.file only hands out a descriptor and a length.
                    if (sent + chunk == httpSession.OutLen && httpSession.PendingStaticFd != 0)
                    {
                        int n = await conn.ReadFileAsync(httpSession.PendingStaticFd,
                                                         (int)httpSession.PendingStaticLen, fileOffset: 0);
                        conn.AdvanceWrite(n);
                        httpSession.PendingStaticFd = 0;
                        if (httpSession.PendingStaticClose) httpSession.WantClose = true;
                    }

                    await conn.FlushAsync();
                    sent += chunk;
                }
                httpSession.OutLen = 0;
                httpSession.PendingStaticFd = 0;

                if (httpSession.WantClose || (tls?.Closed ?? false))
                    return;

                RecvSnapshot snap = await conn.ReadAsync();
                FeedSlices(httpSession, conn, tls, snap);
                if (snap.IsClosed)
                {
                    httpSession.WantClose = true;
                }
                else
                {
                    conn.ResetRead();
                }
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[{Thread.CurrentThread.Name}] http handler crash fd={conn.ClientFd}: {ex}");
        }
        finally
        {
            tls?.Dispose();
            // The loop only reaches here when this connection is finished: the
            // peer closed, the request asked for Connection: close, or it
            // faulted. Without the FIN the response goes out saying
            // "Connection: close" and the socket stays open, so any client that
            // reads to EOF -- curl, and scripts/validate-frag.py -- hangs until
            // its own timeout.
            int fd = conn.ClientFd;
            if (fd >= 0) Shutdown(fd, ShutWr);
            conn.DecRef();
        }
    }

    // Copy one slab-sized slice of the direct (baked static) response into the connection's write
    // slab - managed precompressed buffer or native identity response. Kept in a sync unsafe helper
    // so the native pointer never crosses an await in the async handler.
    private static unsafe void WriteDirect(TcpConnection conn, HttpSession s, int off, int len)
    {
        if (s.DirectBytes != null)
        {
            conn.Write(s.DirectBytes.AsSpan(off, len));
        }
        else
        {
            conn.Write(new ReadOnlySpan<byte>((void*)(s.DirectPtr + off), len));
        }
    }

    private static async Task ServeH2Async(Reactor reactor, TcpConnection conn)
    {
        TlsSession? session = null;
        try
        {
            session = await reactor.GetService<H2Tls>().Service.AcceptAsync(conn);
            await using var pipe = new TlsConnectionDualPipe(conn, session, ownsSession: false);
            await new Http2Connection(pipe).RunBufferedAsync(Multiplexed.RouteH2);
        }
        catch
        {
            // probe / handshake fault
        }
        finally
        {
            session?.Dispose();
            conn.DecRef();
        }
    }

    private static unsafe void FeedSlices(HttpSession s, TcpConnection conn, TlsSession? tls, in RecvSnapshot snap)
    {
        while (conn.TryGetItem(snap, out SpscRecvRing.Item item))
        {
            if (!item.HasBuffer)
            {
                continue;
            }
            if (tls != null)
            {
                s.Feed(tls.Decrypt(item.Ptr, item.Len));
            }
            else
            {
                s.Feed(item.AsSpan());
            }
            
            conn.ReturnBuffer(in item);
        }
    }
}