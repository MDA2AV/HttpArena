module HttpArena.Handlers

open System
open System.Globalization
open System.IO
open System.Text
open HttpArena.Services
open Microsoft.AspNetCore.Http
open Oxpecker

/// Reads an int query parameter through Oxpecker's query accessor, falling
/// back to `fallback` when the parameter is absent or unparsable.
let private queryInt (ctx: HttpContext) (key: string) (fallback: int) =
    match ctx.TryGetQueryValue key with
    | Some raw ->
        match Int32.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture) with
        | true, value -> value
        | _ -> fallback
    | None -> fallback

let private queryFloat (ctx: HttpContext) (key: string) (fallback: float) =
    match ctx.TryGetQueryValue key with
    | Some raw ->
        match Double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture) with
        | true, value -> value
        | _ -> fallback
    | None -> fallback

// ── Connection profiles ────────────────────────────────────────────────────

let pipeline: EndpointHandler = text "ok"

/// GET /baseline11 and GET /baseline2 — sum of the two query parameters.
let baseline: EndpointHandler =
    fun ctx ->
        let a = queryInt ctx "a" 0
        let b = queryInt ctx "b" 0
        ctx.WriteText(string (a + b))

/// POST /baseline11 — sum of the two query parameters plus the request body.
let baselineWithBody: EndpointHandler =
    fun ctx ->
        let a = queryInt ctx "a" 0
        let b = queryInt ctx "b" 0

        task {
            use reader = new StreamReader(ctx.Request.Body)
            let! body = reader.ReadToEndAsync()

            let fromBody =
                match Int32.TryParse(body, NumberStyles.Integer, CultureInfo.InvariantCulture) with
                | true, value -> value
                | _ -> 0

            return! ctx.WriteText(string (a + b + fromBody))
        }

// ── Workload profiles ──────────────────────────────────────────────────────

/// POST /echo — the request body written back verbatim.
///
/// The body is copied into a MemoryStream rather than piped straight to the
/// response because the length has to be known before the first byte goes out:
/// a chunked request carries no Content-Length to forward, and WriteBytes sets
/// one from the array it is given — zero included, for an empty body.
let echo: EndpointHandler =
    fun ctx ->
        task {
            use body = new MemoryStream()
            do! ctx.Request.Body.CopyToAsync body

            ctx.SetContentType "application/octet-stream"
            return! ctx.WriteBytes(body.ToArray())
        }

/// GET /json/{count}?m=N — the first `count` dataset items, each carrying a
/// total computed from the multiplier.
let json (count: int) : EndpointHandler =
    fun ctx ->
        let multiplier = queryInt ctx "m" 1
        let response = Dataset.getItems count multiplier
        ctx.WriteJsonChunked response

// ── Database profiles ──────────────────────────────────────────────────────

/// GET /async-db — Postgres range query over the unindexed price column.
let asyncDb: EndpointHandler =
    fun ctx ->
        let minPrice = queryFloat ctx "min" 10.0
        let maxPrice = queryFloat ctx "max" 50.0
        let limit = queryInt ctx "limit" 50
        task {
            let! response = Items.query minPrice maxPrice limit
            return! ctx.WriteJsonChunked response
        }   

/// GET /crud/items — paginated list by category.
let crudList: EndpointHandler =
    fun ctx ->
        let category = ctx.TryGetQueryValue "category" |> Option.defaultValue ""
        let page = queryInt ctx "page" 0
        let limit = queryInt ctx "limit" 0
        task {
            let! response = Items.list category page limit
            return! ctx.WriteJsonChunked response
        }

/// GET /crud/items/{id} — cache-aside single-item read, reporting the cache
/// outcome through X-Cache.
let crudRead (id: int) : EndpointHandler =
    fun ctx ->
        task {
            match! Items.read id with
            | ValueNone ->
                ctx.SetStatusCode 404
            | ValueSome result ->
                ctx.SetHttpHeader("X-Cache", if result.CacheHit then "HIT" else "MISS")
                match result.Value with
                | TypedItem item ->
                    return! ctx.WriteJsonChunked item
                | SerializedItem cached ->
                    // Already JSON on the Redis path — write the cached bytes
                    // back rather than round-tripping them through the serializer.
                    ctx.SetContentType "application/json"
                    return! ctx.WriteBytes(Encoding.UTF8.GetBytes cached)
        }

/// POST /crud/items — create (upsert on id conflict).
let crudCreate: EndpointHandler =
    fun ctx ->
        task {
            let! input = ctx.BindJson<CrudItemInput>()
            let! created = Items.create input
            ctx.SetStatusCode 201
            return! ctx.WriteJsonChunked created
        }

/// PUT /crud/items/{id} — update and invalidate the cached entry.
let crudUpdate (id: int) : EndpointHandler =
    fun ctx ->
        task {
            let! input = ctx.BindJson<CrudItemInput>()
            match! Items.update id input with
            | None ->
                ctx.SetStatusCode 404
            | Some updated ->
                return! ctx.WriteJsonChunked updated
        }
            

// ── Template profile ───────────────────────────────────────────────────────

/// GET /fortunes — DB query plus an Oxpecker.ViewEngine render.
let fortunes: EndpointHandler =
    fun ctx ->
        task {
            let! rows = Fortunes.getRows ()
            return! ctx.WriteHtmlViewChunked(Views.fortunes rows)
        }
