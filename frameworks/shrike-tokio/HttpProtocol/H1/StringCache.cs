using System.Text;

namespace Shrike;

internal class StringCache
{
    private readonly Dictionary<PinnedByteSequence, string> _map;
    
    private readonly Lock _gate = new();

    public StringCache(List<string>? preCacheableStrings, int capacity = 256)
    {
        _map = new Dictionary<PinnedByteSequence, string>(capacity, PinnedByteSequenceComparer.Instance);

        if (preCacheableStrings is null)
        {
            return;
        }
        
        foreach (var preCacheableString in preCacheableStrings)
        {
            Add(preCacheableString);
        }
    }

    public string? GetOrAdd(ReadOnlySpan<byte> bytes)
    {
        var seq = new PinnedByteSequence(bytes);
        
        ref var item = ref CollectionsMarshal.GetValueRefOrNullRef(_map, seq);
        if (!Unsafe.IsNullRef(ref item))
        {
            return item; 
        }
        
        // Did not find a value, add it
        var value = Encoding.UTF8.GetString(bytes);
        if (TryAdd(seq, value))
        {
            return value;
        }

        return null;
    }
    
    public bool TryGetOrAdd(ReadOnlySpan<byte> bytes, out string value)
    {
        var seq = new PinnedByteSequence(bytes);
        
        ref var item = ref CollectionsMarshal.GetValueRefOrNullRef(_map, seq);
        if (!Unsafe.IsNullRef(ref item))
        {
            value = item; 
            return true; 
        }
        
        // Did not find a value, add it
        value = Encoding.UTF8.GetString(bytes);
        return TryAdd(seq, value);
    }
    
    private bool TryAdd(PinnedByteSequence key, string value)
    {
        var allocatedKey = AllocateSequence(key);
        
        lock (_gate)
        {
            return _map.TryAdd(allocatedKey, value);
        }
    }

    private unsafe PinnedByteSequence AllocateSequence(PinnedByteSequence sequence)
    {
        // Allocate pinned unmanaged slab
        var ptr = (byte*)NativeMemory.AlignedAlloc((nuint)sequence.Length, 64);
        
        Buffer.MemoryCopy(
            sequence.Ptr, 
            ptr, 
            sequence.Length, 
            sequence.Length);
        
        return new PinnedByteSequence(ptr, sequence.Length);
    }
    
    private void Add(string item)
    {
        lock (_gate)
        {
            var bytes = Encoding.UTF8.GetBytes(item);
            var seq = new PinnedByteSequence(bytes);
            _map.TryAdd(seq, item);
        }
    }
    
    private sealed class PinnedByteSequenceComparer : IEqualityComparer<PinnedByteSequence>
    {
        public static readonly PinnedByteSequenceComparer Instance = new();

        public bool Equals(PinnedByteSequence x, PinnedByteSequence y)
        {
            return x.AsSpan().SequenceEqual(y.AsSpan());
        }

        public int GetHashCode(PinnedByteSequence mem)
        {
            var span = mem.AsSpan();
            var h = new HashCode();
            h.AddBytes(span);
            return h.ToHashCode();
        }
    }
}