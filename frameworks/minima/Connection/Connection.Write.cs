using System.Buffers;
using System.Threading.Tasks.Sources;
using Minima.Utils;

// ReSharper disable SuggestVarOrType_BuiltInTypes

namespace Minima;

public sealed unsafe partial class Connection : IValueTaskSource, IBufferWriter<byte>
{
    private readonly int _writeSlabSize;
    internal byte* WriteBuffer;
    internal int   WriteHead;
    internal int   WriteTail;
    internal int   WriteInFlight;
    
    private readonly UnmanagedMemoryManager _manager;

    private ManualResetValueTaskSourceCore<bool> _flushSignal = new()
    {
        RunContinuationsAsynchronously = false,
    };
    private int _flushArmed;
    private int _flushInProgress;
    
    // IBufferWrite<byte>
#region IBufferWrite<byte>
    
    public Memory<byte> GetMemory(int sizeHint = 0)
    {
        if (Volatile.Read(ref _flushInProgress) != 0)
        {
            throw new InvalidOperationException("Cannot write while flush is in progress.");
        }

        int remaining = _writeSlabSize - WriteTail;
        if (sizeHint > remaining)
        {
            throw new InvalidOperationException("Buffer too small.");
        }

        return _manager.Memory.Slice(WriteTail, remaining);
    }

    public Span<byte> GetSpan(int sizeHint = 0)
    {
        if (Volatile.Read(ref _flushInProgress) != 0)
        {
            throw new InvalidOperationException("Cannot write while flush is in progress.");
        }

        if (WriteTail + sizeHint > _writeSlabSize)
        {
            throw new InvalidOperationException("Write buffer too small.");
        }

        return new Span<byte>(WriteBuffer + WriteTail, _writeSlabSize - WriteTail);
    }

    public void Advance(int count)
    {
        if (Volatile.Read(ref _flushInProgress) != 0)
        {
            throw new InvalidOperationException("Cannot write while flush is in progress.");
        }

        WriteTail += count;
    }
    
#endregion
    
    // Write to the inner buffer
    public void Write(ReadOnlySpan<byte> source)
    {
        if (Volatile.Read(ref _flushInProgress) != 0)
        {
            throw new InvalidOperationException("Cannot write while flush is in progress.");
        }

        int len = source.Length;
        if (WriteTail + len > _writeSlabSize)
        {
            throw new InvalidOperationException("Write buffer too small.");
        }

        source.CopyTo(new Span<byte>(WriteBuffer + WriteTail, len));
        WriteTail += len;
    }

    // Flush inner buffer data to the kernel
    public ValueTask FlushAsync()
    {
        // Connection already torn down (reactor saw EOF/error → MarkClosed): don't flush
        // a removed connection — the handoff would reach a reactor that no longer knows
        // this fd and the awaiter would hang. Return completed so the handler unwinds to
        // its next ReadAsync, sees IsClosed, and exits.
        if (Volatile.Read(ref _closed) == 1)
        {
            return default;
        }

        if (Interlocked.Exchange(ref _flushInProgress, 1) == 1)
        {
            throw new InvalidOperationException("FlushAsync already in progress.");
        }

        int target = WriteTail;
        if (target == 0)
        {
            Volatile.Write(ref _flushInProgress, 0);
            
            return default;
        }

        if (Interlocked.Exchange(ref _flushArmed, 1) == 1)
        {
            throw new InvalidOperationException("FlushAsync already armed.");
        }

        _flushSignal.Reset();
        WriteInFlight = target;

        int gen = Volatile.Read(ref _generation);

        _reactor.EnqueueFlush(ClientFd);

        // Race recovery (mirrors ReadAsync): if close raced in after the guard above,
        // self-complete so we don't hang waiting on a send the reactor will never make.
        if (Volatile.Read(ref _closed) == 1 && Interlocked.Exchange(ref _flushArmed, 0) == 1)
        {
            Volatile.Write(ref _flushInProgress, 0);
            _flushSignal.SetResult(true);
        }

        return new ValueTask(this, (short)gen);
    }

    // Signal the FlushAsync was completed, called by the reactor's dispatcher send branch
    internal void CompleteFlush()
    {
        WriteHead = 0;
        WriteTail = 0;
        WriteInFlight = 0;
        Volatile.Write(ref _flushInProgress, 0);
        Interlocked.Exchange(ref _flushArmed, 0);
        
        _flushSignal.SetResult(true);
    }
    
    // IValueTaskSource
#region IValueTaskSource
    
    void IValueTaskSource.GetResult(short token)
    {
        if (token != (short)Volatile.Read(ref _generation))
        {
            return;
        }
        
        _flushSignal.GetResult(_flushSignal.Version);
    }

    ValueTaskSourceStatus IValueTaskSource.GetStatus(short token)
    {
        if (token != (short)Volatile.Read(ref _generation))
        {
            return ValueTaskSourceStatus.Succeeded;
        }
        
        return _flushSignal.GetStatus(_flushSignal.Version);
    }

    void IValueTaskSource.OnCompleted(Action<object?> continuation, object? state, short token, ValueTaskSourceOnCompletedFlags flags)
    {
        if (token != (short)Volatile.Read(ref _generation))
        {
            continuation(state);
            
            return;
        }
        _flushSignal.OnCompleted(continuation, state, _flushSignal.Version, flags);
    }
    
#endregion
}