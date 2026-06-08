using System.Buffers;
using System.IO.Pipelines;
using Minima.Utils;
// ReSharper disable SuggestVarOrType_BuiltInTypes

namespace Minima;

/// <summary>
/// Adapts Minima's raw <see cref="Connection"/> read API (ReadAsync + TryGetItem
/// + ReturnBuffer) to a standard <see cref="PipeReader"/>. Recv buffers are
/// exposed zero-copy as a ReadOnlySequence&lt;byte&gt; (one segment per buffer)
/// and held until AdvanceTo consumes them, at which point fully-consumed buffers
/// are returned to the reactor.
///
/// Convenience/compat layer for PipeReader consumers — the raw ReadAsync/
/// TryGetItem path stays the faster one (this adds held-buffer + sequence
/// bookkeeping per read).
/// </summary>
public sealed class ConnectionPipeReader : PipeReader
{
    private readonly Connection _conn;
    private readonly List<Held> _held = new(16);
    private ReadOnlySequence<byte> _lastSequence;

    private bool _completed;
    private bool _cancelRequested;
    private bool _connectionClosed;

    private readonly struct Held
    {
        public readonly ReadOnlyMemory<byte> Memory;
        public readonly SpscRecvRing.Item Item;

        public Held(ReadOnlyMemory<byte> memory, SpscRecvRing.Item item)
        {
            Memory = memory;
            Item = item;
        }

        public Held WithMemory(ReadOnlyMemory<byte> memory) => new(memory, Item);
    }

    public ConnectionPipeReader(Connection connection)
    {
        _conn = connection ?? throw new ArgumentNullException(nameof(connection));
    }

    public override async ValueTask<ReadResult> ReadAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfCompleted();

        if (_cancelRequested)
        {
            _cancelRequested = false;
            return new ReadResult(BuildSequence(), isCanceled: true, isCompleted: _connectionClosed);
        }

        // Anything still held from a previous read that wasn't fully consumed.
        if (_held.Count > 0)
            return new ReadResult(BuildSequence(), isCanceled: false, isCompleted: _connectionClosed);

        if (_connectionClosed)
            return new ReadResult(default, isCanceled: false, isCompleted: true);

        RecvSnapshot snap = await _conn.ReadAsync();

        while (_conn.TryGetItem(snap, out SpscRecvRing.Item item))
        {
            if (item.HasBuffer)
                _held.Add(new Held(item.AsMemoryManager().Memory, item));
        }

        _conn.ResetRead();

        if (snap.IsClosed)
            _connectionClosed = true;

        if (_cancelRequested)
        {
            _cancelRequested = false;
            return new ReadResult(BuildSequence(), isCanceled: true, isCompleted: _connectionClosed);
        }

        return new ReadResult(BuildSequence(), isCanceled: false, isCompleted: _connectionClosed);
    }

    public override bool TryRead(out ReadResult result)
    {
        ThrowIfCompleted();

        if (_held.Count > 0)
        {
            result = new ReadResult(BuildSequence(), isCanceled: false, isCompleted: _connectionClosed);
            return true;
        }

        if (_connectionClosed)
        {
            result = new ReadResult(default, isCanceled: false, isCompleted: true);
            return true;
        }

        result = default;
        return false;
    }

    public override void AdvanceTo(SequencePosition consumed) => AdvanceTo(consumed, consumed);

    public override void AdvanceTo(SequencePosition consumed, SequencePosition examined)
    {
        if (_held.Count == 0)
            return;

        long consumedBytes = _lastSequence.Slice(0, consumed).Length;

        while (_held.Count > 0 && consumedBytes > 0)
        {
            Held seg = _held[0];
            int available = seg.Memory.Length;

            if (consumedBytes >= available)
            {
                // Whole buffer consumed — return it to the reactor.
                _conn.ReturnBuffer(seg.Item);
                _held.RemoveAt(0);
                consumedBytes -= available;
            }
            else
            {
                // Partial — keep the unconsumed tail of this buffer.
                _held[0] = seg.WithMemory(seg.Memory[(int)consumedBytes..]);
                consumedBytes = 0;
            }
        }
    }

    public override void CancelPendingRead() => _cancelRequested = true;

    public override void Complete(Exception? exception = null)
    {
        if (_completed)
            return;

        _completed = true;

        for (int i = 0; i < _held.Count; i++)
            _conn.ReturnBuffer(_held[i].Item);

        _held.Clear();
    }

    private ReadOnlySequence<byte> BuildSequence()
    {
        if (_held.Count == 0)
        {
            _lastSequence = default;
            return _lastSequence;
        }

        if (_held.Count == 1)
        {
            _lastSequence = new ReadOnlySequence<byte>(_held[0].Memory);
            return _lastSequence;
        }

        var head = new RingSegment(_held[0].Memory, _held[0].Item.Bid);
        RingSegment tail = head;

        for (int i = 1; i < _held.Count; i++)
            tail = tail.Append(_held[i].Memory, _held[i].Item.Bid);

        _lastSequence = new ReadOnlySequence<byte>(head, 0, tail, tail.Memory.Length);
        return _lastSequence;
    }

    private void ThrowIfCompleted()
    {
        if (_completed)
            throw new InvalidOperationException("Reading is not allowed after the reader was completed.");
    }
}
