/// Item queries against Postgres: the /async-db range query plus a realistic
/// CRUD API with paginated list, cached single-item read, create, and update.
/// Cache-aside on single-item reads with a 200ms TTL, invalidated on update.
/// List queries always hit Postgres.
module HttpArena.Services.Items

open System
open System.Data
open System.Data.Common
open System.Text.Json
open System.Threading.Tasks

open HttpArena

open Microsoft.Extensions.Caching.Memory

open Npgsql
open StackExchange.Redis

module private Sql =

    [<Literal>]
    let Columns = "id, name, category, price, quantity, active, tags, rating_score, rating_count"

    /// Range query for /async-db.
    [<Literal>]
    let Range = "SELECT " + Columns + " FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3"

    // Single data query. A COUNT(*) pass was 90%+ of PG CPU because concurrent
    // writes kept the visibility map dirty, forcing heap fetches on every
    // index-only scan. "Load more" pagination (return page size, no total) is a
    // realistic alternative that removes that dominant cost.
    [<Literal>]
    let List = "SELECT " + Columns + " FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3"

    [<Literal>]
    let ById = "SELECT " + Columns + " FROM items WHERE id = $1 LIMIT 1"

    [<Literal>]
    let Upsert =
        "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) "
        + "VALUES ($1, $2, $3, $4, $5, true, '[\"bench\"]', 0, 0) "
        + "ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 "
        + "RETURNING id"

    [<Literal>]
    let Update = "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4"

    let read (reader: DbDataReader) : Item = {
        Id = reader.GetInt32 0
        Name = reader.GetString 1
        Category = reader.GetString 2
        Price = reader.GetInt32 3
        Quantity = reader.GetInt32 4
        Active = reader.GetBoolean 5
        Tags = JsonSerializer.Deserialize<string[]>(reader.GetString 6, Serialization.options)
        Rating = { Score = reader.GetInt32 7; Count = reader.GetInt32 8 }
    }

let private intParameter (value: int) =
    NpgsqlParameter<int>(DbType = DbType.Int32, TypedValue = value)

let private floatParameter (value: float) =
    NpgsqlParameter<float>(DbType = DbType.Double, TypedValue = value)

let private stringParameter (value: string) =
    NpgsqlParameter<string>(DbType = DbType.String, TypedValue = value)

module private Cache =

    let ttl = TimeSpan.FromMilliseconds 200.0

    let entryOptions = MemoryCacheEntryOptions(AbsoluteExpirationRelativeToNow = Nullable ttl)

    let key (id: int) = $"crud:%i{id}"

    /// In-process fallback; only constructed when Redis is not configured.
    let local =
        match Database.redis with
        | Some _ -> ValueNone
        | None -> ValueSome(new MemoryCache(MemoryCacheOptions()))

let private fetchById (id: int) =
    task {
        use cmd = Database.command Sql.ById
        cmd.Parameters.Add(intParameter id) |> ignore
        use! reader = cmd.ExecuteReaderAsync()
        let! hasRow = reader.ReadAsync()
        return if hasRow then ValueSome(Sql.read reader) else ValueNone
    }

/// Range query for /async-db: items with price between `minPrice` and `maxPrice`.
let query (minPrice: float) (maxPrice: float) (limit: int) =
    let limit = Math.Clamp(limit, 1, 50)

    task {
        use cmd = Database.command Sql.Range
        cmd.Parameters.Add(floatParameter minPrice) |> ignore
        cmd.Parameters.Add(floatParameter maxPrice) |> ignore
        cmd.Parameters.Add(intParameter limit) |> ignore

        use! reader = cmd.ExecuteReaderAsync()
        let items = ResizeArray<Item> limit

        while! reader.ReadAsync() do
            items.Add(Sql.read reader)

        return { Items = items; Count = items.Count }
    }

