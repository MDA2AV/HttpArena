// The container logs benchmark.sh keeps for every run stay in the HttpArena repository, under
// site/static/logs/, and this lambda keeps no copy of them. The address the site links a log
// from, logs/{profile}/{conns}/{framework dir}.log, sends the reader on to that file in the
// repository, as it is on main.

public static class Logs
{
    private const string Repository = "https://raw.githubusercontent.com/MDA2AV/HttpArena/main/site/static/logs/";

    /// <summary>GET {profile}/{conns}/{name}: sent on to the log in the repository.</summary>
    public static IHandlerBuilder Serve()
        => Inline.Create()
                 .Get(":profile/:conns/:name", (IRequest request, string profile, string conns, string name) => Send(request, profile, conns, name));

    private static IResponseBuilder Send(IRequest request, string profile, string conns, string name)
    {
        if (!Names.IsProfile(profile) || !Names.IsConnections(conns) || !Names.IsLogName(name))
        {
            throw new ProviderException(ResponseStatus.NotFound, "There is no such log.");
        }

        // temporary, so that where logs are kept can change without browsers remembering this
        return request.Respond()
                      .Status(ResponseStatus.Found)
                      .Header("Location", $"{Repository}{profile}/{conns}/{name}");
    }
}
