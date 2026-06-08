using System.Buffers;

namespace Minima.Utils;

public sealed unsafe class UnmanagedMemoryManager : MemoryManager<byte>
{
    private readonly byte* _ptr;
    private readonly int _length;

    public ushort BufferId { get; }
    
    public UnmanagedMemoryManager(byte* ptr, int length)
    {
        _ptr = ptr;
        _length = length;
    }

    public UnmanagedMemoryManager(byte* ptr, int length, ushort bufferId)
    {
        _ptr = ptr;
        _length = length;
        BufferId = bufferId;
    }

    public override Span<byte> GetSpan() => new(_ptr, _length);

    public override MemoryHandle Pin(int elementIndex = 0) => new(_ptr + elementIndex);

    public override void Unpin() { }

    protected override void Dispose(bool disposing) { }
}
