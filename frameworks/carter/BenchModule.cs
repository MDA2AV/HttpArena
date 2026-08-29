using Carter;

using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;

namespace HttpArena.Carter;

/// Routes are declared in a Carter module rather than on the app directly:
/// module discovery and the IEndpointRouteBuilder mapping are what this entry
/// is here to measure.
public sealed class BenchModule : ICarterModule
{
    public void AddRoutes(IEndpointRouteBuilder app)
    {
        app.MapMethods("/baseline11", ["GET", "POST"], Handlers.Baseline11);
        app.MapGet("/json/{count:int}", Handlers.JsonItems);
        app.MapPost("/upload", Handlers.Upload);
    }
}
