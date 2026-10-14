using HttpArena.Types;

namespace HttpArena.Services;

/// <summary>
/// Loads and prepares the fortune rows for the /fortunes HTML workload.
/// </summary>
public sealed class FortuneService(DatabaseService database)
{
    public bool IsAvailable => database.Postgres is not null;

    public async Task<List<Fortune>> GetFortunesAsync()
    {
        var list = new List<Fortune>(201);

        await using (var cmd = database.Postgres!.CreateCommand("SELECT id, message FROM fortune"))
        await using (var reader = await cmd.ExecuteReaderAsync())
        {
            while (await reader.ReadAsync())
            {
                list.Add(new Fortune(reader.GetInt32(0), reader.GetString(1)));
            }
        }

        // Runtime-injected row defeats whole-page memoization: the rendered
        // HTML must vary per request, even though the seeded rows don't.
        list.Add(new Fortune(0, "Additional fortune added at request time."));
        list.Sort(static (a, b) => string.CompareOrdinal(a.Message, b.Message));

        return list;
    }
}
