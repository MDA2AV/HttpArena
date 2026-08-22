/// Serves the preloaded JSON dataset for the /json workload. The file is read
/// once, when this module is first touched.
module HttpArena.Services.Dataset

open System
open System.IO
open System.Text.Json

open HttpArena

let private items =
    let path =
        match Environment.GetEnvironmentVariable "DATASET_PATH" with
        | null | "" -> "/data/dataset.json"
        | value -> value

    if File.Exists path then
        JsonSerializer.Deserialize<Item[]>(File.ReadAllText path, Serialization.options)
    else
        null

let getItems (count: int) (multiplier: int) =
    let count = Math.Clamp(count, 0, items.Length)
    let processed = Array.zeroCreate<ProcessedItem> count

    for i in 0 .. count - 1 do
        let item = items[i]
        processed[i] <- {
            Id = item.Id
            Name = item.Name
            Category = item.Category
            Price = item.Price
            Quantity = item.Quantity
            Active = item.Active
            Tags = item.Tags
            Rating = item.Rating
            Total = item.Price * item.Quantity * multiplier
        }

    { JsonResponse.Items = processed; Count = count }
