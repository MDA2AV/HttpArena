using System.Text.Json;

using GenHTTP.Api.Content;
using GenHTTP.Api.Infrastructure;
using GenHTTP.Api.Protocol;

using genhttp.Content;

namespace genhttp.Handlers;

/// <summary>
/// Serves the first {count} items of the dataset with their totals for ?m.
/// </summary>
public sealed class JsonHandler : IHandler
{
    private readonly DatasetItem[]? _items = LoadItems();

    private static DatasetItem[]? LoadItems()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase
        };

        var path = Environment.GetEnvironmentVariable("DATASET_PATH") ?? "/data/dataset.json";

        if (File.Exists(path))
        {
            return JsonSerializer.Deserialize<DatasetItem[]>(File.ReadAllText(path), options);
        }

        return null;
    }

    public ValueTask PrepareAsync(IServer server) => ValueTask.CompletedTask;

    public ValueTask<IResponse?> HandleAsync(IRequest request)
    {
        var items = _items ?? throw new ProviderException(ResponseStatus.InternalServerError, "No dataset");

        var header = request.Header;

        if (!Parameters.TryPath(header.Target, out var count))
        {
            throw new ProviderException(ResponseStatus.BadRequest, "Count must be an integer");
        }

        var m = Parameters.Query(header.Query, "m"u8, 1);

        count = Math.Clamp(count, 0, items.Length);

        var response = request.Respond()
                              .Content(DatasetContent.From(items, count, m))
                              .Build();

        return new(response);
    }

}
