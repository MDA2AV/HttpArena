namespace ServiceStack.Benchmarks;

public class DatasetItem
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public int Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public List<string>? Tags { get; set; }
    public RatingInfo? Rating { get; set; }
}

public class ProcessedItem
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public int Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public List<string>? Tags { get; set; }
    public RatingInfo? Rating { get; set; }
    public long Total { get; set; }
}

public class RatingInfo
{
    public int Score { get; set; }
    public int Count { get; set; }
}

public class ListWithCount<T>(List<T> items)
{

    public List<T> Items => items;

    public int Count => items.Count;

}

public static class DatasetItemExtensions
{
    public static ProcessedItem ToProcessed(this DatasetItem d, int m = 1) => new()
    {
        Id       = d.Id,       Name     = d.Name,
        Category = d.Category, Price    = d.Price,
        Quantity = d.Quantity, Active   = d.Active,
        Tags     = d.Tags,     Rating   = d.Rating,
        Total    = d.Price * d.Quantity * m
    };
}