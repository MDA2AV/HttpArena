using GenHTTP.Api.Content;
using GenHTTP.Api.Protocol;

using GenHTTP.Modules.Compression.Algorithms;
using GenHTTP.Modules.Files;
using GenHTTP.Modules.Layouting;
using GenHTTP.Modules.Layouting.Provider;
using GenHTTP.Modules.Websockets;

using genhttp.Handlers;

namespace genhttp;

public static class Project
{

    public static IHandlerBuilder Create()
    {
        var baseline = new BaselineHandler();

        var app = Layout.Create()
                        .Add("pipeline", new FixedHandler("ok"u8.ToArray(), ContentType.TextPlain))
                        .Add("baseline11", baseline)
                        .Add("baseline2", baseline)
                        .Add("echo", new EchoHandler())
                        .Add("json", new JsonHandler())
                        .Add("delay", new DelayHandler())
                        .Add("async-db", new AsyncDatabaseHandler())
                        .AddStaticFiles()
                        .AddWebsocket();

        return app;
    }

    private static LayoutBuilder AddStaticFiles(this LayoutBuilder app)
    {
        if (Directory.Exists("/data/static"))
        {
            var handler = Assets.From("/data/static")
                                .AllowPrecompressed(new BrotliAlgorithm());

            app.Add("static", handler);
        }

        return app;
    }

    private static LayoutBuilder AddWebsocket(this LayoutBuilder app)
    {
        var websocket = Websocket.Imperative()
                                 .DoNotAllocateFrameData()
                                 .Handler(new WebsocketEchoHandler());

        return app.Add("ws", websocket);
    }

}
