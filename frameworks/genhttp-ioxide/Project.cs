using GenHTTP.Api.Content;

using GenHTTP.Modules.IO;
using GenHTTP.Modules.Compression;
using GenHTTP.Modules.Compression.Algorithms;
using GenHTTP.Modules.Files;
using GenHTTP.Modules.Layouting;
using GenHTTP.Modules.Layouting.Provider;
using GenHTTP.Modules.Webservices;
using GenHTTP.Modules.Websockets;

using genhttp.Infrastructure;
using genhttp.Tests;

namespace genhttp;

public static class Project
{
    public static IHandlerBuilder Create()
    {
        var app = Layout.Create()
                        .Add("pipeline", Content.From(Resource.FromString("ok")))
                        .AddService<Baseline>("baseline11")
                        .AddService<Baseline>("baseline2")
                        .AddService<Echo>("echo")
                        .AddService<Json>("json")
                        // The async profile: /delay/{ms} holds the request without holding a thread.
                        .AddService<Delay>("delay");

        // async-db and crud require a configured Postgres (DATABASE_URL).
        if (Postgres.Enabled)
        {
            var crud = Layout.Create()
                             .AddService<Crud>("items");

            app = app.AddService<AsyncDatabase>("async-db")
                     .Add("crud", crud);
        }

        return app
            .AddStaticFiles()
            .AddWebsocket();
    }

    private static LayoutBuilder AddStaticFiles(this LayoutBuilder app)
    {
        var staticDir = Environment.GetEnvironmentVariable("IOXIDE_STATIC") ?? "/data/static";

        if (Directory.Exists(staticDir))
        {
            // GenHTTP's own file handler rather than IoxideFiles. IoxideFiles serves correctly over
            // HTTP/1.1 and HTTP/3 but returns an empty body over HTTP/2, and it does not follow a
            // file replaced underneath it - both of which the static profiles check. Assets is
            // ordinary response content, so every protocol handles it the same way. The write slab
            // is sized above the largest asset in Program.cs, which is what made this viable.
            app.Add("static", Assets.From(ResourceTree.FromDirectory(staticDir))
                              .AllowPrecompressed(new BrotliAlgorithm()));
        }

        return app;
    }
    
    private static LayoutBuilder AddWebsocket(this LayoutBuilder app)
    {
        var websocket = Websocket.Imperative()
            .DoNotAllocateFrameData()
            .Handler(new EchoHandler());

        return app.Add("ws", websocket);
    }

}
