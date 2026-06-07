// ReSharper disable always CheckNamespace
// ReSharper disable always SuggestVarOrType_BuiltInTypes
// (var is avoided intentionally in this project so that concrete types are visible at call sites.)
// ReSharper disable always StackAllocInsideLoop
// ReSharper disable always ClassCannotBeInstantiated
#pragma warning disable CA2014

namespace Shrike;

internal interface ISpanWriter<T>
{
    /// <summary>Notifies the <see cref="T:System.Buffers.IBufferWriter`1" /> that <paramref name="count" /> data items were written to the output <see cref="T:System.Span`1" /> or <see cref="T:System.Memory`1" />.</summary>
    /// <param name="count">The number of data items written to the <see cref="T:System.Span`1" />.</param>
    void Advance(int count);
    
    /// <summary>Returns a <see cref="T:System.Span`1" /> to write to that is at least the requested size (specified by <paramref name="sizeHint" />).</summary>
    /// <param name="sizeHint">The minimum length of the returned <see cref="T:System.Span`1" />. If 0, a non-empty buffer is returned.</param>
    /// <returns>A <see cref="T:System.Span`1" /> of at least the size <paramref name="sizeHint" />. If <paramref name="sizeHint" /> is 0, returns a non-empty buffer.</returns>
    Span<T> GetSpan(int sizeHint = 0);
}