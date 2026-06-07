namespace Shrike;

public class H1HeaderData
{
    public string Route { get; internal set; } = null!;
    public string HttpMethod { get; internal set; } = null!;
    public PooledDictionary<string, string> QueryParameters { get; }
    public PooledDictionary<string, string> Headers { get; }

    public H1HeaderData()
    {
        QueryParameters = new PooledDictionary<string, string>(
            capacity: 8,
            comparer: StringComparer.OrdinalIgnoreCase);
        
        Headers = new PooledDictionary<string, string>(
            capacity: 8,
            comparer: StringComparer.OrdinalIgnoreCase);
    }

    public void Clear()
    {
        Headers?.Clear();
        QueryParameters?.Clear();
    }
}