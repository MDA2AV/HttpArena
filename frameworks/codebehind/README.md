# codebehind

[CodeBehind](https://github.com/elanatframework/CodeBehind) by Elanat: an MVC framework that runs as ASP.NET Core middleware. Views are `.aspx` files in Razor (or standard `<% %>`) syntax, compiled into one assembly with Roslyn when the app starts. Controllers can be selected from the route.

## Stack

- **Language:** C# / .NET 10
- **Framework:** CodeBehind 4.8.1
- **Engine:** Kestrel
- **Database:** Npgsql with default settings, `NpgsqlDataSource` registered through `Npgsql.DependencyInjection`, pool sized from `DATABASE_MAX_CONN`
- **Build:** framework-dependent publish on `mcr.microsoft.com/dotnet/aspnet:10.0`, plus `libmsquic` for HTTP/3. CodeBehind compiles the views against the shared ASP.NET Core assemblies at startup, so it needs the ASP.NET runtime image rather than a self-contained build.

## Endpoints

Every endpoint except `/static` is a CodeBehind route controller in `Controllers/`.

| Endpoint | Method | Controller | Description |
|---|---|---|---|
| `/baseline11` | GET, POST | `Baseline11Controller` | `a + b` from the query, plus the body on POST |
| `/baseline2` | GET | `Baseline2Controller` | `a + b` (HTTP/2, HTTP/3) |
| `/pipeline` | GET | `PipelineController` | `ok` |
| `/delay/{ms}` | GET | `DelayController` | Waits `ms` milliseconds, answers `ms` |
| `/json/{count}?m=` | GET | `JsonController` | First `count` dataset items with `total = price * quantity * m` |
| `/async-db?min=&max=&limit=` | GET | `Async__DbController` | Postgres price range query |
| `/echo` | POST | `EchoController` | The request body, unchanged |
| `/fortunes` | GET | `FortunesController` | Renders `wwwroot/fortunes.aspx` |
| `/static/*` | GET | – | ASP.NET Core `UseStaticFiles` over `/data/static` |

Listeners: HTTP/1.1 on 8080, HTTP/1.1 + TLS on 8081, h2c on 8082, HTTP/1.1 + HTTP/2 + HTTP/3 on 8443. Response compression is ASP.NET Core's middleware with its defaults (so it is off over TLS).

## How CodeBehind is used

- **Route mode.** `UseCodeBehindRouteNextNotFoundAsync()` runs the controller whose class name matches the first path segment, and the rest of the path arrives as `Segment` (`/json/5` gives `Segment.GetValue(0) == "5"`). Requests that match no controller continue to the 404 at the end of the pipeline.
- **Options.** `code_behind/options.ini` sets two documented options: `ignore_suffix_controller=Controller`, so `JsonController` answers `/json`, and `put_two_underlines_equal_to_dash_for_controller=true`, so `Async__DbController` answers `/async-db`. CodeBehind fills in the remaining defaults at startup.
- **Responses.** Controllers write their body with `Write()` and skip the view with `IgnoreAll()`. CodeBehind has no API for status codes, content types or JSON, so `HttpArenaController` sets those on the ASP.NET Core `HttpContext` and serializes with System.Text.Json.
- **Fortunes** is the MVC path: the controller loads the rows and calls `View("/fortunes.aspx", model)`, and the template uses `@model` with Razor syntax. `@break` keeps the page from being requested by its own path.

## Deviations, and why the entry is marked tuned

- **No auto-escaping.** CodeBehind writes `@expression` output as-is and has no encode helper, so the template calls `System.Net.WebUtility.HtmlEncode` itself. Standard mode for fortunes asks for an engine that escapes by default.
- **Echo bypasses CodeBehind's output.** `Write()` only takes strings, and the echo body is arbitrary bytes, so `EchoController` streams the request body into `HttpContext.Response.Body` directly.
- **Completeness:** routing and response are declared `false`. The router picks a class by path segment but does not match methods or name parameters, so every controller checks the method itself. The response is assembled on `HttpContext` rather than declared.

## Workarounds for CodeBehind 4.8.1

- **Async controllers need route mode.** In the default view-first mode (the `.aspx` names its controller) the generated code calls an async `PageLoad` without awaiting it, even with `@controller await ...`, so the view renders before the data has loaded. Route mode detects a `Task`-returning `PageLoad` and awaits it.
- **Controller namespace.** Route mode builds a variable name from the controller's namespace without replacing the dots, so the controllers live in the single-segment `HttpArena` namespace.
- **Exceptions.** When a controller throws, CodeBehind logs to the console and answers 200 with an empty body. The database controllers turn `DbException` into a 500 themselves, and bad input is rejected with a 400 before anything can throw.

## Settings

Logging is the only setting changed from the defaults: `ClearProviders()` removes the ASP.NET Core logging providers. CodeBehind itself only writes to the console when a controller throws.

## Generated files

At startup CodeBehind writes its options, the generated view class and logs to `code_behind/` in the working directory, and a WebForms script to `wwwroot/script/`. Apart from `options.ini`, both are git- and docker-ignored.
