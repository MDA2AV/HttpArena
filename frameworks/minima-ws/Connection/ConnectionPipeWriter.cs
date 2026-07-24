using System.IO.Pipelines;
// ReSharper disable SuggestVarOrType_BuiltInTypes

namespace Minima;

/// <summary>
/// Adapts Minima's <see cref="Connection"/> write API (GetMemory/GetSpan/Advance/
/// FlushAsync) to a standard <see cref="PipeWriter"/>, so PipeWriter-based code
/// can write responses through the connection's per-connection slab.
/// A thin wrapper — all the work lives in Connection.
/// </summary>
public sealed class ConnectionPipeWriter : PipeWriter
{
    private readonly Connection _conn;
    private bool _completed;
    private bool _cancelRequested;
    private long _unflushed;

    public ConnectionPipeWriter(Connection connection)
    {
        _conn = connection ?? throw new ArgumentNullException(nameof(connection));
    }

    public override bool CanGetUnflushedBytes => true;
    public override long UnflushedBytes => _unflushed;

    public override Memory<byte> GetMemory(int sizeHint = 0) => _conn.GetMemory(sizeHint);

    public override Span<byte> GetSpan(int sizeHint = 0) => _conn.GetSpan(sizeHint);

    public override void Advance(int bytes)
    {
        _unflushed += bytes;
        _conn.Advance(bytes);
    }

    public override ValueTask<FlushResult> FlushAsync(CancellationToken cancellationToken = default)
    {
        if (_cancelRequested)
        {
            _cancelRequested = false;
            return new ValueTask<FlushResult>(new FlushResult(isCanceled: true, isCompleted: _completed));
        }

        _unflushed = 0;
        ValueTask inner = _conn.FlushAsync();

        if (inner.IsCompletedSuccessfully)
            return new ValueTask<FlushResult>(new FlushResult(isCanceled: false, isCompleted: _completed));

        return AwaitFlush(inner);
    }

    private async ValueTask<FlushResult> AwaitFlush(ValueTask inner)
    {
        await inner;
        return new FlushResult(isCanceled: false, isCompleted: _completed);
    }

    public override void CancelPendingFlush() => _cancelRequested = true;

    public override void Complete(Exception? exception = null) => _completed = true;
}
