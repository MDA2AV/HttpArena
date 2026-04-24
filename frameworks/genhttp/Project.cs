using GenHTTP.Api.Content;
using GenHTTP.Modules.IO;
using GenHTTP.Modules.Layouting;
using GenHTTP.Modules.Layouting.Provider;
using GenHTTP.Modules.Webservices;
using GenHTTP.Modules.Websockets;

using genhttp.Tests;

namespace genhttp;

public static class Project
{
    public static IHandlerBuilder Create()
    {
        var crud = Layout.Create()
                         .AddService<Crud>("items");

        var app = Layout.Create()
                        .Add("pipeline", Content.From(Resource.FromString("ok")))
                        .AddService<Baseline>("baseline11")
                        .AddService<Baseline>("baseline2")
                        .AddService<Upload>("upload")
                        .AddService<Json>("json")
                        .AddService<AsyncDatabase>("async-db")
                        .Add("crud", crud)
                        .AddStaticFiles()
                        .AddWebsocket();

        return app;
    }

    private static LayoutBuilder AddStaticFiles(this LayoutBuilder app)
    {
        if (Directory.Exists("/data/static"))
        {
            app.Add("static", Resources.From(ResourceTree.FromDirectory("/data/static")));
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
