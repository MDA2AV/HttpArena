// The records: every publish, the entries and results as of the newest one, each result as
// every publish left it, and which log is kept under which path. The tables are the
// migration's in resources/migrations/; ArenaContext only maps them.
//
// A publish is a whole snapshot of the HttpArena repository's site/data at one commit of main,
// and it replaces what was there: a row the snapshot no longer has is removed, and its history
// gets a NULL row for that publish. Rows are kept as the JSON benchmark.sh wrote them, compacted,
// and compared by a hash of that JSON, so publishing the same data twice changes nothing.
//
// Every call makes a context on a connection of its own and uses it synchronously.

using System.Security.Cryptography;

/// <summary>What the HttpArena repository sends: site/data as of one commit of main.</summary>
/// <param name="Host">site/data/current.json: the benchmark machine</param>
/// <param name="Frameworks">site/data/frameworks.json: every entry, by display name</param>
/// <param name="Results">site/data/results/*.json, by file name without .json (the slug)</param>
public record Snapshot(string Commit, int? Pr, string Title, JsonElement Host,
                       Dictionary<string, JsonElement> Frameworks, Dictionary<string, ResultsFile> Results);

/// <summary>One file of site/data/results/: an entry's rows by "{profile}-{conns}".</summary>
public record ResultsFile(string Framework, Dictionary<string, JsonElement> Results);

/// <summary>What a publish did. Unchanged: it was the newest publish's commit again, with the same data.</summary>
public record PublishSummary(long Id, string Commit, int Frameworks, int Rows, int Changed, int Removed, bool Unchanged);

public record PublishInfo(long Id, DateTime Created, string Commit, int? Pr, string Title, int Changed, int Removed);

public sealed class PublishEntry
{
    public long Id { get; set; }

    public DateTime Created { get; set; }

    public string Commit { get; set; }

    public int? Pr { get; set; }

    public string Title { get; set; } = "";

    public string Host { get; set; } = "{}";

    public int Changed { get; set; }

    public int Removed { get; set; }
}

public sealed class FrameworkEntry
{
    public string Name { get; set; }

    public string Meta { get; set; }

    public long PublishId { get; set; }
}

public sealed class ResultEntry
{
    public string Framework { get; set; }

    public string Key { get; set; }

    public string Slug { get; set; }

    public string Row { get; set; }

    public string Hash { get; set; }

    public long PublishId { get; set; }
}

public sealed class HistoryEntry
{
    public long Id { get; set; }

    public string Slug { get; set; }

    public string Framework { get; set; }

    public string Key { get; set; }

    /// <summary>The row as this publish left it - null where it removed it.</summary>
    public string Row { get; set; }

    public long PublishId { get; set; }
}

public sealed class LogEntry
{
    public string Path { get; set; }

    public string Sha256 { get; set; }

    public long Bytes { get; set; }

    public long Stored { get; set; }

    public DateTime Updated { get; set; }
}

public sealed class ArenaContext(SqliteConnection connection) : DbContext
{
    public DbSet<PublishEntry> Publishes => Set<PublishEntry>();

    public DbSet<FrameworkEntry> Frameworks => Set<FrameworkEntry>();

    public DbSet<ResultEntry> Results => Set<ResultEntry>();

    public DbSet<HistoryEntry> History => Set<HistoryEntry>();

    public DbSet<LogEntry> Logs => Set<LogEntry>();

    protected override void OnConfiguring(DbContextOptionsBuilder options)
        => options.UseSqlite(connection, contextOwnsConnection: true);

    protected override void OnModelCreating(ModelBuilder model)
    {
        var publish = model.Entity<PublishEntry>().ToTable("publishes");
        publish.Property(p => p.Commit).HasColumnName("commit_sha");
        publish.Property(p => p.Created).HasConversion(t => Times.Write(t), t => Times.Read(t));

        var framework = model.Entity<FrameworkEntry>().ToTable("frameworks");
        framework.HasKey(f => f.Name);
        framework.Property(f => f.PublishId).HasColumnName("publish_id");

        var result = model.Entity<ResultEntry>().ToTable("results");
        result.HasKey(r => new { r.Framework, r.Key });
        result.Property(r => r.Key).HasColumnName("result_key");
        result.Property(r => r.Row).HasColumnName("row_json");
        result.Property(r => r.PublishId).HasColumnName("publish_id");

        var history = model.Entity<HistoryEntry>().ToTable("result_history");
        history.Property(h => h.Key).HasColumnName("result_key");
        history.Property(h => h.Row).HasColumnName("row_json");
        history.Property(h => h.PublishId).HasColumnName("publish_id");

        var log = model.Entity<LogEntry>().ToTable("logs");
        log.HasKey(l => l.Path);
        log.Property(l => l.Updated).HasConversion(t => Times.Write(t), t => Times.Read(t));
    }
}

