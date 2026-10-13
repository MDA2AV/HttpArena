// The container logs benchmark.sh keeps for every run, served where the site links them:
// logs/{profile}/{conns}/{framework dir}.log.
//
// They arrive gzipped and stay gzipped, in the workspace under logs/{sha256 of the log}.gz -
// so the hundreds of empty logs, and any two runs that logged the same, are kept once - and
// the logs table says which content is kept under which path. A log is sent decompressed:
// it is text, and the server compresses what it sends anyway.
//
// Keeping a file and changing what points at it happen under one lock, so that two uploads
// can never leave a path pointing at content a third one just removed.

using System.IO.Compression;
using System.Security.Cryptography;

/// <summary>What the log store may do with the workspace.</summary>
public record LogFiles(Func<string, byte[]> Read, Action<string, byte[]> Write, Action<string> Delete, Func<string, bool> Exists);

public record LogInfo(string Path, string Sha256, long Bytes, long Stored);

/// <summary>Every log kept, by path, with the SHA-256 of its content - what an upload compares against.</summary>
public record LogManifest(int Count, long Bytes, long Stored, Dictionary<string, string> Logs);

public sealed class LogStore(ArenaStore store, LogFiles files)
{
    // benchmark.sh cuts new logs at 8 MB; one from before it did is 31 MB
    private const long MaxLog = 64L * 1024 * 1024;

    private const int MaxUpload = 32 * 1024 * 1024;

    private static readonly ContentType Text = new("text/plain; charset=utf-8");

    private readonly Lock _gate = new();

    public LogManifest Manifest()
    {
        var logs = store.LogHashes();

        var (bytes, stored) = store.LogTotals();

        return new LogManifest(logs.Count, bytes, stored, logs);
    }

    public async Task<LogInfo> PutAsync(string profile, string conns, string name, Stream body)
    {
        var path = PathOf(profile, conns, name)
                ?? throw new ProviderException(ResponseStatus.BadRequest, "A log is put at {profile}/{conns}/{framework}.log.");

        // the body comes over the network; the rest is memory and the workspace
        var gzip = await ReadAsync(body);

        var (sha256, bytes) = Inspect(gzip);

        lock (_gate)
        {
            if (!files.Exists(Stored(sha256)))
            {
                files.Write(Stored(sha256), gzip);
            }

            var previous = store.SaveLog(path, sha256, bytes, gzip.Length);

            if (previous != null && previous != sha256 && !store.LogContentInUse(previous))
            {
                files.Delete(Stored(previous));
            }
        }

        return new LogInfo(path, sha256, bytes, gzip.Length);
    }

    public void Remove(string profile, string conns, string name)
    {
        var path = PathOf(profile, conns, name) ?? throw Missing();

        lock (_gate)
        {
            var previous = store.RemoveLog(path) ?? throw Missing();

            if (!store.LogContentInUse(previous))
            {
                files.Delete(Stored(previous));
            }
        }
    }

    /// <summary>GET {profile}/{conns}/{name}: the log, decompressed on its way out.</summary>
    public IHandlerBuilder Serve()
        => Inline.Create()
                 .Get(":profile/:conns/:name", (IRequest request, string profile, string conns, string name) => Respond(request, profile, conns, name));

    private IResponseBuilder Respond(IRequest request, string profile, string conns, string name)
    {
        var entry = PathOf(profile, conns, name) is { } path ? store.FindLog(path) : null;

        if (entry == null)
        {
            throw Missing();
        }

        var content = new GZipStream(new MemoryStream(files.Read(Stored(entry.Sha256))), CompressionMode.Decompress);

        // the content's hash is its checksum, so a browser that has it is told it is unchanged
        var checksum = Convert.ToUInt64(entry.Sha256[..16], 16);

        return request.Respond()
                      .Content(content, Text, (ulong)entry.Bytes, checksumProvider: () => ValueTask.FromResult<ulong?>(checksum))
                      .Header("Cache-Control", "public, max-age=300");
    }

    private static string PathOf(string profile, string conns, string name)
        => Names.IsProfile(profile) && Names.IsConnections(conns) && Names.IsLogName(name) ? $"{profile}/{conns}/{name}" : null;

    private static string Stored(string sha256) => $"logs/{sha256}.gz";

    /// <summary>Checks that the body is gzip, and hashes and measures what it holds.</summary>
    private static (string Sha256, long Bytes) Inspect(byte[] gzip)
    {
        try
        {
            using var log = new GZipStream(new MemoryStream(gzip), CompressionMode.Decompress);

            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);

            var buffer = new byte[64 * 1024];

            long bytes = 0;

            int read;

            while ((read = log.Read(buffer, 0, buffer.Length)) > 0)
            {
                bytes += read;

                if (bytes > MaxLog)
                {
                    throw new ProviderException(ResponseStatus.RequestEntityTooLarge, $"A log can be {MaxLog / 1024 / 1024} MB at most.");
                }

                hash.AppendData(buffer, 0, read);
            }

            return (Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant(), bytes);
        }
        catch (InvalidDataException)
        {
            throw new ProviderException(ResponseStatus.BadRequest, "A log is sent gzipped, and this body is not gzip.");
        }
    }

    /// <summary>Reads the body, but never more than the limit.</summary>
    private static async Task<byte[]> ReadAsync(Stream body)
    {
        using var buffer = new MemoryStream();

        var chunk = new byte[64 * 1024];

        int read;

        while ((read = await body.ReadAsync(chunk)) > 0)
        {
            if (buffer.Length + read > MaxUpload)
            {
                throw new ProviderException(ResponseStatus.RequestEntityTooLarge, $"A gzipped log can be {MaxUpload / 1024 / 1024} MB at most.");
            }

            buffer.Write(chunk, 0, read);
        }

        return buffer.ToArray();
    }

    private static ProviderException Missing() => new(ResponseStatus.NotFound, "There is no such log.");
}
