using System.Security.Cryptography.X509Certificates;

using HttpArena.Data;

using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.FileProviders;

var builder = WebApplication.CreateBuilder(args);

// Logging is the only setting this entry changes from the defaults.
builder.Logging.ClearProviders();

var certificate = LoadCertificate(builder.Configuration);

builder.WebHost.ConfigureKestrel(kestrel =>
{
    kestrel.ListenAnyIP(8080, listen => listen.Protocols = HttpProtocols.Http1);

    // Cleartext HTTP/2 with prior knowledge.
    kestrel.ListenAnyIP(8082, listen => listen.Protocols = HttpProtocols.Http2);

    if (certificate is not null)
    {
        kestrel.ListenAnyIP(8081, listen =>
        {
            listen.Protocols = HttpProtocols.Http1;
            listen.UseHttps(certificate);
        });

        kestrel.ListenAnyIP(8443, listen =>
        {
            listen.Protocols = HttpProtocols.Http1AndHttp2AndHttp3;
            listen.UseHttps(certificate);
        });
    }
});

builder.Services.AddResponseCompression();

builder.Services.AddSingleton<DatasetService>();

// The database is only provided for the profiles that use it; without it the
// database endpoints answer 503.
if (builder.Configuration["DATABASE_URL"] is { Length: > 0 } databaseUrl)
{
    var maxConnections = builder.Configuration.GetValue<int?>("DATABASE_MAX_CONN");

    builder.Services.AddNpgsqlDataSource(PostgresConnectionString.FromUrl(databaseUrl, maxConnections));
    builder.Services.AddSingleton<ItemService>();
    builder.Services.AddSingleton<FortuneService>();
}

// Compiles the aspx views under wwwroot into an assembly on first use. Outside
// development the last successful compilation is reused across restarts.
builder.Services.AddCodeBehind(!builder.Environment.IsDevelopment());

var app = builder.Build();

// Read the dataset now rather than on the first request.
app.Services.GetRequiredService<DatasetService>();

app.UseResponseCompression();

if (Directory.Exists("/data/static"))
{
    app.UseStaticFiles(new StaticFileOptions
    {
        FileProvider = new PhysicalFileProvider("/data/static"),
        RequestPath = "/static"
    });
}

// Controller-in-route mode: the first path segment selects the controller
// (/json/5 runs JsonController with "5" as its first Segment). Requests that
// match no controller continue down the pipeline and end in a 404.
app.UseCodeBehindRouteNextNotFoundAsync();

app.Run();

static X509Certificate2? LoadCertificate(IConfiguration configuration)
{
    var certificatePath = configuration["TLS_CERT"] ?? "/certs/server.crt";
    var keyPath = configuration["TLS_KEY"] ?? "/certs/server.key";

    return File.Exists(certificatePath) && File.Exists(keyPath)
        ? X509Certificate2.CreateFromPemFile(certificatePath, keyPath)
        : null;
}