/// Paginated list by category (always DB, never cached). Out-of-range paging
/// inputs fall back to page 1 / limit 10.
let list (category: string) (page: int) (limit: int) =
    let category = if String.IsNullOrEmpty category then "electronics" else category
    let page = if page < 1 then 1 else page
    let limit = if limit < 1 || limit > 50 then 10 else limit
    let offset = (page - 1) * limit

    task {
        use cmd = Database.command Sql.List
        cmd.Parameters.Add(stringParameter category) |> ignore
        cmd.Parameters.Add(intParameter limit) |> ignore
        cmd.Parameters.Add(intParameter offset) |> ignore

        use! reader = cmd.ExecuteReaderAsync()
        let items = ResizeArray<Item> limit

        while! reader.ReadAsync() do
            items.Add(Sql.read reader)

        return {
            Items = items
            Total = items.Count
            Page = page
            Limit = limit
        }
    }

/// Single item read, cached with a 200ms TTL. Redis when available (the cache
/// stores pre-serialized JSON so the HIT path skips a Serialize+Deserialize
/// round trip); else in-process MemoryCache (caches the typed DTO). Returns
/// None when the item does not exist.
let read (id: int) =
    let key = Cache.key id

    task {
        match Database.redis with
        | Some redis ->
            match! redis.StringGetAsync(RedisKey key) with
            | cached when cached.HasValue ->
                return ValueSome { Value = SerializedItem(cached.ToString()); CacheHit = true }
            | _ ->
                match! fetchById id with
                | ValueNone -> return ValueNone
                | ValueSome item ->
                    let json = JsonSerializer.Serialize(item, Serialization.options)
                    let! _ = redis.StringSetAsync(RedisKey key, RedisValue json, Nullable Cache.ttl, When.Always)
                    return ValueSome { Value = SerializedItem json; CacheHit = false }
        | None ->
            match Cache.local.Value.TryGetValue key with
            | true, (:? Item as item) -> return ValueSome { Value = TypedItem item; CacheHit = true }
            | _ ->
                match! fetchById id with
                | ValueNone -> return ValueNone
                | ValueSome item ->
                    Cache.local.Value.Set(key, item, Cache.entryOptions) |> ignore
                    return ValueSome { Value = TypedItem item; CacheHit = false }
    }

/// Creates an item (upsert on id conflict).
let create (input: CrudItemInput) =
    task {
        use cmd = Database.command Sql.Upsert
        cmd.Parameters.Add(intParameter input.Id) |> ignore
        cmd.Parameters.Add(stringParameter (if isNull input.Name then "New Product" else input.Name)) |> ignore
        cmd.Parameters.Add(stringParameter (if isNull input.Category then "test" else input.Category)) |> ignore
        cmd.Parameters.Add(intParameter input.Price) |> ignore
        cmd.Parameters.Add(intParameter input.Quantity) |> ignore

        let! newId = cmd.ExecuteScalarAsync()

        return {
            Id = unbox newId
            Name = input.Name
            Category = input.Category
            Price = input.Price
            Quantity = input.Quantity
        }
    }

/// Updates an item and invalidates its cache entry. Returns None when the item
/// does not exist.
let update (id: int) (input: CrudItemInput) =
    task {
        use cmd = Database.command Sql.Update
        cmd.Parameters.Add(stringParameter (if isNull input.Name then "Updated" else input.Name)) |> ignore
        cmd.Parameters.Add(intParameter input.Price) |> ignore
        cmd.Parameters.Add(intParameter input.Quantity) |> ignore
        cmd.Parameters.Add(intParameter id) |> ignore

        let! affected = cmd.ExecuteNonQueryAsync()

        if affected = 0 then
            return None
        else
            match Database.redis with
            | Some redis ->
                do! redis.KeyDeleteAsync(RedisKey(Cache.key id)) :> Task
            | None ->
                Cache.local.Value.Remove(Cache.key id)              

            return
                Some {
                    Id = id
                    Name = input.Name
                    Category = input.Category
                    Price = input.Price
                    Quantity = input.Quantity
                }
    }
