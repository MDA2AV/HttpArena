using GenHTTP.Modules.Webservices;

namespace genhttp.Tests;

/// <summary>
/// The async profile: hold the request for the requested number of milliseconds, then answer.
/// </summary>
/// <remarks>
/// Task.Delay registers a timer and yields, so the thread goes back to the pool rather than
/// sitting on the request and the number of waits in flight is bounded by memory.
/// </remarks>
public class Delay
{

    [ResourceMethod(":ms")]
    public async ValueTask<string> Wait(int ms)
    {
        if (ms > 0)
        {
            await Task.Delay(ms);
        }

        return ms.ToString();
    }

}
