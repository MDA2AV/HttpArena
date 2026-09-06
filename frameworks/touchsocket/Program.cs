using TouchSocketArena;

using TouchSocket.Core;
using TouchSocket.Http;
using TouchSocket.Sockets;

// ─────────────────────────────────────────────────────────────────────────────────────────────
//  touchsocket - TouchSocket.Http, the framework's HTTP/1.1 server component.
//
//  Requests are answered from an IHttpPlugin, which is how TouchSocket exposes its HTTP pipeline:
//  the plugin sees each request, answers the ones it recognises and passes the rest along. h1
//  cleartext on :8080.
// ─────────────────────────────────────────────────────────────────────────────────────────────

var dataset = new Dataset();

var port = int.TryParse(Environment.GetEnvironmentVariable("PORT"), out var p) ? p : 8080;

var service = new HttpService();

await service.SetupAsync(new TouchSocketConfig()
    .SetListenIPHosts(port)
    .ConfigurePlugins(a => a.Add(new ArenaPlugin(dataset))));

await service.StartAsync();

Console.WriteLine($"[touchsocket] :{port}, dataset={(dataset.IsAvailable ? dataset.Count + " items" : "absent")}");

await Task.Delay(Timeout.Infinite);
