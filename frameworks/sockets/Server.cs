using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace SocketsArena;

/// <summary>
/// The listener side: one socket per core, each with its own accept loop on its own thread.
/// </summary>
/// <remarks>
/// A single listening socket makes the accept queue a shared point every core contends on, and the
/// thread that accepts is rarely the one that ends up serving. SO_REUSEPORT lets each thread open
/// its own listener on the same port and have the kernel hash incoming connections across them, so
/// a connection is accepted, read and answered on one thread with no handoff between them. It is
/// the same shape the io_uring entries get from their per-reactor rings.
/// </remarks>
internal static class Server
{
    private const int SOL_SOCKET = 1;
    private const int SO_REUSEPORT = 15;   // Linux

    public static void Start(int port, int listeners, Dataset dataset, X509Certificate2? certificate = null)
    {
        for (var i = 0; i < listeners; i++)
        {
            var index = i;

            new Thread(() => AcceptLoop(port, dataset, null))
            {
                IsBackground = true,
                Name = $"sockets-{index}"
            }.Start();
        }
    }

    public static void StartSecure(int port, int listeners, Dataset dataset, X509Certificate2 certificate)
    {
        for (var i = 0; i < listeners; i++)
        {
            var index = i;

            new Thread(() => AcceptLoop(port, dataset, certificate))
            {
                IsBackground = true,
                Name = $"sockets-tls-{index}"
            }.Start();
        }
    }

    private static async Task ServeSecureAsync(Socket accepted, Dataset dataset, X509Certificate2 certificate)
    {
        var tls = new SslStream(new NetworkStream(accepted, ownsSocket: false), leaveInnerStreamOpen: false);

        try
        {
            await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificate = certificate,
                ApplicationProtocols = [SslApplicationProtocol.Http11],
                ClientCertificateRequired = false
            });
        }
        catch
        {
            await tls.DisposeAsync();
            accepted.Dispose();
            return;
        }

        await new Connection(accepted, dataset, tls).RunAsync();
    }

    private static void AcceptLoop(int port, Dataset dataset, X509Certificate2? certificate)
    {
        var listener = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);

        // Before Bind, or the kernel refuses the second listener on the port.
        listener.SetRawSocketOption(SOL_SOCKET, SO_REUSEPORT, BitConverter.GetBytes(1));

        listener.Bind(new IPEndPoint(IPAddress.Any, port));
        listener.Listen(1024);

        while (true)
        {
            Socket accepted;

            try
            {
                accepted = listener.Accept();
            }
            catch (SocketException)
            {
                continue;
            }

            accepted.NoDelay = true;

            // Served away from the accept loop, so a slow client - or a TLS handshake, which is
            // several round trips - never holds up the next accept.
            _ = certificate is null
                ? Task.Run(() => new Connection(accepted, dataset).RunAsync())
                : Task.Run(() => ServeSecureAsync(accepted, dataset, certificate));
        }
    }
}
