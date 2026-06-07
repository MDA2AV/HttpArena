// ReSharper disable always CheckNamespace
// ReSharper disable always SuggestVarOrType_BuiltInTypes
// (var is avoided intentionally in this project so that concrete types are visible at call sites.)
// ReSharper disable always StackAllocInsideLoop
// ReSharper disable always ClassCannotBeInstantiated

#pragma warning disable CA2014

namespace Shrike;

/// <summary>
/// Provides extremely lightweight hashing utilities optimized for short, hot-path inputs
/// (e.g. HTTP routes, header names, or method tokens).
/// </summary>
internal static class HashUtils
{
    /// <summary>
    /// Computes a 32-bit FNV-1a (Fowler–Noll–Vo) hash of the given byte span.
    /// </summary>
    /// <remarks>
    /// FNV-1a is a simple, fast, non-cryptographic hash function designed for small inputs
    /// and stable distribution.  
    /// 
    /// Formula:
    /// <code>
    /// h = 2166136261
    /// for each byte b in data:
    ///     h = (h XOR b) * 16777619
    /// </code>
    ///
    /// Characteristics:
    ///  • 32-bit unsigned integer output  
    ///  • Deterministic and endian-independent  
    ///  • Good avalanche behavior for short ASCII inputs  
    ///  • Not suitable for security-critical use (collision-prone vs. modern hashes)
    /// </remarks>
    /// <param name="data">Input data to hash (typically a small UTF-8 slice).</param>
    /// <returns>32-bit unsigned FNV-1a hash of <paramref name="data"/>.</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    internal static uint Fnv1a32(ReadOnlySpan<byte> data)
    {
        const uint offset = 2166136261u;
        const uint prime = 16777619u;
        uint h = offset;

        for (int i = 0; i < data.Length; i++)
        {
            h ^= data[i];
            h *= prime;
        }

        return h;
    }
    
    /// <summary>
    /// Computes an 8-bit FNV-1a hash of the given byte span.
    /// </summary>
    /// <remarks>
    /// Derived from the 32-bit version but truncated to 8 bits (mod 256).  
    /// This variant is extremely small and fast — ideal for quick indexing or hashing
    /// into small tables, but collisions are frequent due to the 1-byte range.
    ///
    /// Formula:
    /// <code>
    /// h = 0xA3
    /// for each byte b in data:
    ///     h = (h XOR b) * 0x9B
    /// return h
    /// </code>
    ///
    /// Characteristics:
    ///  • Output range: 0–255  
    ///  • Very lightweight; no heap allocations  
    ///  • Not stable for large datasets (collisions expected)
    /// </remarks>
    /// <param name="data">Input data to hash.</param>
    /// <returns>8-bit FNV-1a hash value.</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    internal static byte Fnv1a8(ReadOnlySpan<byte> data)
    {
        const byte offset = 0xA3; // 163 decimal
        const byte prime = 0x9B;  // 155 decimal
        byte h = offset;

        for (int i = 0; i < data.Length; i++)
        {
            h ^= data[i];
            unchecked { h = (byte)(h * prime); }
        }

        return h;
    }
}