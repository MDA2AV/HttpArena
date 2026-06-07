using System.Text;

namespace Shrike;

internal class StringCacheMemoryVariant
{
    private readonly Dictionary<ReadOnlyMemory<byte>, string> _map;
    
    private readonly Lock _gate = new();

    public StringCacheMemoryVariant(List<string>? preCacheableStrings, int capacity = 256)
    {
        _map = new Dictionary<ReadOnlyMemory<byte>, string>(capacity, ReadOnlyMemoryComparer.Instance);

        if (preCacheableStrings is null)
        {
            return;
        }
        
        foreach (var preCacheableString in preCacheableStrings)
        {
            Add(preCacheableString);
        }
    }
    
    public bool TryGetOrAdd(ReadOnlyMemory<byte> bytes, out string value)
    {
        ref var item = ref CollectionsMarshal.GetValueRefOrNullRef(_map, bytes);
        if (!Unsafe.IsNullRef(ref item))
        {
            value = item; 
            return true; 
        }
        
        // Did not find a value, add it
        value = Encoding.UTF8.GetString(bytes.Span);
        return TryAdd(bytes, value);
    }
    
    private bool TryAdd(ReadOnlyMemory<byte> key, string value)
    {
        lock (_gate)
        {
            return _map.TryAdd(key, value);
        }
    }
    
    private void Add(string item)
    {
        lock (_gate)
        {
            var bytes = Encoding.UTF8.GetBytes(item);
            _map.TryAdd(bytes, item);
        }
    }
    
    private sealed class ReadOnlyMemoryComparer : IEqualityComparer<ReadOnlyMemory<byte>>
    {
        public static readonly ReadOnlyMemoryComparer Instance = new();

        public bool Equals(ReadOnlyMemory<byte> x, ReadOnlyMemory<byte> y)
            => x.Span.SequenceEqual(y.Span);

        public int GetHashCode(ReadOnlyMemory<byte> mem)
        {
            var span = mem.Span;
            var h = new HashCode();
            h.AddBytes(span);
            return h.ToHashCode();
        }
    }
}