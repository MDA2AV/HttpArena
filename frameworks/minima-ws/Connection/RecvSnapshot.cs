namespace Minima;

public readonly struct RecvSnapshot
{
    public readonly long Tail;
    public readonly bool IsClosed;

    public RecvSnapshot(long tail, bool isClosed)
    {
        Tail = tail;
        IsClosed = isClosed;
    }

    public static RecvSnapshot Closed() => new(0, isClosed: true);
}