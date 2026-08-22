/// Owns the shared Postgres connection pool and the optional Redis
/// connection, both configured from environment variables. Either may be
/// unavailable; consumers must check for None.
///
/// These are module-level bindings, so .NET runs them once on first access
/// and every caller shares the same pool without a container in between.
module HttpArena.Services.Database

open System

open Npgsql

open StackExchange.Redis

let private openPostgres () =
    match Environment.GetEnvironmentVariable "DATABASE_URL" with
    | null | "" -> None
    | dbUrl ->
        try
            let uri = Uri dbUrl
            let userInfo = uri.UserInfo.Split(':', 2)
            let maxConn =
                match Int32.TryParse(Environment.GetEnvironmentVariable "DATABASE_MAX_CONN") with
                | true, value when value > 0 -> value
                | _ -> 1024

            let connStr =
                NpgsqlConnectionStringBuilder(
                    Host = uri.Host,
                    Username = Uri.UnescapeDataString userInfo[0],
                    Database = uri.AbsolutePath.TrimStart '/',
                    MaxPoolSize = maxConn,
                    MinPoolSize = min 64 maxConn,
                    MaxAutoPrepare = 20,
                    NoResetOnClose = true,
                    Enlist = false
                )

            if userInfo.Length > 1 then
                connStr.Password <- Uri.UnescapeDataString userInfo[1]
            if uri.Port > 0 then
                connStr.Port <- uri.Port

            NpgsqlDataSourceBuilder(connStr.ConnectionString).Build() |> Some
        with _ ->
            None

let private openRedis () =
    match Environment.GetEnvironmentVariable "REDIS_URL" with
    | null | "" -> None
    | redisUrl ->
        try
            // REDIS_URL is "redis://host:port" — convert to StackExchange's
            // "host:port" configuration string.
            let uri = Uri redisUrl
            let config = ConfigurationOptions.Parse $"{uri.Host}:{uri.Port}"
            config.AbortOnConnectFail <- false
            ConnectionMultiplexer.Connect(config).GetDatabase() |> Some
        with _ ->
            None

let postgres = openPostgres ()

/// Optional Redis cache for the crud profile. When REDIS_URL is set, Items
/// uses Redis as a shared cache; otherwise it uses an in-process MemoryCache.
let redis = openRedis ()

/// Opens a pooled command.
let command (sql: string) = postgres.Value.CreateCommand sql
