using System.Text.Json;
using System.Text.Json.Serialization.Metadata;

using CodeBehind;

namespace HttpArena;

// CodeBehind 4.8.1 derives a variable name from each route controller's
// namespace without replacing the dots, so all controllers live in the
// single-segment HttpArena namespace.

/// <summary>
/// Shared responses for the route controllers. A CodeBehind controller builds
/// its body with Write() and skips the view with IgnoreAll(); the framework has
/// no content type, status or JSON API of its own, so those go through the
/// ASP.NET Core HttpContext it hands to PageLoad.
/// </summary>
public abstract class HttpArenaController : CodeBehindController
{
    protected void Text(HttpContext context, string body)
    {
        context.Response.ContentType = "text/plain; charset=utf-8";
        Write(body);
        IgnoreAll();
    }

    protected void Json<T>(HttpContext context, T value, JsonTypeInfo<T> typeInfo)
    {
        context.Response.ContentType = "application/json";
        Write(JsonSerializer.Serialize(value, typeInfo));
        IgnoreAll();
    }

    protected void Status(HttpContext context, int statusCode)
    {
        context.Response.StatusCode = statusCode;
        IgnoreAll();
    }

    /// <summary>
    /// CodeBehind runs a route controller for every HTTP method, so each
    /// controller states which ones it answers.
    /// </summary>
    protected bool AllowMethod(HttpContext context, string method)
    {
        if (HttpMethods.Equals(context.Request.Method, method))
        {
            return true;
        }

        context.Response.Headers.Allow = method;
        Status(context, StatusCodes.Status405MethodNotAllowed);
        return false;
    }
}
