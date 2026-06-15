using System.Net;

using genhttp;

using GenHTTP.Engine.Ioxide;

var app = Project.Create();

var host = Host.Create()
               .Handler(app);

host.Bind(IPAddress.Any, 8080);

await host.RunAsync();
