namespace HttpArena

open System.Text.Json

/// Rating block shared by the dataset file and the Postgres `items` table.
[<CLIMutable>]
type RatingInfo = { Score: int; Count: int }

/// An item as stored in the dataset file and the Postgres `items` table.
[<CLIMutable>]
type Item = {
    Id: int
    Name: string
    Category: string
    Price: int
    Quantity: int
    Active: bool
    Tags: string[]
    Rating: RatingInfo
}

/// A dataset item enriched with a computed total for the /json workload.
[<CLIMutable>]
type ProcessedItem = {
    Id: int
    Name: string
    Category: string
    Price: int
    Quantity: int
    Active: bool
    Tags: string[]
    Rating: RatingInfo
    Total: int
}

type JsonResponse = {
    Items: ProcessedItem[]
    Count: int
}

type AsyncDbResponse = {
    Items: ResizeArray<Item>
    Count: int
}

/// Request body of POST /crud/items and PUT /crud/items/{id}. Fields the
/// caller omits (PUT never sends an id) stay at their default.
[<CLIMutable>]
type CrudItemInput = {
    Id: int
    Name: string
    Category: string
    Price: int
    Quantity: int
}

type CrudListResponse = {
    Items: ResizeArray<Item>
    Total: int
    Page: int
    Limit: int
}

type CrudWriteResponse = {
    Id: int
    Name: string
    Category: string
    Price: int
    Quantity: int
}

/// Payload of a cached single-item read. The two cache backends hand back
/// different shapes: the in-process cache stores the typed DTO, Redis stores
/// the already-serialized JSON so a HIT skips a Deserialize+Serialize round trip.
[<Struct>]
type CachedItem =
    | TypedItem of item:Item
    | SerializedItem of json:string

[<Struct>]
type CachedItemResult = { Value: CachedItem; CacheHit: bool }

type Fortune = { Id: int; Message: string }

[<RequireQualifiedAccess>]
module Serialization =
    /// Shared System.Text.Json options: web defaults, i.e. camelCase property
    /// names, case-insensitive reads and numbers accepted as strings. The same
    /// instance is handed to Oxpecker's SystemTextJsonSerializer at startup, so
    /// handler responses and service-level (de)serialization agree on the shape.
    let options = JsonSerializerOptions(JsonSerializerDefaults.Web)
