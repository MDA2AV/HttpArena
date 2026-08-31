using GenHTTP.Api.Content;

using GenHTTP.Modules.IO;
using GenHTTP.Modules.IoxideFiles;
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
                        .AddService<Json>("json");

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
            // Serve static files through ioxide.file (baked native responses + statx revalidation)
            // rather than GenHTTP's Modules.Files, whose FileResource overflows the ioxide write slab.
            app.Add("static", IoxideFiles.From(staticDir));
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
