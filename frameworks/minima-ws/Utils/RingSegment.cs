using System.Buffers;

namespace Minima.Utils;

/// <summary>
/// One segment of a multi-buffer ReadOnlySequence&lt;byte&gt; built by the
/// ConnectionPipeReader when a single read spans more than one recv buffer.
/// BufferId is carried for debugging; buffer return is driven off the held
/// item list, not the segments.
/// </summary>
public sealed class RingSegment : ReadOnlySequenceSegment<byte>
{
    public ushort BufferId { get; }

    public RingSegment(ReadOnlyMemory<byte> memory, ushort bufferId)
    {
        Memory = memory;
        BufferId = bufferId;
    }

    public RingSegment Append(ReadOnlyMemory<byte> memory, ushort bufferId)
    {
        var next = new RingSegment(memory, bufferId)
        {
            RunningIndex = RunningIndex + Memory.Length
        };

        Next = next;
        return next;
    }
}
