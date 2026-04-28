using GenHTTP.Api.Protocol;
using GenHTTP.Modules.Webservices;

namespace genhttp.Tests;

public class Upload
{

    [ResourceMethod(RequestMethod.Post)]
    public ValueTask<long> Compute(Stream input)
    {
        if (input.CanSeek)
        {
            // internal engine
            return ValueTask.FromResult(input.Length);
        }

        // kestrel
        return ComputeManually(input);
    }

    private async ValueTask<long> ComputeManually(Stream input)
    {
        var buffer = new byte[8192];

        long total = 0;

        var read = 0;

        while ((read = await input.ReadAsync(buffer)) > 0)
        {
            total += read;
        }

        return total;
    }
    
}