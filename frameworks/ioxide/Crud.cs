using System.Buffers.Text;
using System.Text;
using System.Text.Json;
using ioxide.pg;

namespace IoxideArena;

internal enum CrudKind { None, List, GetOne, Create, Update }

/// <summary>
/// /crud/items - the realistic REST profile. The parser stashes the operation here (method, id,
/// query, body); the handler runs it against Postgres with Redis cache-aside on single-item reads
/// (X-Cache: MISS/HIT, invalidated on PUT). SQL is simple-protocol with inlined, quote-escaped
/// values - controlled benchmark input.
/// </summary>
internal sealed unsafe partial class HttpSession
{
    public CrudKind PendingCrud;
    public bool PendingCrudClose;

    private int _crudId;
    private string _crudCategory = "";
    private int _crudPage = 1, _crudLimit = 10;
    private byte[] _crudBody = [];
    private int _crudBodyLen;

    // -- routing (synchronous, in Respond) --------------------------------

    private void RouteCrud(ReadOnlySpan<byte> method, ReadOnlySpan<byte> path, ReadOnlySpan<byte> query, ReadOnlySpan<byte> body, bool close)
    {
        PendingCrudClose = close;
        bool isPost = method.SequenceEqual("POST"u8);
        bool isPut = method.SequenceEqual("PUT"u8);

        ReadOnlySpan<byte> rest = path[("/crud/items".Length)..];   // "" or "/{id}"
        if (rest.IsEmpty)
        {
            if (isPost) { StashBody(body); PendingCrud = CrudKind.Create; }
            else { ParseListParams(query); PendingCrud = CrudKind.List; }
            return;
        }
        if (rest[0] == (byte)'/')
        {
            Utf8Parser.TryParse(rest[1..], out _crudId, out _);
            if (isPut) { StashBody(body); PendingCrud = CrudKind.Update; }
            else { PendingCrud = CrudKind.GetOne; }
        }
    }

    private void StashBody(ReadOnlySpan<byte> body)
    {
        if (_crudBody.Length < body.Length) _crudBody = new byte[Math.Max(body.Length, 1024)];
        body.CopyTo(_crudBody);
        _crudBodyLen = body.Length;
    }

    private void ParseListParams(ReadOnlySpan<byte> query)
    {
        _crudCategory = ""; _crudPage = 1; _crudLimit = 10;
        while (query.Length > 0)
        {
            int amp = query.IndexOf((byte)'&');
            ReadOnlySpan<byte> kv = amp >= 0 ? query[..amp] : query;
            int eq = kv.IndexOf((byte)'=');
            if (eq >= 0)
            {
                ReadOnlySpan<byte> k = kv[..eq];
                ReadOnlySpan<byte> v = kv[(eq + 1)..];
                if (k.SequenceEqual("category"u8)) _crudCategory = Encoding.ASCII.GetString(v);
                else if (k.SequenceEqual("page"u8)) { Utf8Parser.TryParse(v, out int p, out _); _crudPage = Math.Max(1, p); }
                else if (k.SequenceEqual("limit"u8)) { Utf8Parser.TryParse(v, out int l, out _); _crudLimit = Math.Clamp(l, 1, 100); }
            }
            if (amp < 0) break;
            query = query[(amp + 1)..];
        }
    }

    // -- SQL (built from the stashed op) ----------------------------------

    private const string ItemCols = "id, name, category, price, quantity, active, tags, rating_score, rating_count";

    public string CrudCountSql() => $"SELECT count(*) FROM items WHERE category = '{Esc(_crudCategory)}'";

    public string CrudListSql() =>
        $"SELECT {ItemCols}, count(*) OVER() AS total FROM items WHERE category = '{Esc(_crudCategory)}' " +
        $"ORDER BY id LIMIT {_crudLimit} OFFSET {(_crudPage - 1) * _crudLimit}";

    public string CrudItemSql() => $"SELECT {ItemCols} FROM items WHERE id = {_crudId}";

    public string CrudInsertSql()
    {
        (int id, string name, string category, int price, int quantity) = ParseItemBody();
        return $"INSERT INTO items ({ItemCols}) VALUES " +
               $"({id}, '{Esc(name)}', '{Esc(category)}', {price}, {quantity}, false, '[]'::jsonb, 0, 0) " +
               $"ON CONFLICT (id) DO UPDATE SET name = excluded.name, category = excluded.category, " +
               $"price = excluded.price, quantity = excluded.quantity";
    }

    public string CrudUpdateSql()
    {
        (_, string name, string category, int price, int quantity) = ParseItemBody();
        return $"UPDATE items SET name = '{Esc(name)}', category = '{Esc(category)}', " +
               $"price = {price}, quantity = {quantity} WHERE id = {_crudId}";
    }

    public string CacheKey() => $"crud:item:{_crudId}";

