using Npgsql;

namespace genhttp.Infrastructure;

public static class Postgres
{
    private static readonly NpgsqlDataSource? _pool = OpenPool();

    public static NpgsqlDataSource? Pool { get => _pool; }

    private static NpgsqlDataSource? OpenPool()
    {
        var dbUrl = Environment.GetEnvironmentVariable("DATABASE_URL");

        if (string.IsNullOrEmpty(dbUrl)) return null;

        try
        {
            var uri = new Uri(dbUrl);
            var userInfo = uri.UserInfo.Split(':');
            var maxConn = int.TryParse(Environment.GetEnvironmentVariable("DATABASE_MAX_CONN"), out var p) && p > 0 ? p : 256;
            var minConn = Math.Min(64, maxConn);
            var connStr = $"Host={uri.Host};Port={uri.Port};Username={userInfo[0]};Password={userInfo[1]};Database={uri.AbsolutePath.TrimStart('/')};Maximum Pool Size={maxConn};Minimum Pool Size={minConn};Multiplexing=true;No Reset On Close=true;Max Auto Prepare=20;Auto Prepare Min Usages=1";
            var builder = new NpgsqlDataSourceBuilder(connStr);

            return builder.Build();
        }
        catch
        {
            return null;
        }
    }

}