/// <summary>Times as ISO 8601 text in UTC, which sorts as it should and reads well.</summary>
public static class Times
{
    public static string Write(DateTime value) => value.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);

    public static DateTime Read(string value) => DateTime.Parse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
}

public sealed class ArenaStore
{
    private const int MaxTitle = 300;

    public PublishSummary Publish(Snapshot snapshot)
    {
        Validate(snapshot);

        using var db = new ArenaContext(Database.GetConnection());

        // all of it or none: a failed publish leaves the previous one standing
        using var transaction = db.Database.BeginTransaction();

        var last = db.Publishes.AsNoTracking().OrderByDescending(p => p.Id).FirstOrDefault();

        var publish = new PublishEntry
        {
            Created = DateTime.UtcNow,
            Commit = snapshot.Commit,
            Pr = snapshot.Pr,
            Title = Clip(snapshot.Title ?? "", MaxTitle),
            Host = snapshot.Host.ValueKind == JsonValueKind.Object ? Json.Compact(snapshot.Host) : "{}"
        };

        db.Publishes.Add(publish);
        db.SaveChanges();

        var frameworksChanged = PublishFrameworks(db, snapshot, publish.Id);

        var (rows, changed, removed) = PublishResults(db, snapshot, publish.Id);

        if (changed == 0 && removed == 0 && !frameworksChanged && last != null && last.Commit == publish.Commit && last.Host == publish.Host)
        {
            // the same commit with the same data again - a workflow that ran twice
            transaction.Rollback();

            return new PublishSummary(last.Id, last.Commit, snapshot.Frameworks.Count, rows, 0, 0, Unchanged: true);
        }

        publish.Changed = changed;
        publish.Removed = removed;

        db.SaveChanges();
        transaction.Commit();

        return new PublishSummary(publish.Id, publish.Commit, snapshot.Frameworks.Count, rows, changed, removed, Unchanged: false);
    }

    /// <summary>site/data/frameworks.json, as the newest publish had it.</summary>
    public string FrameworksJson()
    {
        using var db = new ArenaContext(Database.GetConnection());

        var frameworks = db.Frameworks.AsNoTracking().OrderBy(f => f.Name).Select(f => new { f.Name, f.Meta }).ToList();

        return Json.Write(writer =>
        {
            writer.WriteStartObject();

            foreach (var framework in frameworks)
            {
                writer.WritePropertyName(framework.Name);
                writer.WriteRawValue(framework.Meta, skipInputValidation: true);
            }

            writer.WriteEndObject();
        });
    }

    /// <summary>Every file of site/data/results/, by slug - or the one file of that slug, null where there is none.</summary>
    public string ResultsJson(string slug = null)
    {
        using var db = new ArenaContext(Database.GetConnection());

        var query = db.Results.AsNoTracking();

        if (slug != null)
        {
            query = query.Where(r => r.Slug == slug);
        }

        var rows = query.OrderBy(r => r.Slug).ThenBy(r => r.Key).Select(r => new { r.Slug, r.Framework, r.Key, r.Row }).ToList();

        if (slug != null && rows.Count == 0)
        {
            return null;
        }

        return Json.Write(writer =>
        {
            if (slug == null)
            {
                writer.WriteStartObject();
            }

            foreach (var file in rows.GroupBy(r => r.Slug))
            {
                if (slug == null)
                {
                    writer.WritePropertyName(file.Key);
                }

                // the shape rebuild_site_data.py writes: {framework, results: {key: row}}
                writer.WriteStartObject();
                writer.WriteString("framework", file.First().Framework);
                writer.WritePropertyName("results");
                writer.WriteStartObject();

                foreach (var row in file)
                {
                    writer.WritePropertyName(row.Key);
                    writer.WriteRawValue(row.Row, skipInputValidation: true);
                }

                writer.WriteEndObject();
                writer.WriteEndObject();
            }

            if (slug == null)
            {
                writer.WriteEndObject();
            }
        });
    }

    /// <summary>site/data/current.json as of the newest publish, null before the first.</summary>
    public string HostJson()
    {
        using var db = new ArenaContext(Database.GetConnection());

        return db.Publishes.AsNoTracking().OrderByDescending(p => p.Id).Select(p => p.Host).FirstOrDefault();
    }

    public List<PublishInfo> Publishes(int limit)
    {
        using var db = new ArenaContext(Database.GetConnection());

        return db.Publishes.AsNoTracking()
                           .OrderByDescending(p => p.Id)
                           .Take(Math.Clamp(limit, 1, 200))
                           .Select(p => new PublishInfo(p.Id, p.Created, p.Commit, p.Pr, p.Title, p.Changed, p.Removed))
                           .ToList();
    }

