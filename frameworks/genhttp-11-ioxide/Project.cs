using GenHTTP.Api.Content;

using GenHTTP.Modules.IO;
using GenHTTP.Modules.Layouting;
using GenHTTP.Modules.Webservices;

using genhttp.Tests;

namespace genhttp;

public static class Project
{

    // Only the HTTP/1.1 plaintext endpoints exercised by this entry's profiles:
    //   baseline / limited-conn -> /baseline11 (Baseline webservice: GET/POST sum)
    //   pipelined               -> /pipeline   (fixed "ok")
    public static IHandlerBuilder Create()
        => Layout.Create()
                 .Add("pipeline", Content.From(Resource.FromString("ok")))
                 .AddService<Baseline>("baseline11")
                 .AddService<Baseline>("baseline2");

}
