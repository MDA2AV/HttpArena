using Npgsql;

namespace HttpArena.Data;

/// <summary>
/// Loads the fortune rows for the /fortunes page.
/// </summary>
public sealed class FortuneService(NpgsqlDataSource dataSource)
{
    public async Task<List<Fortune>> GetFortunesAsync(CancellationToken cancellationToken)
    {
        var fortunes = new List<Fortune>(201);

        await using (var command = dataSource.CreateCommand("SELECT id, message FROM fortune"))
        await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                fortunes.Add(new Fortune(reader.GetInt32(0), reader.GetString(1)));
            }
        }

        // Added per request, so the page differs from what the table alone would render.
        fortunes.Add(new Fortune(0, "Additional fortune added at request time."));
        fortunes.Sort(static (a, b) => string.CompareOrdinal(a.Message, b.Message));

        return fortunes;
    }
}
