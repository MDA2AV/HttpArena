using Npgsql;

namespace HttpArena.Data;

/// <summary>
/// Turns the harness's DATABASE_URL (postgres://user:password@host:port/db)
/// into an Npgsql connection string, which does not accept the URL form.
/// </summary>
public static class PostgresConnectionString
{
    public static string FromUrl(string url, int? maxPoolSize)
    {
        var uri = new Uri(url);
        var credentials = uri.UserInfo.Split(':', 2);

        var builder = new NpgsqlConnectionStringBuilder
        {
            Host = uri.Host,
            Port = uri.IsDefaultPort ? 5432 : uri.Port,
            Database = uri.AbsolutePath.TrimStart('/'),
            Username = Uri.UnescapeDataString(credentials[0]),
            Password = credentials.Length > 1 ? Uri.UnescapeDataString(credentials[1]) : null
        };

        if (maxPoolSize is > 0)
        {
            builder.MaxPoolSize = maxPoolSize.Value;
        }

        return builder.ConnectionString;
    }
}
