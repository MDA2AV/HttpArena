using System.Globalization;
using System.Net;
using System.Text;
using Sisk.Cadente;

HttpHost.ServerNameHeader = "cadente";

using var host = new HttpHost ( new IPEndPoint ( IPAddress.Any, 8080 ) ) {
    Handler = new BenchmarkHandler ()
};

host.Start ();
await Task.Delay ( Timeout.InfiniteTimeSpan );

sealed class BenchmarkHandler : HttpHostHandler {
    private static readonly byte [] PipelineBody = "ok"u8.ToArray ();
    private static readonly byte [] NotFoundBody = "Not Found"u8.ToArray ();

    public override async Task OnContextCreatedAsync ( HttpHost host, HttpHostContext context ) {
        var request = context.Request;
        var path = request.Path;
        var queryIndex = path.IndexOf ( '?' );
        var route = queryIndex >= 0 ? path [ ..queryIndex ] : path;

        if (request.Method == "GET" && route == "/pipeline") {
            await WriteTextAsync ( context, PipelineBody );
            return;
        }

        if ((request.Method == "GET" || request.Method == "POST") && route == "/baseline11") {
            var query = queryIndex >= 0 ? path [ (queryIndex + 1) .. ] : string.Empty;
            var a = 0;
            var b = 0;

            foreach (var pair in query.Split ( '&', StringSplitOptions.RemoveEmptyEntries )) {
                var separator = pair.IndexOf ( '=' );
                if (separator <= 0 || !int.TryParse ( pair [ (separator + 1) .. ], NumberStyles.Integer, CultureInfo.InvariantCulture, out var value )) {
                    continue;
                }

                if (pair.AsSpan ( 0, separator ).SequenceEqual ( "a" )) {
                    a = value;
                }
                else if (pair.AsSpan ( 0, separator ).SequenceEqual ( "b" )) {
                    b = value;
                }
            }

            var c = 0;
            if (request.Method == "POST") {
                using var reader = new StreamReader ( request.GetRequestStream (), Encoding.UTF8, detectEncodingFromByteOrderMarks: false, leaveOpen: true );
                int.TryParse ( await reader.ReadToEndAsync (), NumberStyles.Integer, CultureInfo.InvariantCulture, out c );
            }

            await WriteTextAsync ( context, Encoding.ASCII.GetBytes ( (a + b + c).ToString ( CultureInfo.InvariantCulture ) ) );
            return;
        }

        context.Response.StatusCode = 404;
        context.Response.StatusDescription = "Not Found";
        await WriteTextAsync ( context, NotFoundBody );
    }

    private static async Task WriteTextAsync ( HttpHostContext context, byte [] body ) {
        context.Response.Headers.Set ( new HttpHeader ( "Content-Type", "text/plain; charset=utf-8" ) );
        context.Response.Headers.Set ( new HttpHeader ( "Content-Length", body.Length.ToString ( CultureInfo.InvariantCulture ) ) );
        await using var stream = await context.Response.GetResponseStreamAsync ( chunked: false );
        await stream.WriteAsync ( body );
    }
}
