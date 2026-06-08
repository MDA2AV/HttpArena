namespace Minima;

/// <summary>
/// All server tunables in one place — replaces the consts that used to be
/// scattered across Program.cs and Reactor.cs. Defaults match the previous
/// hardcoded values; override via object initializer in Main, e.g.:
///   new ServerConfig { Port = 9000, ReactorCount = 8, Incremental = true }.
/// </summary>
public sealed record ServerConfig
{
    // Server-level.
    public ushort Port         { get; init; } = 8080;
    public int    ReactorCount { get; init; } = 12;

    // Handler style: false = raw ReadAsync/TryGetItem loop; true = PipeReader/PipeWriter.
    public bool   UsePipe      { get; init; } = false;

    // Static file served by the handler via Magpie (io_uring file read). If the path
    // doesn't exist a sample file is written there at startup.
    public string FilePath     { get; init; } = "/tmp/minima-magpie-sample.html";

    // io_uring SQ/CQ depth.
    public uint   RingEntries  { get; init; } = 8192;

    // Shared buffer ring (used when Incremental == false).
    public int    RecvBufferSize    { get; init; } = 32 * 1024;
    public int    BufferRingEntries { get; init; } = 4096;

    // Per-connection write slab + connection pool cap.
    public int    WriteSlabSize { get; init; } = 16 * 1024;
    public int    PoolMax       { get; init; } = 1024;

    // Incremental mode (IOU_PBUF_RING_INC) — per-connection rings.
    //   reserved native memory ≈ PoolMax × ConnBufRingEntries × IncRecvBufferSize × ReactorCount.
    public bool   Incremental        { get; init; } = false;
    public int    MaxConnections     { get; init; } = 4096;   // GID cap (one bgid per active connection)
    public int    ConnBufRingEntries { get; init; } = 16;     // buffers per connection ring
    public int    IncRecvBufferSize  { get; init; } = 4096;   // bytes per buffer (filled incrementally)
}
