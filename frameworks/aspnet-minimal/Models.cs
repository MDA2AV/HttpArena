record ResponseDto(IReadOnlyList<ProcessedItem> Items, int Count);

class DatasetItem
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public double Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public List<string> Tags { get; set; } = [];
    public RatingInfo Rating { get; set; } = new();
}

class ProcessedItem
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public double Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public List<string> Tags { get; set; } = [];
    public RatingInfo Rating { get; set; } = new();
    public double Total { get; set; }
}

class RatingInfo
{
    public double Score { get; set; }
    public int Count { get; set; }
}
