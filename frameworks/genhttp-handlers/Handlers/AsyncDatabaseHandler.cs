using GenHTTP.Api.Content;
using GenHTTP.Api.Infrastructure;
using GenHTTP.Api.Protocol;

using genhttp.Content;
using genhttp.Infrastructure;

using Npgsql;

using static genhttp.Content.JsonNames;

namespace genhttp.Handlers;

/// <summary>
/// Queries items in a price range and streams the rows into a JSON buffer.
/// </summary>
public sealed class AsyncDatabaseHandler : IHandler
{
    private const string Sql = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";

    public ValueTask PrepareAsync(IServer server) => ValueTask.CompletedTask;

    public ValueTask<IResponse?> HandleAsync(IRequest request)
    {
        var query = request.Header.Query;

        var min = Parameters.Query(query, "min"u8, 10);
        var max = Parameters.Query(query, "max"u8, 50);
        var limit = Parameters.Query(query, "limit"u8, 50);

        return QueryAsync(request, min, max, limit);
    }

    private static async ValueTask<IResponse?> QueryAsync(IRequest request, int min, int max, int limit)
    {
        var content = BufferedJsonContent.Rent();

        try
        {
            var writer = content.Writer;

            writer.WriteStartObject();
            writer.WriteStartArray(Items);

            var count = 0;

            var pool = Postgres.Pool;

            if (pool != null)
            {
                await using var cmd = pool.CreateCommand(Sql);

                cmd.Parameters.Add(new NpgsqlParameter<int> { TypedValue = min });
                cmd.Parameters.Add(new NpgsqlParameter<int> { TypedValue = max });
                cmd.Parameters.Add(new NpgsqlParameter<int> { TypedValue = limit });

                await using var reader = await cmd.ExecuteReaderAsync();

                while (await reader.ReadAsync())
                {
                    writer.WriteStartObject();

                    writer.WriteNumber(Id, reader.GetInt32(0));
                    writer.WriteString(Name, reader.GetString(1));
                    writer.WriteString(Category, reader.GetString(2));
                    writer.WriteNumber(Price, reader.GetInt32(3));
                    writer.WriteNumber(Quantity, reader.GetInt32(4));
                    writer.WriteBoolean(Active, reader.GetBoolean(5));

                    // jsonb column, already a JSON array
                    writer.WritePropertyName(Tags);
                    writer.WriteRawValue(reader.GetString(6), skipInputValidation: true);

                    writer.WriteStartObject(Rating);
                    writer.WriteNumber(Score, reader.GetInt32(7));
                    writer.WriteNumber(Count, reader.GetInt32(8));
                    writer.WriteEndObject();

                    writer.WriteEndObject();

                    count++;
                }
            }

            writer.WriteEndArray();
            writer.WriteNumber(Count, count);
            writer.WriteEndObject();

            writer.Flush();

            return request.Respond()
                          .Content(content)
                          .Build();
        }
        catch
        {
            content.Dispose();
            throw;
        }
    }

}
