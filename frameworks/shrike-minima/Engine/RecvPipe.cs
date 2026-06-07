namespace Shrike;

/// <summary>
/// Per-connection single-producer / single-consumer ring of received chunks
/// (Minima-style recv handoff). The worker (producer) recv's into pooled buffers
/// and enqueues (ptr, len); the handler (consumer) dequeues them, copies the bytes
/// into its own parse buffer, and returns the buffer to the pool. Producer and
/// consumer touch disjoint ends (tail / head) with release/acquire ordering, so the
/// recv buffer is never shared between the two threads — no driver/handler race.
/// </summary>
public sealed unsafe class SpscRing
{
    private struct Slot { public byte* Ptr; public int Len; }

    private readonly Slot[] _slots;
    private readonly int _mask;
    private int _head;   // consumer (handler) only writes this
    private int _tail;   // producer (worker) only writes this

    public SpscRing(int capacityPow2)
    {
        _slots = new Slot[capacityPow2];
        _mask = capacityPow2 - 1;
    }

    /// <summary>Producer (worker thread). Returns false if the ring is full.</summary>
    public bool TryEnqueue(byte* ptr, int len)
    {
        int tail = _tail;
        if (tail - Volatile.Read(ref _head) >= _slots.Length) return false;
        _slots[tail & _mask] = new Slot { Ptr = ptr, Len = len };
        Volatile.Write(ref _tail, tail + 1);   // release: publish slot before tail
        return true;
    }

    /// <summary>Consumer (handler thread). Returns false if empty.</summary>
    public bool TryDequeue(out byte* ptr, out int len)
    {
        int head = _head;
        if (head == Volatile.Read(ref _tail)) { ptr = null; len = 0; return false; } // acquire
        Slot s = _slots[head & _mask];
        ptr = s.Ptr;
        len = s.Len;
        Volatile.Write(ref _head, head + 1);
        return true;
    }
}

/// <summary>
/// Global pool of fixed-size native recv buffers. The worker takes one to recv into;
/// the handler returns it after copying the bytes into its parse buffer. Thread-safe.
/// </summary>
internal static unsafe class RecvPool
{
    public const int BufSize = 16 * 1024;
    private static readonly System.Collections.Concurrent.ConcurrentQueue<IntPtr> Free = new();

    public static byte* Take()
        => Free.TryDequeue(out IntPtr p) ? (byte*)p : (byte*)NativeMemory.Alloc(BufSize);

    public static void Return(byte* buf) => Free.Enqueue((IntPtr)buf);
}
