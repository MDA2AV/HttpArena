namespace Shrike;

public readonly unsafe struct PinnedByteSequence : IEquatable<PinnedByteSequence>
{
    private readonly byte* _ptr { get; }
    
    public readonly byte* Ptr => _ptr;

    public int Length { get; }
    
    public PinnedByteSequence(ReadOnlySpan<byte> span)
    {
        _ptr = (byte*)Unsafe.AsPointer(ref MemoryMarshal.GetReference(span));
        Length = span.Length;
    }

    public PinnedByteSequence(byte* ptr, int length)
    {
        _ptr = ptr;
        Length = length;
    }
    
    public unsafe ReadOnlySpan<byte> AsSpan() => new(_ptr, Length);

    public bool Equals(PinnedByteSequence other)
    {
        return _ptr == other._ptr && Length == other.Length;
    }

    public override bool Equals(object? obj)
    {
        return obj is PinnedByteSequence other && Equals(other);
    }

    public override int GetHashCode()
    {
        return HashCode.Combine(unchecked((int)(long)_ptr), Length);
    }
}