using ioxide.file;

namespace IoxideArena;

/// <summary>
/// Keeps the static tree honest.
///
/// Both static paths are built once at startup and neither notices the disk
/// afterwards: ioxide.file opens a descriptor per asset and reads positionally
/// off it, and <see cref="Precompressed"/> bakes whole responses into memory.
/// That is exactly what makes them fast, and it is also why replacing a file
/// under the mount used to keep serving the bytes the process opened at boot.
///
/// The implementation rules require the opposite: replace a file and the next
/// response has to carry the new bytes. So the tree is stamped and the stamp is
/// checked before a static request is answered.
///
/// The stamp is file count plus the newest write time, not content. It is a
/// stat per file over a directory of twenty, throttled so a burst of requests
/// pays for it once, which is cheap next to a rebuild and far cheaper than
/// reopening per request. Size is deliberately not part of it: the validation
/// replaces a file with one of exactly the same length, so anything keyed on
/// size alone would miss it.
/// </summary>
internal static class StaticRefresh
{
    // Well inside the 2s the rules allow, and long enough that a saturating run
    // stats the tree a few times a second rather than a few hundred thousand.
    private const long IntervalTicks = TimeSpan.TicksPerMillisecond * 250;

    private static string? _root;
    private static StaticAssets? _assets;
    private static Precompressed? _pre;

    private static long _nextCheck;
    private static long _stamp;
    private static int _busy;

    public static void Init(string root, StaticAssets? assets, Precompressed? pre)
    {
        _root = Directory.Exists(root) ? root : null;
        _assets = assets;
        _pre = pre;
        _stamp = Stamp();
        _nextCheck = DateTime.UtcNow.Ticks + IntervalTicks;
    }

    /// <summary>Reload both caches if the tree changed. Cheap and safe to call per request.</summary>
    public static void Poll()
    {
        if (_root is null) return;

        long now = DateTime.UtcNow.Ticks;
        if (now < Volatile.Read(ref _nextCheck)) return;

        // One reactor does the work; the others carry on serving the snapshot
        // they already have rather than queueing behind a directory walk.
        if (Interlocked.Exchange(ref _busy, 1) == 1) return;
        try
        {
            Volatile.Write(ref _nextCheck, now + IntervalTicks);
            long s = Stamp();
            if (s != _stamp)
            {
                _stamp = s;
                _assets?.Reload();
                _pre?.Rebuild();
            }
        }
        finally
        {
            Volatile.Write(ref _busy, 0);
        }
    }

    private static long Stamp()
    {
        if (_root is null) return 0;
        long newest = 0, count = 0;
        try
        {
            foreach (string f in Directory.EnumerateFiles(_root, "*", SearchOption.AllDirectories))
            {
                count++;
                long t = File.GetLastWriteTimeUtc(f).Ticks;
                if (t > newest) newest = t;
            }
        }
        catch (IOException)
        {
            return _stamp;   // mid-replacement; try again on the next tick
        }
        return newest ^ (count * 1_000_003);
    }
}
