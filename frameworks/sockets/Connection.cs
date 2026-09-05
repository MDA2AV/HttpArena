using System.Buffers;
using System.Buffers.Text;
using System.Net.Security;
using System.Net.Sockets;
using System.Text;

namespace SocketsArena;

/// <summary>
/// One connection: read, parse every request the read contained, answer them into one buffer, and
/// write that buffer once.
/// </summary>
/// <remarks>
/// The batching is the point. A pipelined client puts many requests in a single segment, and
/// answering each with its own send would turn one read into a dozen syscalls; responses are
/// appended to a growable buffer and flushed when the parse runs out of complete requests. The
/// same path serves the unpipelined case at a batch of one, so there is no second code path for it.
/// </remarks>
internal sealed class Connection(Socket socket, Dataset dataset, SslStream? tls = null)
{
    private const int InitialRead = 16 * 1024;
    private const int InitialWrite = 16 * 1024;

    private byte[] _read = ArrayPool<byte>.Shared.Rent(InitialRead);
    private byte[] _write = ArrayPool<byte>.Shared.Rent(InitialWrite);
    private byte[]? _chunked;   // decoded chunked body, rented on first use

    private int _readEnd;      // bytes held in _read
    private int _written;      // bytes staged in _write

    public async Task RunAsync()
    {
        try
        {
            while (true)
            {
                var read = await ReadAsync(_read.AsMemory(_readEnd));

                if (read == 0)
                {
                    return; // peer closed
                }

                _readEnd += read;

                if (!await DrainAsync())
                {
                    return;
                }

                if (_written > 0)
                {
                    await SendAsync();
                }

                Compact();
            }
        }
        catch (SocketException) { }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
        finally
        {
            ArrayPool<byte>.Shared.Return(_read);
            ArrayPool<byte>.Shared.Return(_write);

            if (_chunked is not null)
            {
                ArrayPool<byte>.Shared.Return(_chunked);
            }

            if (tls is not null)
            {
                try { await tls.DisposeAsync(); } catch { }
            }

            try { socket.Shutdown(SocketShutdown.Both); } catch { }
            socket.Dispose();
        }
    }

    /// <summary>Answers every complete request in the buffer. False means the connection should close.</summary>
    private async ValueTask<bool> DrainAsync()
    {
        var consumed = 0;

        while (true)
        {
            var pending = _read.AsSpan(consumed, _readEnd - consumed);

            if (!Request.TryParse(pending, out var request, out var headerLength))
            {
                // Partial request. Grow if a single one cannot fit, otherwise wait for more bytes.
                if (consumed == 0 && _readEnd == _read.Length)
                {
                    Grow(ref _read, _read.Length * 2);
                }
                break;
            }

            var total = headerLength + request.ContentLength;
            var chunkedLength = 0;

            if (request.Chunked)
            {
                // Decoded from whatever has arrived; when the terminator has not, read more and
                // start the decode again rather than trying to resume mid-chunk.
                while (true)
                {
                    _chunked ??= ArrayPool<byte>.Shared.Rent(InitialRead);

                    var source = _read.AsSpan(consumed + headerLength, _readEnd - consumed - headerLength);

                    if (Chunked.TryDecode(source, _chunked, out chunkedLength, out var rawLength, out var overflow))
                    {
                        total = headerLength + rawLength;
                        break;
                    }

                    if (overflow)
                    {
                        Grow(ref _chunked, _chunked.Length * 2);
                        continue;
                    }

                    if (_readEnd == _read.Length)
                    {
                        Grow(ref _read, _read.Length * 2);
                    }

                    if (_written > 0)
                    {
                        await SendAsync();
                    }

                    var arrived = await ReadAsync(_read.AsMemory(_readEnd));

                    if (arrived == 0)
                    {
                        return false;
                    }

                    _readEnd += arrived;
                }
            }
            else if (request.ContentLength > 0)
            {
                // The body has to be here before it can be echoed back.
                while (_readEnd - consumed < total)
                {
                    if (_readEnd == _read.Length)
                    {
                        Grow(ref _read, Math.Max(_read.Length * 2, consumed + total));
                    }

                    // Anything staged so far goes out first: the client may be waiting on it
                    // before it sends the rest.
                    if (_written > 0)
                    {
                        await SendAsync();
                    }

                    var more = await ReadAsync(_read.AsMemory(_readEnd));

                    if (more == 0)
                    {
                        return false;
                    }

                    _readEnd += more;
                }
            }

            if (request.DelayMs > 0)
            {
                // The wait belongs to this connection, not to a thread: whatever is already staged
                // goes out first so the client is not left waiting on an earlier response.
                if (_written > 0)
                {
                    await SendAsync();
                }

                await Task.Delay(request.DelayMs);
            }

            // Taken after the awaits above: the buffer can be grown or refilled by them, so a span
            // captured earlier would point at the wrong array.
            Respond(in request, request.Chunked
                ? _chunked.AsSpan(0, chunkedLength)
                : _read.AsSpan(consumed + headerLength, request.ContentLength));

            consumed += total;

            if (!request.KeepAlive)
            {
                if (_written > 0)
                {
                    await SendAsync();
                }
                return false;
            }
        }

        // Shift whatever is left of a partial request to the front.
        if (consumed > 0)
        {
            _read.AsSpan(consumed, _readEnd - consumed).CopyTo(_read);
            _readEnd -= consumed;
        }

        return true;
    }

