namespace ServiceStack.Benchmarks;

public static class PgPoolFactory
{
    public static Npgsql.NpgsqlDataSource? Open()
    {
        var url = Environment.GetEnvironmentVariable("DATABASE_URL");
        if (string.IsNullOrEmpty(url)) return null;
        try
        {
            var uri  = new Uri(url);
            var info = uri.UserInfo.Split(':');
            var cs   = $"Host={uri.Host};Port={uri.Port};Username={info[0]};Password={info[1]};" +
                       $"Database={uri.AbsolutePath.TrimStart('/')};" +
                       "Maximum Pool Size=256;Minimum Pool Size=64;" +
                       "Multiplexing=true;No Reset On Close=true;" +
                       "Max Auto Prepare=4;Auto Prepare Min Usages=1";
            return new Npgsql.NpgsqlDataSourceBuilder(cs).Build();
        }
        catch { return null; }
    }
}
