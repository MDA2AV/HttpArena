using GenHTTP.Api.Content;
using GenHTTP.Api.Protocol;

using GenHTTP.Modules.IO;
using GenHTTP.Modules.Layouting;
using GenHTTP.Modules.Layouting.Provider;
using GenHTTP.Modules.Reflection;
using GenHTTP.Modules.Webservices;
using GenHTTP.Modules.Websockets;
using GenHTTP.Modules.Functional;

using genhttp.Tests;

namespace genhttp;

public static class Project
{
    public static IHandlerBuilder Create()
    {
        var app = Layout.Create()
                        .Add("pipeline", Content.From(Resource.FromString("ok")))
                        .AddService<Baseline>("baseline11", mode: ExecutionMode.Auto)
                        .AddService<Baseline>("baseline2", mode: ExecutionMode.Auto)
                        .AddService<Upload>("upload", mode: ExecutionMode.Auto)
                        .AddService<Json>("json", mode: ExecutionMode.Auto)
                        .AddService<Database>("db", mode: ExecutionMode.Auto)
                        .AddService<AsyncDatabase>("async-db", mode: ExecutionMode.Auto)
                        .AddStaticFiles()
                        .AddWebsocket()
                        .Add(Concern.From(AddHeader));

        return app;
    }

    private static LayoutBuilder AddStaticFiles(this LayoutBuilder app)
    {
        if (Directory.Exists("/data/static"))
        {
            app.Add("static", ResourceTree.FromDirectory("/data/static"));
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

    private static async ValueTask<IResponse?> AddHeader(IRequest request, IHandler content)
    {
        var response = await content.HandleAsync(request);

        response?.Headers.Add("Server", "genhttp");

        return response;
    }

}
