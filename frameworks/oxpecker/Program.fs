module HttpArena.Program

open System
open System.IO
open System.Security.Cryptography.X509Certificates
open System.Threading.Tasks

open HttpArena.Services

open Microsoft.AspNetCore.Builder
open Microsoft.AspNetCore.Hosting
open Microsoft.AspNetCore.Server.Kestrel.Core
open Microsoft.Extensions.DependencyInjection
open Microsoft.Extensions.Hosting
open Microsoft.Extensions.Logging
open Microsoft.Extensions.Primitives

open Oxpecker


let endpoints = [
    GET [
        route "/pipeline" Handlers.pipeline
        route "/baseline11" Handlers.baseline
        route "/baseline2" Handlers.baseline
        route "/async-db" Handlers.asyncDb
        route "/fortunes" Handlers.fortunes
        routef "/json/{%i}" Handlers.json
    ]
    POST [
        route "/baseline11" Handlers.baselineWithBody
        route "/upload" Handlers.upload
    ]
    subRoute "/crud/items" [
        GET [
            route "" Handlers.crudList
            routef "/{%i}" Handlers.crudRead
        ]
        POST [ route "" Handlers.crudCreate ]
        PUT [ routef "/{%i}" Handlers.crudUpdate ]
    ]
]

let private envPath name fallback =
    match Environment.GetEnvironmentVariable(name: string) with
    | null | "" -> fallback
    | value -> value

let private configureKestrel (options: KestrelServerOptions) =
    options.AddServerHeader <- false
    options.Limits.Http2.MaxStreamsPerConnection <- 256
    options.Limits.Http2.InitialConnectionWindowSize <- 2 * 1024 * 1024
    options.Limits.Http2.InitialStreamWindowSize <- 1024 * 1024

    options.ListenAnyIP(8080, fun listen -> listen.Protocols <- HttpProtocols.Http1)

    // h2c prior-knowledge listener for the baseline-h2c / json-h2c profiles.
    // Protocols = Http2 with no UseHttps() gives Kestrel cleartext HTTP/2 from
    // the first byte, and clients that try HTTP/1.1 on this port get rejected —
    // which is what validate.sh's h2c anti-cheat requires.
    options.ListenAnyIP(8082, fun listen -> listen.Protocols <- HttpProtocols.Http2)

    let certPath = envPath "TLS_CERT" "/certs/server.crt"
    let keyPath = envPath "TLS_KEY" "/certs/server.key"

    if File.Exists certPath && File.Exists keyPath then
        let cert = X509Certificate2.CreateFromPemFile(certPath, keyPath)

        options.ListenAnyIP(
            8443,
            fun listen ->
                listen.Protocols <- HttpProtocols.Http1AndHttp2AndHttp3
                listen.UseHttps cert |> ignore
        )

        // HTTP/1.1-only TLS listener for the json-tls / static-tls profiles.
        // Kestrel advertises http/1.1 via ALPN so HTTP/1.1-only clients
        // negotiate correctly and never upgrade to h2.
        options.ListenAnyIP(
            8081,
            fun listen ->
                listen.Protocols <- HttpProtocols.Http1
                listen.UseHttps cert |> ignore
        )

[<EntryPoint>]
let main args =
    let builder = WebApplication.CreateBuilder(args)

    builder.Logging.ClearProviders() |> ignore
    builder.WebHost.ConfigureKestrel configureKestrel |> ignore

    builder.Services
        .AddRouting()
        .AddOxpecker()
        .AddResponseCompression()
    |> ignore

    let app = builder.Build()

    // The Services modules hold their state in module-level bindings, which
    // .NET initializes on first touch. Reading them here loads the dataset and
    // opens the Postgres/Redis pools at startup instead of during the first
    // request — and turns a missing dataset or DATABASE_URL into a startup
    // message rather than mystery 500s.
    if not Dataset.isAvailable then
        Console.Error.WriteLine "dataset not loaded; /json will answer 500"

    if not Database.isAvailable then
        Console.Error.WriteLine "DATABASE_URL not configured; DB endpoints will answer 500"

    app.UseResponseCompression() |> ignore

    app.UseRouting() |> ignore

    // Static assets are served by ASP.NET Core's static asset endpoints. The
    // SDK writes an endpoint manifest at publish time carrying each file's
    // content type, length and ETag alongside gzip/brotli variants on disk, so
    // a hit costs a route match plus the file read — not a content-type probe
    // and a fresh Brotli pass over the body on every request. Bodies still come
    // off disk; only the headers are precomputed.
    app.MapStaticAssets() |> ignore

    app.UseOxpecker endpoints |> ignore

    app.Run()
    0