    private void Respond(in Request request, ReadOnlySpan<byte> body)
    {
        switch (request.Route)
        {
            case Route.Pipeline:
                Text("ok"u8, request.KeepAlive);
                return;

            case Route.Baseline:
            {
                var total = request.A + request.B;

                if (body.Length > 0 && Utf8Parser.TryParse(body, out int fromBody, out _))
                {
                    total += fromBody;
                }

                Span<byte> number = stackalloc byte[16];
                Utf8Formatter.TryFormat(total, number, out var written);
                Text(number[..written], request.KeepAlive);
                return;
            }

            case Route.Delay:
            {
                Span<byte> number = stackalloc byte[16];
                Utf8Formatter.TryFormat(request.DelayMs, number, out var written);
                Text(number[..written], request.KeepAlive);
                return;
            }

            case Route.Json:
            {
                var json = dataset.Render(request.A, request.B, request.AcceptsBrotli, request.AcceptsGzip,
                                          out var encoding);

                if (!dataset.IsAvailable)
                {
                    Status("503 Service Unavailable"u8, request.KeepAlive);
                    return;
                }

                Head("200 OK"u8, "application/json"u8, json.Length, request.KeepAlive, encoding, vary: true);
                Append(json);
                return;
            }

            case Route.Echo:
                Head("200 OK"u8, "application/octet-stream"u8, body.Length, request.KeepAlive, default, vary: false);
                Append(body);
                return;

            default:
                Status("404 Not Found"u8, request.KeepAlive);
                return;
        }
    }

    // ── response writing ─────────────────────────────────────────────────────────────────────

    private void Text(ReadOnlySpan<byte> value, bool keepAlive)
    {
        Head("200 OK"u8, "text/plain"u8, value.Length, keepAlive, default, vary: false);
        Append(value);
    }

    private void Status(ReadOnlySpan<byte> status, bool keepAlive)
        => Head(status, "text/plain"u8, 0, keepAlive, default, vary: false);

    private void Head(ReadOnlySpan<byte> status, ReadOnlySpan<byte> contentType, int length, bool keepAlive,
                      ReadOnlySpan<byte> encoding, bool vary)
    {
        Reserve(256 + contentType.Length + encoding.Length);

        Append("HTTP/1.1 "u8);
        Append(status);
        Append("\r\nContent-Type: "u8);
        Append(contentType);

        if (!encoding.IsEmpty)
        {
            Append("\r\nContent-Encoding: "u8);
            Append(encoding);
        }

        if (vary)
        {
            Append("\r\nVary: Accept-Encoding"u8);
        }

        Append("\r\nContent-Length: "u8);

        Utf8Formatter.TryFormat(length, _write.AsSpan(_written), out var written);
        _written += written;

        Append("\r\n"u8);
        Append(DateHeader.Line);

        Append(keepAlive ? "\r\n"u8 : "Connection: close\r\n\r\n"u8);
    }

    private void Append(ReadOnlySpan<byte> bytes)
    {
        Reserve(bytes.Length);
        bytes.CopyTo(_write.AsSpan(_written));
        _written += bytes.Length;
    }

    private void Reserve(int needed)
    {
        if (_written + needed > _write.Length)
        {
            Grow(ref _write, Math.Max(_write.Length * 2, _written + needed));
        }
    }

    // One branch per I/O op rather than a stream wrapper on the cleartext path: NetworkStream would
    // put an allocation and a virtual call in front of every read on the profiles that do not use TLS.
    private ValueTask<int> ReadAsync(Memory<byte> destination)
        => tls is null
            ? socket.ReceiveAsync(destination, SocketFlags.None)
            : tls.ReadAsync(destination);

    private async ValueTask SendAsync()
    {
        if (tls is null)
        {
            var sent = 0;

            while (sent < _written)
            {
                sent += await socket.SendAsync(_write.AsMemory(sent, _written - sent), SocketFlags.None);
            }
        }
        else
        {
            await tls.WriteAsync(_write.AsMemory(0, _written));
        }

        _written = 0;
    }

    private void Compact()
    {
        if (_readEnd == 0 && _read.Length > InitialRead)
        {
            // A large upload grew the buffer; give it back rather than holding it per connection.
            ArrayPool<byte>.Shared.Return(_read);
            _read = ArrayPool<byte>.Shared.Rent(InitialRead);
        }
    }

    private static void Grow(ref byte[] buffer, int size)
    {
        var grown = ArrayPool<byte>.Shared.Rent(size);
        buffer.CopyTo(grown.AsSpan());
        ArrayPool<byte>.Shared.Return(buffer);
        buffer = grown;
    }
}
