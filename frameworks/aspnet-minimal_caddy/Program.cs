using Microsoft.AspNetCore.Server.Kestrel.Core;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();

builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenAnyIP(8080, lo =>
    {
        lo.Protocols = HttpProtocols.Http1;
    });
});

var app = builder.Build();

AppData.Load();

app.MapGet("/baseline2", Handlers.Sum);
app.MapGet("/json/{count}", Handlers.Json);
app.MapGet("/async-db", Handlers.AsyncDatabase);

app.Run();