    /// <summary>One row through every publish that changed it, oldest first.</summary>
    public string HistoryJson(string slug, string key)
    {
        using var db = new ArenaContext(Database.GetConnection());

        var changes = (from h in db.History.AsNoTracking()
                       where h.Slug == slug && h.Key == key
                       join p in db.Publishes.AsNoTracking() on h.PublishId equals p.Id
                       orderby h.PublishId
                       select new { p.Id, p.Created, p.Commit, p.Pr, h.Row }).ToList();

        return Json.Write(writer =>
        {
            writer.WriteStartArray();

            foreach (var change in changes)
            {
                writer.WriteStartObject();
                writer.WriteNumber("publish", change.Id);
                writer.WriteString("created", Times.Write(change.Created));
                writer.WriteString("commit", change.Commit);

                if (change.Pr is { } pr)
                {
                    writer.WriteNumber("pr", pr);
                }
                else
                {
                    writer.WriteNull("pr");
                }

                writer.WritePropertyName("row");

                if (change.Row != null)
                {
                    writer.WriteRawValue(change.Row, skipInputValidation: true);
                }
                else
                {
                    writer.WriteNullValue();
                }

                writer.WriteEndObject();
            }

            writer.WriteEndArray();
        });
    }

    public Dictionary<string, string> LogHashes()
    {
        using var db = new ArenaContext(Database.GetConnection());

        return db.Logs.AsNoTracking().ToDictionary(l => l.Path, l => l.Sha256);
    }

    public (long Bytes, long Stored) LogTotals()
    {
        using var db = new ArenaContext(Database.GetConnection());

        return (db.Logs.Sum(l => l.Bytes), db.Logs.Sum(l => l.Stored));
    }

    public LogEntry FindLog(string path)
    {
        using var db = new ArenaContext(Database.GetConnection());

        return db.Logs.AsNoTracking().FirstOrDefault(l => l.Path == path);
    }

    /// <summary>Keeps the log under its path, and says what it replaced - null where it is new.</summary>
    public string SaveLog(string path, string sha256, long bytes, long stored)
    {
        using var db = new ArenaContext(Database.GetConnection());

        var entry = db.Logs.Find(path);

        var previous = entry?.Sha256;

        if (entry == null)
        {
            db.Logs.Add(new LogEntry { Path = path, Sha256 = sha256, Bytes = bytes, Stored = stored, Updated = DateTime.UtcNow });
        }
        else
        {
            entry.Sha256 = sha256;
            entry.Bytes = bytes;
            entry.Stored = stored;
            entry.Updated = DateTime.UtcNow;
        }

        db.SaveChanges();

        return previous;
    }

    /// <summary>Forgets the log under a path, and says what it was - null where there was none.</summary>
    public string RemoveLog(string path)
    {
        using var db = new ArenaContext(Database.GetConnection());

        var entry = db.Logs.Find(path);

        if (entry == null)
        {
            return null;
        }

        db.Logs.Remove(entry);
        db.SaveChanges();

        return entry.Sha256;
    }

    public bool LogContentInUse(string sha256)
    {
        using var db = new ArenaContext(Database.GetConnection());

        return db.Logs.Any(l => l.Sha256 == sha256);
    }

    private static bool PublishFrameworks(ArenaContext db, Snapshot snapshot, long publishId)
    {
        var changed = false;

        var known = db.Frameworks.ToDictionary(f => f.Name);

        foreach (var (name, meta) in snapshot.Frameworks)
        {
            var json = Json.Compact(meta);

            if (known.Remove(name, out var entry))
            {
                if (entry.Meta != json)
                {
                    entry.Meta = json;
                    entry.PublishId = publishId;
                    changed = true;
                }
            }
            else
            {
                db.Frameworks.Add(new FrameworkEntry { Name = name, Meta = json, PublishId = publishId });
                changed = true;
            }
        }

        // what is left is no longer in frameworks.json
        if (known.Count > 0)
        {
            db.Frameworks.RemoveRange(known.Values);
            changed = true;
        }

        return changed;
    }

