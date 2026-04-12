sealed record ResponseDto<T>(IReadOnlyList<T> Items, int Count);


sealed class DbResponseItemDto
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public int Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public List<string> Tags { get; set; } = [];
    public RatingInfo Rating { get; set; } = new();
}

sealed class DatasetItem
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public int Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public List<string> Tags { get; set; } = [];
    public RatingInfo Rating { get; set; } = new();
}

sealed class ProcessedItem
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public int Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public List<string> Tags { get; set; } = [];
    public RatingInfo Rating { get; set; } = new();
    public long Total { get; set; }
}

sealed class RatingInfo
{
    public int Score { get; set; }
    public int Count { get; set; }
}
