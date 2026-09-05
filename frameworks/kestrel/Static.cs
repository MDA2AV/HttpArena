using Microsoft.AspNetCore.Http;

namespace KestrelArena;

/// <summary>
/// Static files served straight off the mounted directory.
/// </summary>
/// <remarks>
/// Read per request through the filesystem rather than from a copy taken at image build, so a file
/// replaced under the mount is reflected in the next response - which the static profiles check by
/// replacing one and asking again.
///
/// Compression is a precompressed sibling (.br, then .gz) chosen from Accept-Encoding, not a
/// compressor in the response path: the corpus ships the twins, so serving them is both what a
/// production deployment does and cheaper than compressing the same bytes on every request.
/// </remarks>
internal static class StaticFiles
{
    private static readonly string Root =
        Environment.GetEnvironmentVariable("STATIC_ROOT") ?? "/data/static";

    public static bool Available { get; } = Directory.Exists(Root);

    public static async Task<bool> TryServeAsync(HttpContext ctx, string path)
    {
        // path is everything after "/static/". Reject anything that could escape the root.
        if (path.Length == 0 || path.Contains("..", StringComparison.Ordinal) || path.Contains('\\'))
        {
            return false;
        }

        var full = Path.Combine(Root, path);

        if (!File.Exists(full))
        {
            return false;
        }

        var response = ctx.Response;
        response.ContentType = ContentTypeFor(path);

        // Vary regardless of what is served: the answer depends on Accept-Encoding, so a cache
        // that ignored it would hand a brotli body to a client that cannot read one.
        response.Headers.Vary = "Accept-Encoding";

        var encodings = ctx.Request.Headers.AcceptEncoding;

        if (Sibling(full, ".br", encodings, "br") is { } brotli)
        {
            response.Headers.ContentEncoding = "br";
            await response.SendFileAsync(brotli);
            return true;
        }

        if (Sibling(full, ".gz", encodings, "gzip") is { } gzip)
        {
            response.Headers.ContentEncoding = "gzip";
            await response.SendFileAsync(gzip);
            return true;
        }

        await response.SendFileAsync(full);
        return true;
    }

    private static string? Sibling(string full, string suffix, Microsoft.Extensions.Primitives.StringValues accepted, string token)
    {
        if (!Accepts(accepted, token))
        {
            return null;
        }

        var candidate = full + suffix;

        return File.Exists(candidate) ? candidate : null;
    }

    private static bool Accepts(Microsoft.Extensions.Primitives.StringValues accepted, string token)
    {
        foreach (var value in accepted)
        {
            if (value is not null && value.Contains(token, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static string ContentTypeFor(string path)
    {
        var dot = path.LastIndexOf('.');

        if (dot < 0)
        {
            return "application/octet-stream";
        }

        return path.AsSpan(dot) switch
        {
            ".html" or ".htm" => "text/html",
            ".css" => "text/css",
            ".js" or ".mjs" => "application/javascript",
            ".json" => "application/json",
            ".svg" => "image/svg+xml",
            ".png" => "image/png",
            ".jpg" or ".jpeg" => "image/jpeg",
            ".webp" => "image/webp",
            ".gif" => "image/gif",
            ".ico" => "image/x-icon",
            ".woff2" => "font/woff2",
            ".woff" => "font/woff",
            ".txt" => "text/plain",
            ".xml" => "application/xml",
            ".wasm" => "application/wasm",
            ".map" => "application/json",
            _ => "application/octet-stream"
        };
    }
}
