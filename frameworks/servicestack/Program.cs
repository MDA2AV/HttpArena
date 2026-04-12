using ServiceStack;
using ServiceStack.Benchmarks;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls("http://*:8080");
builder.Services.AddResponseCompression();
builder.Logging.ClearProviders();

var app = builder.Build();

app.UseResponseCompression();

if (Directory.Exists("/data/static"))
{
    var mimeTypes = new Dictionary<string, string>
    {
        [".css"] = "text/css", [".js"] = "application/javascript", [".html"] = "text/html",
        [".woff2"] = "font/woff2", [".svg"] = "image/svg+xml", [".webp"] = "image/webp", [".json"] = "application/json",
    };
    var staticFiles = new Dictionary<string, (byte[] data, byte[]? br, byte[]? gz, string contentType)>();
    foreach (var file in Directory.GetFiles("/data/static"))
    {
        var name = Path.GetFileName(file);
        if (name.EndsWith(".br") || name.EndsWith(".gz")) continue;
        var ext = Path.GetExtension(name);
        var ct = mimeTypes.GetValueOrDefault(ext, "application/octet-stream");
        var brPath = file + ".br";
        var gzPath = file + ".gz";
        staticFiles[name] = (
            File.ReadAllBytes(file),
            File.Exists(brPath) ? File.ReadAllBytes(brPath) : null,
            File.Exists(gzPath) ? File.ReadAllBytes(gzPath) : null,
            ct
        );
    }
    app.MapGet("/static/{filename}", (string filename, HttpContext ctx) =>
    {
        if (!staticFiles.TryGetValue(filename, out var sf))
            return Results.NotFound();
        var ae = ctx.Request.Headers.AcceptEncoding.ToString();
        if (sf.br != null && ae.Contains("br"))
        {
            ctx.Response.Headers.ContentEncoding = "br";
            return Results.Bytes(sf.br, sf.contentType);
        }
        if (sf.gz != null && ae.Contains("gzip"))
        {
            ctx.Response.Headers.ContentEncoding = "gzip";
            return Results.Bytes(sf.gz, sf.contentType);
        }
        return Results.Bytes(sf.data, sf.contentType);
    });
}

app.UseServiceStack(new AppHost(), options => {
    options.MapEndpoints();
});

await app.RunAsync();