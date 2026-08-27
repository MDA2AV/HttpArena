using GenHTTP.Modules.Webservices;

namespace genhttp.Tests;

public class AsyncDelay
{

    [ResourceMethod(":ms")]
    public async ValueTask<int> Delay(int ms)
    {
        if (ms > 0)
        {
            await Task.Delay(ms);
        }

        return ms;
    }

}
