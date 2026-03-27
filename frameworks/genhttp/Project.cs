using GenHTTP.Api.Content;
using GenHTTP.Api.Protocol;

using GenHTTP.Modules.Compression;
using GenHTTP.Modules.IO;
using GenHTTP.Modules.Layouting;
using GenHTTP.Modules.Layouting.Provider;
using GenHTTP.Modules.Reflection;
using GenHTTP.Modules.Webservices;

using genhttp.Tests;

namespace genhttp;

public static class Project
{
    public static IHandlerBuilder Create()
    {
        var app = Layout.Create()
            .AddPipeline()
            .AddBaseline()
            .AddUpload()
            .AddJson()
            .AddDatabase()
            .AddCompression()
            .AddStaticFiles()
            .Add(Concern.From(AddHeader));

        return app;
    }

    private static LayoutBuilder AddStaticFiles(this LayoutBuilder app)
    {
        var staticDir = "/data/static";

        if (Directory.Exists(staticDir))
        {
            var files = ResourceTree.FromDirectory("/data/static");

            app.Add("static", Resources.From(files));
        }

        return app;
    }

    private static LayoutBuilder AddPipeline(this LayoutBuilder app)
    {
        return app.Add("pipeline", Content.From(Resource.FromString("ok")));
    }
    
    private static LayoutBuilder AddBaseline(this LayoutBuilder app)
    {
        return app.AddService<Baseline>("baseline11", mode: ExecutionMode.Auto)
                  .AddService<Baseline>("baseline2", mode: ExecutionMode.Auto);
    }

    private static LayoutBuilder AddUpload(this LayoutBuilder app)
    {
        return app.AddService<Upload>("upload", mode: ExecutionMode.Auto);
    }
    
    private static LayoutBuilder AddJson(this LayoutBuilder app)
    {
        return app.AddService<Json>("json", mode: ExecutionMode.Auto);
    }
    
    private static LayoutBuilder AddDatabase(this LayoutBuilder app)
    {
        return app.AddService<Database>("db", mode: ExecutionMode.Auto)
                  .AddService<AsyncDatabase>("async-db", mode: ExecutionMode.Auto);
    }
    
    private static LayoutBuilder AddCompression(this LayoutBuilder app)
    {
        var service = ServiceResource.From<Compression>().ExecutionMode(ExecutionMode.Auto);

        service.Add(CompressedContent.Default());

        return app.Add("compression", service);
    }

    private static async ValueTask<IResponse?> AddHeader(IRequest request, IHandler content)
    {
        var response = await content.HandleAsync(request);

        response?.Headers.Add("Server", "genhttp");

        return response;
    }
    
}