    private (int Id, string Name, string Category, int Price, int Quantity) ParseItemBody()
    {
        int id = _crudId, price = 0, quantity = 0;
        string name = "", category = "";
        var reader = new Utf8JsonReader(_crudBody.AsSpan(0, _crudBodyLen));
        string prop = "";
        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.PropertyName) prop = reader.GetString() ?? "";
            else switch (prop)
            {
                case "id" when reader.TokenType == JsonTokenType.Number: id = reader.GetInt32(); break;
                case "name" when reader.TokenType == JsonTokenType.String: name = reader.GetString() ?? ""; break;
                case "category" when reader.TokenType == JsonTokenType.String: category = reader.GetString() ?? ""; break;
                case "price" when reader.TokenType == JsonTokenType.Number: price = reader.GetInt32(); break;
                case "quantity" when reader.TokenType == JsonTokenType.Number: quantity = reader.GetInt32(); break;
            }
        }
        return (id, name, category, price, quantity);
    }

    private static string Esc(string s) => s.Contains('\'') ? s.Replace("'", "''") : s;

    // -- list response ----------------------------------------------------

    private int _crudClOff, _crudBodyStart;
    private bool _crudFirstRow;
    private int _crudRows;
    private long _crudTotal;

    public void BeginCrudList()
    {
        _crudTotal = 0;   // captured from the first row's count(*) OVER()
        AppendOut("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "u8);
        _crudClOff = OutLen;
        AppendOut("00000000\r\n"u8);
        if (PendingCrudClose) AppendOut("Connection: close\r\n"u8);
        AppendOut("\r\n"u8);
        _crudBodyStart = OutLen;
        AppendOut("{\"items\":["u8);
        _crudFirstRow = true;
        _crudRows = 0;
    }

    public void AppendCrudRow(PgRow row)
    {
        if (!_crudFirstRow)
        {
            AppendOut(","u8);
        }
        else
        {
            Utf8Parser.TryParse(row.Field(9), out long t, out _);   // count(*) OVER() AS total
            _crudTotal = t;
        }
        _crudFirstRow = false;
        _crudRows++;
        AppendItem(row);
    }

    public void EndCrudList()
    {
        AppendOut("],\"total\":"u8); AppendLong(_crudTotal);
        AppendOut(",\"page\":"u8); AppendLong(_crudPage);
        AppendOut(",\"count\":"u8); AppendLong(_crudRows);
        AppendOut("}"u8);
        BackfillLength(_crudClOff, OutLen - _crudBodyStart, 8);
    }

    // -- single item (cache-aside) ----------------------------------------

    private byte[] _itemJson = [];
    private int _itemJsonLen;
    public bool CrudItemFound { get; private set; }

    // Row handler for the single-item query: build the item JSON into a scratch.
    public void CaptureCrudItem(PgRow row)
    {
        byte[] savedOut = Out; int savedLen = OutLen;
        Out = _itemJson; OutLen = 0;
        AppendItem(row);
        _itemJson = Out; _itemJsonLen = OutLen;
        Out = savedOut; OutLen = savedLen;
        CrudItemFound = true;
    }

    public void ResetCrudItem() => CrudItemFound = false;

    public ReadOnlySpan<byte> CrudItemBody() => _itemJson.AsSpan(0, _itemJsonLen);

    /// <summary>Write the single-item 200 with the X-Cache marker; body is freshly built or cached.</summary>
    public void WriteCrudItemResponse(ReadOnlySpan<byte> jsonBody, bool cacheHit)
    {
        AppendOut("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Cache: "u8);
        AppendOut(cacheHit ? "HIT"u8 : "MISS"u8);
        AppendOut("\r\nContent-Length: "u8);
        AppendLong(jsonBody.Length);
        if (PendingCrudClose) AppendOut("\r\nConnection: close"u8);
        AppendOut("\r\n\r\n"u8);
        AppendOut(jsonBody);
    }

    public void WriteCrud404()
    {
        AppendOut("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n"u8);
        if (PendingCrudClose) AppendOut("Connection: close\r\n"u8);
        AppendOut("\r\n"u8);
    }

    public void WriteCrudStatus(ReadOnlySpan<byte> statusLine)
    {
        AppendOut(statusLine);
        if (PendingCrudClose) AppendOut("Connection: close\r\n"u8);
        AppendOut("\r\n"u8);
    }

    public void WriteCrudUnavailable() =>
        WriteCrudStatus("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n"u8);

    // Item object shared by list rows and single item (mirrors the async-db shape).
    private void AppendItem(PgRow row)
    {
        AppendOut("{\"id\":"u8);            AppendOut(row.Field(0));
        AppendOut(",\"name\":\""u8);        AppendOut(row.Field(1));
        AppendOut("\",\"category\":\""u8);   AppendOut(row.Field(2));
        AppendOut("\",\"price\":"u8);       AppendOut(row.Field(3));
        AppendOut(",\"quantity\":"u8);      AppendOut(row.Field(4));
        AppendOut(row.Field(5).SequenceEqual("t"u8) ? ",\"active\":true"u8 : ",\"active\":false"u8);
        AppendOut(",\"tags\":"u8);          AppendOut(row.Field(6));
        AppendOut(",\"rating\":{\"score\":"u8); AppendOut(row.Field(7));
        AppendOut(",\"count\":"u8);         AppendOut(row.Field(8));
        AppendOut("}}"u8);
    }

    private void BackfillLength(int offset, int value, int digits)
    {
        for (int d = offset + digits - 1; d >= offset; d--) { Out[d] = (byte)('0' + value % 10); value /= 10; }
    }
}
