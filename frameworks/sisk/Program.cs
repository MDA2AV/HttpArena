using System.Diagnostics;
using System.Net.Http.Json;
using System.Text.Json;
using Npgsql;
using sisk;
using Sisk.Cadente.CoreEngine;
using Sisk.Core.Http;
using Sisk.Core.Http.FileSystem;
using Sisk.Core.Routing;

var server = HttpServer.CreateBuilder ()
                       .UseEngine<CadenteHttpServerEngine> ()
                       .UseListeningPort ( new ListeningPort ( false, "0.0.0.0", 8080 ) )
                       .UseMinimalConfiguration ()
                       .UseConfiguration ( config => {
                           config.EnableAutomaticResponseCompression = true;
                       } );

Router router = new Router ();

var staticRoute = HttpFileServer.CreateServingRoute ( "/static", new HttpFileServerHandler () {
    RootDirectoryPath = "/data/static",
    AllowDirectoryListing = false
} );

router.SetRoute ( staticRoute );

router.MapGet ( "/baseline11", r => new HttpResponse ( Sum ( r ) ) );
router.MapPost ( "/baseline11", r => new HttpResponse ( Sum ( r ) ) );

router.MapGet ( "/baseline2", r => new HttpResponse ( Sum ( r ) ) );

router.MapGet ( "/pipeline", r => new HttpResponse ( "ok" ) );

router.MapPost ( "/upload", r => {
    var body = r.GetBodyContents ();
    return new HttpResponse ( body.Length.ToString () );
} );

var datasetItems = LoadItems ();

router.MapGet ( "/json/<count>", r => {
    int count = Math.Clamp ( int.Parse ( r.RouteParameters [ "count" ].GetString () ), 0, datasetItems!.Count );
    int m = 1;
    if (r.Query.TryGetValue ( "m", out var mStr )) { int.TryParse ( mStr, out m ); if (m == 0) m = 1; }
    var processed = new ProcessedItem [ count ];

    for (int i = 0; i < count; i++) {
        var d = datasetItems [ i ];
        processed [ i ] = new ProcessedItem {
            Id = d.Id,
            Name = d.Name,
            Category = d.Category,
            Price = d.Price,
            Quantity = d.Quantity,
            Active = d.Active,
            Tags = d.Tags,
            Rating = d.Rating,
            Total = d.Price * d.Quantity * m
        };
    }

    return new HttpResponse {
        Content = JsonContent.Create ( new ListWithCount<ProcessedItem> ( processed.ToList () ) )
    };
} );

var pgDataSource = OpenPgPool ();

router.MapGet ( "/async-db", async ( HttpRequest request ) => {
    var min = request.Query.TryGetValue ( "min", out var vmin ) ? vmin.GetInteger () : 10;
    var max = request.Query.TryGetValue ( "max", out var vmax ) ? vmax.GetInteger () : 50;
    var limit = request.Query.TryGetValue ( "limit", out var vlim ) ? Math.Clamp ( vlim.GetInteger (), 1, 50 ) : 50;

    Debug.Assert ( pgDataSource != null, "PostgreSQL data source is not available. Please set the DATABASE_URL environment variable." );

    await using var cmd = pgDataSource.CreateCommand (
        "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3" );

    cmd.Parameters.AddWithValue ( min );
    cmd.Parameters.AddWithValue ( max );
    cmd.Parameters.AddWithValue ( limit );
    await using var reader = await cmd.ExecuteReaderAsync ();

    var items = new List<object> ();

    while (await reader.ReadAsync ()) {
        items.Add ( new {
            id = reader.GetInt32 ( 0 ),
            name = reader.GetString ( 1 ),
            category = reader.GetString ( 2 ),
            price = reader.GetInt32 ( 3 ),
            quantity = reader.GetInt32 ( 4 ),
            active = reader.GetBoolean ( 5 ),
            tags = JsonSerializer.Deserialize<List<string>> ( reader.GetString ( 6 ) ),
            rating = new { score = reader.GetInt32 ( 7 ), count = reader.GetInt32 ( 8 ) },
        } );
    }

    return new HttpResponse {
        Content = JsonContent.Create ( new ListWithCount<object> ( items ) )
    };
} );

await server.UseRouter ( router ).Build ().StartAsync ();

return;

static string Sum ( HttpRequest request ) {
    var a = request.Query [ "a" ].MaybeNullOrEmpty ()?.GetInteger () ?? 0;
    var b = request.Query [ "b" ].MaybeNullOrEmpty ()?.GetInteger () ?? 0;

    var c = 0;

    if (request.Method == HttpMethod.Post) {
        c = int.Parse ( request.Body );
    }

    return (a + b + c).ToString ();
}

static List<DatasetItem>? LoadItems () {
    var jsonOptions = new JsonSerializerOptions {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    var datasetPath = Environment.GetEnvironmentVariable ( "DATASET_PATH" ) ?? "/data/dataset.json";

    if (File.Exists ( datasetPath )) {
        return JsonSerializer.Deserialize<List<DatasetItem>> ( File.ReadAllText ( datasetPath ), jsonOptions );
    }

    return null;
}

static NpgsqlDataSource? OpenPgPool () {
    var dbUrl = Environment.GetEnvironmentVariable ( "DATABASE_URL" );
    if (string.IsNullOrEmpty ( dbUrl ))
        return null;
    try {
        var uri = new Uri ( dbUrl );
        var userInfo = uri.UserInfo.Split ( ':' );
        var connStr = $"Host={uri.Host};Port={uri.Port};Username={userInfo [ 0 ]};Password={userInfo [ 1 ]};Database={uri.AbsolutePath.TrimStart ( '/' )};Maximum Pool Size=256;Minimum Pool Size=64;Multiplexing=true;No Reset On Close=true;Max Auto Prepare=4;Auto Prepare Min Usages=1";
        var builder = new NpgsqlDataSourceBuilder ( connStr );
        return builder.Build ();
    }
    catch {
        return null;
    }
}

