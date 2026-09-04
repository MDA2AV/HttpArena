using GenHTTP.Modules.Webservices;

namespace genhttp.Tests;

/// <summary>
/// The async profile: hold the request for the requested number of milliseconds, then answer.
/// </summary>
/// <remarks>
/// What the profile measures is whether waiting costs a thread. On this engine the await resumes
/// inline on the reactor that issued it, so a delayed request occupies a connection and nothing
/// else - a blocking server is capped at threads/delay, this one at connections/delay.
/// </remarks>
public class Delay
{

    // The body echoes the delay back, which is how the profile checks that the wait tracked the
    // parameter rather than being a constant sleep.
    [ResourceMethod(":ms")]
    public async ValueTask<string> Wait(int ms)
    {
        await Task.Delay(ms);

        return ms.ToString();
    }

}
