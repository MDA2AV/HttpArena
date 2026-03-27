namespace genhttp;

public class DatasetItem
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public double Price { get; set; }
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
    public double Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public List<string>? Tags { get; set; }
    public RatingInfo? Rating { get; set; }
    public double Total { get; set; }
}

public class RatingInfo
{
    public double Score { get; set; }
    public int Count { get; set; }
}

public class ListWithCount<T>(List<T> items)
{

    public List<T> Items => items;
    
    public int Count => items.Count;

}