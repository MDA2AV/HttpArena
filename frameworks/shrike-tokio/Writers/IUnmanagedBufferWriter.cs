// ReSharper disable always CheckNamespace
// ReSharper disable always SuggestVarOrType_BuiltInTypes
// (var is avoided intentionally in this project so that concrete types are visible at call sites.)
// ReSharper disable always StackAllocInsideLoop
// ReSharper disable always ClassCannotBeInstantiated
#pragma warning disable CA2014

namespace Shrike;

/// <summary>
/// Minimal contract for writing to a caller-provided unmanaged, contiguous buffer.
/// Intended for high-performance I/O/serialization without GC pinning.
/// </summary>
/// <typeparam name="T">Unmanaged element type (e.g., byte).</typeparam>
internal unsafe interface IUnmanagedBufferWriter<T> where T : unmanaged
{
    /// <summary>
    /// Advance the logical write cursor by <paramref name="count"/> elements
    /// after data was written directly into the buffer.
    /// </summary>
    void Advance(int count);

    /// <summary>
    /// Base pointer to the buffer. Valid only while the writer is alive.
    /// Callers that write via this pointer must also call <see cref="Advance"/>.
    /// </summary>
    T* GetPointer();

    /// <summary>
    /// Copy <paramref name="source"/> into the buffer and advance the cursor.
    /// Throw if it would exceed capacity.
    /// </summary>
    void Write(ReadOnlySpan<byte> source);

    /// <summary>
    /// Like <see cref="Write(ReadOnlySpan{byte})"/>, but allows an implementation
    /// to use an unsafe/fast path (e.g., MemoryCopy). Must still enforce bounds.
    /// </summary>
    void WriteUnmanaged(ReadOnlySpan<byte> source);
}
