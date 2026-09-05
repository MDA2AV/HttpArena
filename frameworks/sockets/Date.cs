using System.Text;

namespace SocketsArena;

/// <summary>
/// The Date header, rendered once a second rather than once a request.
/// </summary>
/// <remarks>
/// RFC 9110 says an origin server should send it, and its resolution is one second - so formatting
/// it per request would be the same bytes, several hundred thousand times over, plus a DateTime
/// format each time. A background timer rewrites the line and connections copy whatever is current.
/// </remarks>
internal static class DateHeader
{
    private static byte[] _line = Render();

    static DateHeader()
    {
        var timer = new Timer(static _ => _line = Render(), null, 1000, 1000);
        GC.KeepAlive(timer);
    }

    /// <summary>The full header line, "Date: ...\r\n", ready to copy into a response.</summary>
    public static ReadOnlySpan<byte> Line => _line;

    private static byte[] Render()
        => Encoding.ASCII.GetBytes("Date: " + DateTime.UtcNow.ToString("R") + "\r\n");
}
