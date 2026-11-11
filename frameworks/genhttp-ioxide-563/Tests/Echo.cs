using GenHTTP.Modules.Reflection;
using GenHTTP.Modules.Webservices;

namespace genhttp.Tests;

public class Echo
{

    [ResourceMethod(Method.Post)]
    public Stream Return(Stream input) => input;

}
