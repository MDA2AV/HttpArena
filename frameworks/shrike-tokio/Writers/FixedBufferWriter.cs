// ReSharper disable always CheckNamespace
// ReSharper disable always SuggestVarOrType_BuiltInTypes
// (var is avoided intentionally in this project so that concrete types are visible at call sites.)
// ReSharper disable always StackAllocInsideLoop
// ReSharper disable always ClassCannotBeInstantiated

using System.Text;

#pragma warning disable CA2014

namespace Shrike;

/// <summary>
/// A high-performance, *unmanaged* buffer writer designed for scenarios where
/// zero allocations and deterministic memory layout are critical.
///
/// This struct provides a writable view over a fixed memory region (provided as
/// a raw <see cref="byte*"/> pointer). It does not own or allocate memory itself
/// — unless the caller provides it one that was manually allocated, in which
/// case <see cref="Dispose"/> can free it if desired.
///
/// The typical use case is for writing binary or HTTP data directly into a
/// pre-allocated unmanaged buffer (e.g., a native slab per connection) without
/// heap allocations or GC involvement.
/// </summary>
[SkipLocalsInit]
public unsafe class FixedBufferWriter : IUnmanagedBufferWriter<byte>, IBufferWriter<byte>, IDisposable
{
    private readonly int _capacity;
    private readonly UnmanagedMemoryManager _manager;
    public int Head;
    public int Tail;
    
    public byte* Ptr { get; }
    
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public FixedBufferWriter(byte* ptr, int capacity)
    {
        Ptr = ptr;
        _capacity = capacity;
        Head = 0;
        Tail = 0;
        
        _manager = new UnmanagedMemoryManager(ptr, capacity);
    }
    
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Reset()
    {
        Head = 0;
        Tail = 0;
    }
    
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Advance(int count)
    {
        //Volatile.Write(ref Tail, Tail + count);
        Tail += count;
    }

    public Memory<byte> GetMemory(int sizeHint = 0)
    {
        int remaining = _capacity - Tail;
        if (sizeHint > remaining)
        {
            throw new InvalidOperationException("Buffer too small.");
        }
        
        return _manager.Memory.Slice(Tail, remaining);
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public byte* GetPointer() => Ptr;
    
    public Span<byte> GetSpan(int sizeHint = 0)
    {
        if (Tail + sizeHint > _capacity)
        {
            throw new InvalidOperationException("Buffer too small.");
        }

        return new Span<byte>(Ptr + Tail, _capacity - Tail);
    }
    
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void WriteUnmanaged(ReadOnlySpan<byte> source)
    {
        int len = source.Length;
        if (Tail + len > _capacity)
        {
            throw new InvalidOperationException("Buffer too small.");
        }

        fixed (byte* src = source)
        {
            Buffer.MemoryCopy(src, Ptr + Tail, _capacity - Tail, len);
        }
        
        Tail += len;
    }

    public void WriteUnmanaged(string source)
    {
        var span = new Span<byte>(Ptr + Tail, _capacity - Tail);
        var bytesWritten = Encoding.UTF8.GetBytes(source, span);
        Tail += bytesWritten;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Write(ReadOnlySpan<byte> source)
    {
        int len = source.Length;
        if (Tail + len > _capacity)
        {
            throw new InvalidOperationException("Buffer too small.");
        }

        source.CopyTo(new Span<byte>(Ptr + Tail, _capacity - Tail));
        Tail += len;
    }

    public void Dispose()
    {
        if (Ptr != null)
        {
            NativeMemory.AlignedFree(Ptr);
        }
    }
}