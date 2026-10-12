namespace HttpArena.Types;

/// <summary>
/// An item as stored in the dataset file and the Postgres `items` table.
/// </summary>
public sealed class Item
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

/// <summary>
/// A dataset item enriched with a computed total for the /json workload.
/// </summary>
public sealed class ProcessedItem
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

public sealed class RatingInfo
{
    public int Score { get; set; }
    public int Count { get; set; }
}

public sealed record ItemsResponse<T>(IReadOnlyList<T> Items, int Count);

public sealed record CrudItemInput(int Id, string? Name, string? Category, int Price, int Quantity);

public sealed class CrudListResponse
{
    public List<Item> Items { get; set; } = [];
    public long Total { get; set; }
    public int Page { get; set; }
    public int Limit { get; set; }
}

public sealed class CrudWriteResponse
{
    public int Id { get; set; }
    public string? Name { get; set; }
    public string? Category { get; set; }
    public int Price { get; set; }
    public int Quantity { get; set; }
}

/// <summary>
/// Result of a cached single-item read. Exactly one of <see cref="Item"/>
/// (typed, from the in-process cache path) or <see cref="Json"/>
/// (pre-serialized, from the Redis path) is set.
/// </summary>
public sealed record CachedItemResult(Item? Item, string? Json, bool CacheHit);

public sealed record Fortune(int Id, string Message);
