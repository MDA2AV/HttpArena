using GenHTTP.Api.Protocol;

using Microsoft.Extensions.ObjectPool;

namespace genhttp.Content;

/// <summary>
/// Response content that is rented from a pool by a handler and handed back
/// once the engine has written it.
/// </summary>
/// <remarks>
/// The engine disposes content after writing it to the connection (and the
/// compression module forwards this to the content it wraps), which is where
/// the instance goes back to the pool. If a response is never written (HEAD
/// request, dropped connection), the instance is simply collected.
/// </remarks>
public abstract class PooledContent<T> : IResponseContent, IDisposable where T : PooledContent<T>, new()
{
    private static readonly ObjectPool<T> Pool = new DefaultObjectPool<T>(new DefaultPooledObjectPolicy<T>(), 4096);

    private bool _rented;

    public abstract ulong? Length { get; }

    public abstract ContentType? Type { get; }

    public ReadOnlyMemory<byte>? Encoding => null;

    public static T Rent()
    {
        var instance = Pool.Get();
        instance._rented = true;
        return instance;
    }

    public ValueTask<ulong?> CalculateChecksumAsync() => new((ulong?)null);

    public abstract ValueTask WriteAsync(IResponseSink sink);

    protected virtual void Clear() { }

    public void Dispose()
    {
        if (_rented)
        {
            _rented = false;

            Clear();

            Pool.Return((T)this);
        }
    }

}
