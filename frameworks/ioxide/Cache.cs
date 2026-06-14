using ioxide;
using ioxide.redis;
using StackExchange.Redis;
using Microsoft.Extensions.Caching.Memory;

namespace IoxideArena;

/// <summary>The crud cache, so the backend can be swapped for benchmarking (CRUD_CACHE env var).</summary>
internal interface ICrudCache
{
    ValueTask<string?> GetAsync(string key);
    ValueTask SetExAsync(string key, string value, int seconds);
    ValueTask DelAsync(string key);
}

/// <summary>ioxide.redis: per-reactor pooled connections, pipelined, on the ring (inline resume).</summary>
internal sealed class IoxideRedisCache(RedisPool pool) : ICrudCache
{
    public ValueTask<string?> GetAsync(string key) => pool.GetAsync(key);
    public ValueTask SetExAsync(string key, string value, int seconds) => pool.SetExAsync(key, value, seconds);
    public async ValueTask DelAsync(string key) => await pool.DelAsync(key);
}

/// <summary>
/// In-process IMemoryCache, shared across reactors. Synchronous - GET/SET/REMOVE run inline on
/// the reactor (no network, no thread pool), so a cache-hit never leaves the ring. The cache is
/// shared so a PUT on any reactor is seen by every reactor's next read.
/// </summary>
internal sealed class InProcCache(IMemoryCache cache) : ICrudCache
{
    // Single-item entries expire 200 ms after write, matching genhttp-11's IMemoryCache so the
    // crud comparison is apples-to-apples. (The seconds arg is honored only by the Redis backends.)
    private static readonly MemoryCacheEntryOptions Options =
        new() { AbsoluteExpirationRelativeToNow = TimeSpan.FromMilliseconds(200) };

    public ValueTask<string?> GetAsync(string key)
        => new(cache.TryGetValue(key, out string? value) ? value : null);

    public ValueTask SetExAsync(string key, string value, int seconds)
    {
        cache.Set(key, value, Options);
        return ValueTask.CompletedTask;
    }

    public ValueTask DelAsync(string key)
    {
        cache.Remove(key);
        return ValueTask.CompletedTask;
    }
}

/// <summary>StackExchange.Redis: one shared multiplexer, off-ring (thread-pool completions).</summary>
internal sealed class StackExchangeCache(IDatabase db) : ICrudCache
{
    public async ValueTask<string?> GetAsync(string key) => await db.StringGetAsync(key);
    public ValueTask SetExAsync(string key, string value, int seconds)
        => new(db.StringSetAsync(key, value, TimeSpan.FromSeconds(seconds)));
    public ValueTask DelAsync(string key) => new(db.KeyDeleteAsync(key));
}
