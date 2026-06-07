// ReSharper disable always CheckNamespace
// ReSharper disable always SuggestVarOrType_BuiltInTypes
// (var is avoided intentionally in this project so that concrete types are visible at call sites.)
// ReSharper disable always StackAllocInsideLoop
// ReSharper disable always ClassCannotBeInstantiated
#pragma warning disable CA2014

namespace Shrike;

/// <summary>
/// Provides a <see cref="Memory{T}"/> and <see cref="Span{T}"/> abstraction
/// over a block of unmanaged memory, without taking ownership of that memory.
///
/// This class allows interop scenarios where a <see cref="byte*"/> pointer
/// is obtained externally (for example, via <c>malloc</c>, native buffers,
/// or <c>stackalloc</c>) and must be safely exposed as <see cref="Memory{T}"/>
/// to .NET APIs that expect it.
///
/// <para>
/// <b>Important:</b> This class does not allocate or free the unmanaged memory.
/// The caller is fully responsible for ensuring that the pointer remains valid
/// for the lifetime of the <see cref="UnmanagedMemoryManager"/> instance.
/// </para>
/// </summary>
public sealed unsafe class UnmanagedMemoryManager : MemoryManager<byte>
{
    private readonly byte* _ptr;
    private readonly int _length;

    /// <summary>
    /// Initializes a new instance of the <see cref="UnmanagedMemoryManager"/> class
    /// over an existing unmanaged memory block.
    /// </summary>
    /// <param name="ptr">A pointer to the start of the unmanaged memory block.</param>
    /// <param name="length">The length of the memory block, in bytes.</param>
    /// <exception cref="ArgumentOutOfRangeException">Thrown if <paramref name="length"/> is negative.</exception>
    /// <exception cref="ArgumentNullException">Thrown if <paramref name="ptr"/> is <see langword="null"/>.</exception>
    public UnmanagedMemoryManager(byte* ptr, int length)
    {
        if (ptr == null)
            throw new ArgumentNullException(nameof(ptr));

        if (length < 0)
            throw new ArgumentOutOfRangeException(nameof(length));

        _ptr = ptr;
        _length = length;
    }

    /// <summary>
    /// Returns a <see cref="Span{T}"/> representing the unmanaged memory.
    /// </summary>
    /// <returns>
    /// A <see cref="Span{T}"/> starting at the unmanaged memory address
    /// and covering <see cref="_length"/> bytes.
    /// </returns>
    public override Span<byte> GetSpan() => new(_ptr, _length);

    /// <summary>
    /// Pins the unmanaged memory and returns a handle to it.
    /// Since this memory is already unmanaged, pinning is a no-op.
    /// </summary>
    /// <param name="elementIndex">An optional offset, in bytes, from the start of the buffer.</param>
    /// <returns>
    /// A <see cref="MemoryHandle"/> pointing directly to the unmanaged buffer
    /// at <c>_ptr + elementIndex</c>.
    /// </returns>
    public override MemoryHandle Pin(int elementIndex = 0) => new MemoryHandle(_ptr + elementIndex);

    /// <summary>
    /// Unpins the memory. This is a no-op because unmanaged memory cannot be moved by the GC.
    /// </summary>
    public override void Unpin() { }

    /// <summary>
    /// Releases resources used by this <see cref="UnmanagedMemoryManager"/>.
    /// Since this class does not own the unmanaged memory, this method does nothing.
    /// </summary>
    /// <param name="disposing">
    /// <see langword="true"/> if called from <see cref="IDisposable.Dispose"/>; otherwise <see langword="false"/>.
    /// </param>
    protected override void Dispose(bool disposing) { }
}
