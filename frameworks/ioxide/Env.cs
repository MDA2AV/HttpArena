namespace IoxideArena;

/// <summary>
/// Typed reads for the IOXIDE_* environment knobs, so the "parse it or keep what we had" shape is
/// written once instead of at every call site. Modelled on the runtime's own Playground/Shared/Env.
///
/// Every read takes the fallback as an argument rather than owning a default of its own. That is
/// the point: <see cref="Config"/> passes the library's own default in, so an unset variable falls
/// back to what ioxide itself would have chosen instead of to a number copied into this entry that
/// then silently rots when the library moves.
/// </summary>
internal static class Env
{
    public static string Str(string name, string fallback)
        => Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : fallback;

    public static string? StrOrNull(string name)
        => Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : null;

    public static int Int(string name, int fallback)
        => int.TryParse(Environment.GetEnvironmentVariable(name), out int v) ? v : fallback;

    public static long Long(string name, long fallback)
        => long.TryParse(Environment.GetEnvironmentVariable(name), out long v) ? v : fallback;

    public static uint UInt(string name, uint fallback)
        => uint.TryParse(Environment.GetEnvironmentVariable(name), out uint v) ? v : fallback;

    public static ushort Port(string name, ushort fallback)
        => ushort.TryParse(Environment.GetEnvironmentVariable(name), out ushort v) ? v : fallback;

    /// <summary>
    /// Tri-state, deliberately: "1" and "0" are the only values that mean anything, and anything
    /// else - unset included - keeps the fallback. A plain "set means true" flag could only ever
    /// turn a knob ON, which is useless for the ones this entry ships enabled (kTLS, GRO).
    /// </summary>
    public static bool Bool(string name, bool fallback)
        => Environment.GetEnvironmentVariable(name) switch
        {
            "1" => true,
            "0" => false,
            _   => fallback,
        };

    /// <summary>Enum by name, case-insensitively: IOXIDE_QUIC_ROUTING=kernelfilter.</summary>
    public static T Enum<T>(string name, T fallback) where T : struct
        => System.Enum.TryParse(Environment.GetEnvironmentVariable(name), ignoreCase: true, out T v) ? v : fallback;
}
