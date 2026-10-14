using HttpArena.Services;
using HttpArena.Types;

using Microsoft.AspNetCore.Server.Kestrel.Core;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();

// The same source-generated JSON context and services as aspnet-minimal, whose
// Handlers.cs this entry compiles against (see the Dockerfile).
builder.Services.ConfigureHttpJsonOptions(o =>
    o.SerializerOptions.TypeInfoResolverChain.Insert(0, AppJsonContext.Default));

builder.Services.AddSingleton<DatabaseService>();
builder.Services.AddSingleton<DatasetService>();
builder.Services.AddSingleton<ItemService>();

builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenAnyIP(8080, lo =>
    {
        lo.Protocols = HttpProtocols.Http1;
    });
});

var app = builder.Build();

// Load the dataset and open the Postgres pool at startup instead of on the
// first request.
_ = app.Services.GetRequiredService<DatasetService>();
_ = app.Services.GetRequiredService<ItemService>();

app.MapGet("/baseline2", Handlers.Sum);
app.MapGet("/json/{count}", Handlers.Json);
app.MapGet("/async-db", Handlers.AsyncDatabase);

app.Run();
