using System.Text.Json;

using GenHTTP.Api.Content;
using GenHTTP.Api.Protocol;
using GenHTTP.Modules.Webservices;

namespace genhttp.Tests;

public class Json
{
    private static List<DatasetItem>? datasetItems = LoadItems();

    private static List<DatasetItem> LoadItems()
    {
        var jsonOptions = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase
        };
        
        var datasetPath = Environment.GetEnvironmentVariable("DATASET_PATH") ?? "/data/dataset.json";
        
        if (File.Exists(datasetPath))
        {
            return JsonSerializer.Deserialize<List<DatasetItem>>(File.ReadAllText(datasetPath), jsonOptions);
        }

        return null;
    }
    
    [ResourceMethod]
    public ListWithCount<ProcessedItem> Compute()
    {
        if (datasetItems == null)
        {
            throw new ProviderException(ResponseStatus.InternalServerError, "No dataset");
        }
        
        var processed = new List<ProcessedItem>(datasetItems.Count);
        
        foreach (var d in datasetItems)
        {
            processed.Add(new ProcessedItem
            {
                Id = d.Id, Name = d.Name, Category = d.Category,
                Price = d.Price, Quantity = d.Quantity, Active = d.Active,
                Tags = d.Tags, Rating = d.Rating,
                Total = Math.Round(d.Price * d.Quantity, 2)
            });
        }

        return new(processed);
    }
    
}