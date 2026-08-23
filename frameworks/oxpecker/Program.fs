module HttpArena.Program

open System
open System.IO
open System.Security.Cryptography.X509Certificates
open Microsoft.AspNetCore.Builder
open Microsoft.AspNetCore.Hosting
open Microsoft.AspNetCore.Http
open Microsoft.AspNetCore.Server.Kestrel.Core
open Microsoft.AspNetCore.StaticFiles
open Microsoft.Extensions.DependencyInjection
open Microsoft.Extensions.FileProviders
open Microsoft.Extensions.Hosting
open Microsoft.Extensions.Logging
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

    app.UseResponseCompression() |> ignore

    // Served straight out of the directory the profile mounts, rather than a
    // copy taken at image build. MapStaticAssets, which this used before,
    // resolves assets through a manifest the SDK generates at publish time from
    // wwwroot, so the container held two copies of the corpus and answered from
    // the one the harness cannot touch: replacing a file in the mounted
    // directory never reached a response.
    //
    // UseStaticFiles reads the file per request through the file provider, so
    // what is served follows the mounted directory. Compression stays with the
    // response compression middleware registered above.
    let staticContentTypes = FileExtensionContentTypeProvider()
    staticContentTypes.Mappings[".webp"] <- "image/webp"
    staticContentTypes.Mappings[".woff2"] <- "font/woff2"

    app.UseStaticFiles(
        StaticFileOptions(
            FileProvider = new PhysicalFileProvider("/data/static"),
            RequestPath = PathString "/static",
            ContentTypeProvider = staticContentTypes,
            ServeUnknownFileTypes = false
        )
    )
    |> ignore

    app.UseRouting() |> ignore

    app.UseOxpecker endpoints |> ignore

    app.Run()
    0
