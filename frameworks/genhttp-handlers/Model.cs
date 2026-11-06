namespace genhttp;

public sealed class DatasetItem
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public int Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public string[] Tags { get; set; } = [];
    public RatingInfo Rating { get; set; } = new();
}

public sealed class RatingInfo
{
    public int Score { get; set; }
    public int Count { get; set; }
}
