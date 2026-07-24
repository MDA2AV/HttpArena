using System.Runtime.CompilerServices;

// ReSharper disable SuggestVarOrType_BuiltInTypes

namespace Minima.Utils;

public sealed unsafe class SpscRecvRing
{
    public struct Item
    {
        public byte* Ptr;
        public ushort Bid;
        public int Len;
        public bool HasBuffer;
        public ushort Gen;   // connection generation when enqueued (incremental return guard)

        public ReadOnlySpan<byte> AsSpan() => new(Ptr, Len);

        public UnmanagedMemoryManager AsMemoryManager() => new(Ptr, Len, Bid);
    }

    private readonly Item[] _items;
    private readonly int _mask;
    private long _tail;
    private long _head;

    public SpscRecvRing(int capacityPow2)
    {
        if (capacityPow2 <= 0 || (capacityPow2 & (capacityPow2 - 1)) != 0)
        {
            throw new ArgumentException("capacity must be a power of two", nameof(capacityPow2));
        }
        
        _items = new Item[capacityPow2];
        _mask  = capacityPow2 - 1;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public bool TryEnqueue(in Item item)
    {
        long head = Volatile.Read(ref _head);
        long tail = _tail;
        
        if ((ulong)(tail - head) >= (ulong)_items.Length)
        {
            return false;
        }
        
        _items[(int)(tail & _mask)] = item;
        Volatile.Write(ref _tail, tail + 1);
        
        return true;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public bool TryDequeue(out Item item)
    {
        long head = _head;
        long tail = Volatile.Read(ref _tail);
        
        if (head >= tail)
        {
            item = default; 
            return false;
        }
        
        item = _items[(int)(head & _mask)];
        Volatile.Write(ref _head, head + 1);
        
        return true;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public long SnapshotTail() => Volatile.Read(ref _tail);

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public bool TryDequeueUntil(long tailSnapshot, out Item item)
    {
        long head = _head;
        
        if (head >= tailSnapshot)
        {
            item = default; 
            return false; 
        }
        
        item = _items[(int)(head & _mask)];
        Volatile.Write(ref _head, head + 1);
        
        return true;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public bool IsEmpty() => Volatile.Read(ref _head) >= Volatile.Read(ref _tail);

    // Reactor-thread-only, called during connection teardown (Clear) when no
    // handler is consuming. Discards any leftover items so the recycled
    // connection starts empty.
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Reset()
    {
        _head = 0;
        _tail = 0;
    }
}