    private static (int Rows, int Changed, int Removed) PublishResults(ArenaContext db, Snapshot snapshot, long publishId)
    {
        int rows = 0, changed = 0, removed = 0;

        var current = db.Results.ToDictionary(r => (r.Framework, r.Key));

        var seen = new HashSet<(string, string)>();

        foreach (var (slug, file) in snapshot.Results)
        {
            foreach (var (key, value) in file.Results)
            {
                if (!seen.Add((file.Framework, key)))
                {
                    throw new ProviderException(ResponseStatus.BadRequest, $"{file.Framework} has more than one {key} row: two files name the same framework.");
                }

                rows++;

                var row = Json.Compact(value);

                var hash = Json.Hash(row);

                if (current.Remove((file.Framework, key), out var entry))
                {
                    if (entry.Hash == hash && entry.Slug == slug)
                    {
                        continue;
                    }

                    entry.Slug = slug;
                    entry.Row = row;
                    entry.Hash = hash;
                    entry.PublishId = publishId;
                }
                else
                {
                    db.Results.Add(new ResultEntry { Framework = file.Framework, Key = key, Slug = slug, Row = row, Hash = hash, PublishId = publishId });
                }

                db.History.Add(new HistoryEntry { Slug = slug, Framework = file.Framework, Key = key, Row = row, PublishId = publishId });

                changed++;
            }
        }

        // what is left was in the previous publish and is not in this one
        foreach (var gone in current.Values)
        {
            db.Results.Remove(gone);
            db.History.Add(new HistoryEntry { Slug = gone.Slug, Framework = gone.Framework, Key = gone.Key, Row = null, PublishId = publishId });

            removed++;
        }

        return (rows, changed, removed);
    }

    private static void Validate(Snapshot snapshot)
    {
        if (snapshot == null)
        {
            throw new ProviderException(ResponseStatus.BadRequest, "Send the snapshot as JSON: {commit, pr, title, host, frameworks, results}.");
        }

        if (snapshot.Commit is not { Length: >= 7 and <= 40 } commit || !commit.All(Uri.IsHexDigit))
        {
            throw new ProviderException(ResponseStatus.BadRequest, "commit is the hex SHA of the commit the snapshot was taken at.");
        }

        if (snapshot.Frameworks is not { Count: > 0 })
        {
            throw new ProviderException(ResponseStatus.BadRequest, "frameworks is site/data/frameworks.json, and it has entries.");
        }

        if (snapshot.Results == null)
        {
            throw new ProviderException(ResponseStatus.BadRequest, "results is site/data/results/*.json, by slug.");
        }

        foreach (var (slug, file) in snapshot.Results)
        {
            if (!Names.IsSlug(slug))
            {
                throw new ProviderException(ResponseStatus.BadRequest, $"{slug} is not a slug, which is lower case letters, digits, dots, underscores and dashes.");
            }

            if (file?.Framework is not { Length: > 0 and <= 200 } || file.Results == null)
            {
                throw new ProviderException(ResponseStatus.BadRequest, $"results/{slug} needs its framework and its results.");
            }

            foreach (var (key, row) in file.Results)
            {
                if (!Names.IsResultKey(key))
                {
                    throw new ProviderException(ResponseStatus.BadRequest, $"results/{slug} has the key {key}, which is not {{profile}}-{{conns}}.");
                }

                if (row.ValueKind != JsonValueKind.Object)
                {
                    throw new ProviderException(ResponseStatus.BadRequest, $"results/{slug}/{key} is not an object.");
                }
            }
        }
    }

    private static string Clip(string value, int max) => value.Length <= max ? value : value[..max];
}

/// <summary>Writing JSON as text, without going through objects.</summary>
public static class Json
{
    public static string Write(Action<Utf8JsonWriter> write)
    {
        using var buffer = new MemoryStream();

        using (var writer = new Utf8JsonWriter(buffer))
        {
            write(writer);
        }

        return Encoding.UTF8.GetString(buffer.GetBuffer(), 0, (int)buffer.Length);
    }

    /// <summary>The value as compact JSON, in the order its properties came in.</summary>
    public static string Compact(JsonElement value) => Write(value.WriteTo);

    public static string Hash(string json) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(json))).ToLowerInvariant();
}

/// <summary>What a slug, a result key and the parts of a log's path may be.</summary>
public static class Names
{
    /// <summary>As rebuild_site_data.py's _slug makes them: [a-z0-9._-], not starting with a dot.</summary>
    public static bool IsSlug(string value)
        => value is { Length: > 0 and <= 100 } && value[0] != '.' && value.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '.' or '_' or '-');

    /// <summary>"{profile}-{conns}": baseline-4096, latency-500k-8cpu-1024.</summary>
    public static bool IsResultKey(string value)
    {
        if (value is not { Length: >= 3 and <= 100 })
        {
            return false;
        }

        var dash = value.LastIndexOf('-');

        return dash > 0 && IsProfile(value[..dash]) && IsConnections(value[(dash + 1)..]);
    }

    public static bool IsProfile(string value)
        => value is { Length: > 0 and <= 64 } && value[0] != '-' && value.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-');

    public static bool IsConnections(string value)
        => value is { Length: > 0 and <= 7 } && value.All(char.IsAsciiDigit);

    /// <summary>The log of one entry: what benchmark.sh names it, {framework dir}.log.</summary>
    public static bool IsLogName(string value)
        => value is { Length: > 4 and <= 128 } && value.EndsWith(".log", StringComparison.Ordinal) && char.IsAsciiLetterOrDigit(value[0])
           && !value.Contains("..") && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-');
}
