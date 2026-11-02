using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace genhttp.Infrastructure;

// Temporary: finds out why kernel TLS fails on the CI runners. Prints the kernel and its ULPs,
// repeats ioxide's kTLS calls on a loopback socket, and reports every distinct exception -
// the engine swallows handshake failures, so they would not show up anywhere else.
internal static unsafe partial class KtlsDiagnostics
{
    private const int SOL_TCP = 6;
    private const int TCP_ULP = 31;
    private const int SOL_TLS = 282;
    private const int TLS_TX = 1;

    [LibraryImport("libc", SetLastError = true)]
    private static partial int setsockopt(int fd, int level, int optname, void* optval, uint optlen);

    [ThreadStatic]
    private static bool _reporting;

    internal static void Run()
    {
        Print("kernel", Read("/proc/sys/kernel/osrelease"));
        Print("version", Read("/proc/version"));
        Print("tcp_available_ulp", Read("/proc/sys/net/ipv4/tcp_available_ulp"));
        Print("tls in /proc/modules", ReadTlsModule());

        try
        {
            Probe();
        }
        catch (Exception e)
        {
            Print("probe", $"threw {e}");
        }

        WatchExceptions();
    }

    // The same two setsockopt calls ioxide makes after a handshake, then one send through the ULP.
    private static void Probe()
    {
        using var listener = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        listener.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        listener.Listen(1);

        using var client = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        client.Connect(listener.LocalEndPoint!);

        using var server = listener.Accept();
        var fd = (int)server.Handle;

        ReadOnlySpan<byte> ulp = "tls"u8;
        int rc;
        fixed (byte* p = ulp)
        {
            rc = setsockopt(fd, SOL_TCP, TCP_ULP, p, 3);
        }
        Print("probe TCP_ULP \"tls\"", Result(rc));
        if (rc != 0)
        {
            return;
        }

        // tls12_crypto_info_aes_gcm_128: version, cipher, iv[8], key[16], salt[4], rec_seq[8].
        var info = stackalloc byte[40];
        new Span<byte>(info, 40).Fill(1);
        *(ushort*)info = 0x0304;           // TLS 1.3
        *(ushort*)(info + 2) = 51;         // AES-GCM-128
        new Span<byte>(info + 32, 8).Clear();

        rc = setsockopt(fd, SOL_TLS, TLS_TX, info, 40);
        Print("probe TLS_TX", Result(rc));
        if (rc != 0)
        {
            return;
        }

        var sent = server.Send("hello"u8);
        client.ReceiveTimeout = 2000;
        var buffer = new byte[256];
        var received = client.Receive(buffer);
        Print("probe send", $"sent {sent}, peer received {received} bytes (a 5-byte TLS 1.3 record is 27)");
    }

    private static void WatchExceptions()
    {
        var seen = new ConcurrentDictionary<string, byte>();

        AppDomain.CurrentDomain.FirstChanceException += (_, e) =>
        {
            if (_reporting || seen.Count >= 40)
            {
                return;
            }

            _reporting = true;
            try
            {
                var ex = e.Exception;
                var key = $"{ex.GetType().FullName}: {ex.Message}";
                if (seen.TryAdd(key, 0))
                {
                    var origin = ex.StackTrace?.Split('\n').FirstOrDefault()?.Trim();
                    Console.Error.WriteLine($"[ktls-diag] exception {key} {origin}");
                }
            }
            catch
            {
                // diagnostics only
            }
            finally
            {
                _reporting = false;
            }
        };
    }

    private static string Result(int rc)
    {
        if (rc == 0)
        {
            return "ok";
        }

        var errno = Marshal.GetLastPInvokeError();
        return $"failed, errno {errno} ({Marshal.GetPInvokeErrorMessage(errno)})";
    }

    private static string Read(string path)
    {
        try
        {
            return File.ReadAllText(path).Trim();
        }
        catch (Exception e)
        {
            return $"<{e.GetType().Name}: {e.Message}>";
        }
    }

    private static string ReadTlsModule()
    {
        try
        {
            var line = File.ReadLines("/proc/modules").FirstOrDefault(l => l.StartsWith("tls "));
            return line ?? "<not listed - built in, or not loaded>";
        }
        catch (Exception e)
        {
            return $"<{e.GetType().Name}: {e.Message}>";
        }
    }

    private static void Print(string what, string value) => Console.Error.WriteLine($"[ktls-diag] {what}: {value}");
}
