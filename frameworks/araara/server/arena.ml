(* HttpArena benchmark server for HCS.
   https://github.com/MDA2AV/HttpArena

   One process, four listeners:
     8080  plaintext, Auto_websocket  — all H/1.1 endpoints + WebSocket /ws
     8443  TLS, ALPN h2,http/1.1      — /baseline2, /static (baseline-h2, static-h2)
     8081  TLS, ALPN http/1.1 only    — /json (json-tls), /echo (8gbit)
     8082  cleartext Http2_only (h2c) — /baseline2, /json (baseline-h2c, json-h2c)

   See meta.json for the subscribed HttpArena profiles. *)

(* Use the same application APIs in both modes. Only server configuration
   differs; routing, serialization, compression and static serving are not
   replaced by benchmark-specific fast paths. *)
(* ── Dataset and typed JSON codecs ─────────────────────────────────────── *)

type item = {
  id : int;
  name : string;
  category : string;
  price : int;
  quantity : int;
  active : bool;
  tags : string list;
  rating : int * int;
  total : int option;
}

(* Codecs describe shapes, not values: build them once, including the tags
   decoder used for every PostgreSQL row. *)
let tags_codec = Simdjsont.Codec.(list string)

let rating_codec =
  let open Simdjsont.Codec in
  Obj.field (fun score count -> (score, count))
  |> Obj.mem "score" int ~enc:fst
  |> Obj.mem "count" int ~enc:snd
  |> Obj.finish

let item_codec =
  let open Simdjsont.Codec in
  Obj.field (fun id name category price quantity active tags
                 rating total ->
      { id; name; category; price; quantity; active; tags; rating; total })
  |> Obj.mem "id" int ~enc:(fun i -> i.id)
  |> Obj.mem "name" string ~enc:(fun i -> i.name)
  |> Obj.mem "category" string ~enc:(fun i -> i.category)
  |> Obj.mem "price" int ~enc:(fun i -> i.price)
  |> Obj.mem "quantity" int ~enc:(fun i -> i.quantity)
  |> Obj.mem "active" bool ~enc:(fun i -> i.active)
  |> Obj.mem "tags" tags_codec ~enc:(fun i -> i.tags)
  |> Obj.mem "rating" rating_codec ~enc:(fun i -> i.rating)
  |> Obj.opt_mem "total" int ~enc:(fun i -> i.total)
  |> Obj.finish

let items_codec =
  let open Simdjsont.Codec in
  Obj.field (fun items count -> (items, count))
  |> Obj.mem "items" (list item_codec) ~enc:fst
  |> Obj.mem "count" int ~enc:snd
  |> Obj.finish

let dataset : item array ref = ref [||]

let load_dataset path =
  let body = In_channel.with_open_bin path In_channel.input_all in
  match Simdjsont.Codec.decode_string (Simdjsont.Codec.array item_codec) body with
  | Ok items -> items
  | Error message -> failwith ("Invalid HttpArena dataset: " ^ message)

let respond_items items =
  Hcs.Response.json
    (Simdjsont.Codec.encode_string items_codec (items, List.length items))

(* Read HCS's decoded query parameters once when a route needs several values.
   Keep its integer/default semantics, including first-value-wins duplicates. *)
let query_int_or ~default query name =
  match List.assoc_opt name query with
  | Some value -> Option.value ~default (int_of_string_opt value)
  | None -> default

(* ── Small tuned helpers ───────────────────────────────────────────────── *)

let pipeline_response = Hcs.Response.text "ok"

let parse_int_trimmed s =
  let len = String.length s in
  let rec left i =
    if i >= len then 0
    else match String.unsafe_get s i with
      | ' ' | '\t' | '\r' | '\n' -> left (i + 1)
      | _ -> digits 0 i
  and digits acc i =
    if i >= len then acc
    else match String.unsafe_get s i with
      | '0' .. '9' as c -> digits ((acc * 10) + Char.code c - 48) (i + 1)
      | _ -> acc
  in
  left 0

(* ── Endpoint handlers ─────────────────────────────────────────────────── *)

let handle_baseline _params req =
  (* Tuned mode still uses HCS.Request's parsed query API, but parses the
     query-string once instead of rebuilding the assoc list for each lookup. *)
  let query = Hcs.Request.query_params req in
  let sum = query_int_or ~default:0 query "a" + query_int_or ~default:0 query "b" in
  let body_sum =
    if Hcs.Request.is_post req then parse_int_trimmed (Hcs.Request.body req)
    else 0
  in
  Hcs.Response.text (string_of_int (sum + body_sum))

let handle_json params req =
  let count =
    Hcs.Router.param_int_or "count" ~default:0 params
    |> max 0 |> min (Array.length !dataset)
  in
  let m = Hcs.Request.query_int_or ~default:1 req "m" in
  let items = List.init count (fun n ->
      let item = !dataset.(n) in
      { item with total = Some (item.price * item.quantity * m) })
  in
  (* Serialization happens on every request. Compression is a route plug. *)
  respond_items items

let handle_echo req =
  Hcs.Response.make ~headers:[ ("content-type", "application/octet-stream") ]
    (Hcs.Request.body req)

(* ── Postgres-backed async-db endpoint ────────────────────────────────── *)

module Db = Repodb_postgresql
module Db_pool = Repodb.Pool.Make (Db)
module Repo = Repodb.Repo.Make (Db.Driver)

let item_column name ty =
  Repodb.Expr.qualified ~source:"items" ~column:name ty

let price_column = item_column "price" Repodb.Types.int

let items_query =
  let open Repodb in
  Query.from (Schema.table "items")
  |> Query.select Expr.[
      item_column "id" Types.int;
      item_column "name" Types.string;
      item_column "category" Types.string;
      price_column;
      item_column "quantity" Types.int;
      item_column "active" Types.bool;
      item_column "tags" Types.json;
      item_column "rating_score" Types.int;
      item_column "rating_count" Types.int;
    ]

let select_items mn mx lim =
  let open Repodb in
  items_query
  |> Query.where Expr.(between price_column (int mn) (int mx))
  |> Query.limit_expr (Expr.int lim)

let db_item row =
  let open Repodb.Driver in
  { id = row_int row 0;
    name = row_text row 1;
    category = row_text row 2;
    price = row_int row 3;
    quantity = row_int row 4;
    active = row_bool row 5;
    tags = Simdjsont.Codec.decode_string_exn tags_codec (row_text row 6);
    rating = (row_int row 7, row_int row 8);
    total = None }

let handle_async_db database req =
  let query = Hcs.Request.query_params req in
  let mn = query_int_or ~default:10 query "min" in
  let mx = query_int_or ~default:50 query "max" in
  let lim = max 1 (min 50 (query_int_or ~default:50 query "limit")) in
  let items = match database with
    | None -> []
    | Some (pool, slots) ->
        (* Wait in the HTTP fiber before using a system thread. Both connection
           establishment and query execution may block in Repodb/libpq. *)
        Eio.Semaphore.acquire slots;
        let result = Fun.protect ~finally:(fun () -> Eio.Semaphore.release slots)
            (fun () -> Eio_unix.run_in_systhread (fun () ->
                Db_pool.with_connection pool (fun conn ->
                    Repo.all_query conn (select_items mn mx lim) ~decode:db_item)))
        in
        match result with
        | Ok (Ok items) -> items
        | Ok (Error _) | Error _ -> []
  in
  respond_items items

(* ── Framework routing and middleware ─────────────────────────────────── *)

let make_handler static_root database =
  let mime_type path =
    match String.lowercase_ascii (Filename.extension path) with
    | ".html" | ".htm" -> "text/html; charset=utf-8"
    | ".css" -> "text/css; charset=utf-8"
    | ".js" | ".mjs" -> "application/javascript; charset=utf-8"
    | ".json" -> "application/json"
    | ".svg" -> "image/svg+xml"
    | ".webp" -> "image/webp"
    | ".woff2" -> "font/woff2"
    | _ -> "application/octet-stream"
  in
  let accepts_token req token =
    match Hcs.Request.header req "accept-encoding" with
    | None -> false
    | Some value ->
        let token_len = String.length token in
        let value_len = String.length value in
        let rec loop i =
          if i + token_len > value_len then false
          else if String.sub value i token_len = token then true
          else loop (i + 1)
        in
        loop 0
  in
  let has_precompressed_sidecar suffix =
    match String.lowercase_ascii (Filename.extension suffix) with
    | ".css" | ".js" | ".mjs" | ".html" | ".htm" | ".json" | ".svg" -> true
    | _ -> false
  in
  let handle_static params req =
    (* Tuned static path: HttpArena permits selecting pre-compressed .br/.gz
       sidecars from the mounted static directory when a framework has no
       documented API for this. Bytes are read from disk per request, so file
       replacement is still reflected by the next response. *)
    let suffix = Hcs.Router.param_or "*" ~default:"" params in
    if suffix = "" || String.contains suffix '\x00'
       || String.starts_with ~prefix:"." suffix
       || String.contains suffix '/'
    then Hcs.Response.not_found ()
    else
      let file, encoding =
        if has_precompressed_sidecar suffix && accepts_token req "br" then
          (suffix ^ ".br", Some "br")
        else if has_precompressed_sidecar suffix && accepts_token req "gzip" then
          (suffix ^ ".gz", Some "gzip")
        else (suffix, None)
      in
      try
        let body = Eio.Path.load Eio.Path.(static_root / file) in
        let headers =
          ("Content-Type", mime_type suffix) ::
          ("Vary", "Accept-Encoding") ::
          match encoding with
          | None -> []
          | Some enc -> [ ("Content-Encoding", enc) ]
        in
        Hcs.Response.make ~headers body
      with _ -> Hcs.Response.not_found ()
  in
  let ignore_params f _params req = f req in
  let router = Hcs.Router.compile Hcs.Router.Route.[
      get "/baseline11" handle_baseline;
      post "/baseline11" handle_baseline;
      get "/baseline2" handle_baseline;
      get "/pipeline" (fun _ _ -> pipeline_response);
      get "/json/:count" handle_json |> plug (Hcs.Plug.Compress.create ());
      get "/static/*" handle_static;
      post "/echo" (ignore_params handle_echo);
      get "/async-db" (ignore_params (handle_async_db database));
    ]
  in
  Hcs.Endpoint.to_handler
    (Hcs.Endpoint.router (Hcs.Endpoint.create Hcs.Endpoint.default_config) router)

let ws_handler (ws : Hcs.Websocket.t) =
  let rec loop () =
    match Hcs.Websocket.recv_message ws with
    | Ok (Hcs.Websocket.Opcode.Text, msg) -> (
        match Hcs.Websocket.send_text ws msg with
        | Ok () -> loop ()
        | Error _ -> ())
    | Ok (Hcs.Websocket.Opcode.Binary, msg) -> (
        match Hcs.Websocket.send_binary ws msg with
        | Ok () -> loop ()
        | Error _ -> ())
    | Ok _ -> loop ()
    | Error _ -> ()
  in
  loop ()

(* ── Listener setup ─────────────────────────────────────────────────────── *)

let is_standard_mode () = Sys.getenv_opt "HCS_ARENA_MODE" = Some "standard"

let base_config =
  let open Hcs.Server in
  let config = { default_config with reuse_port = true } in
  if is_standard_mode () then config
  else { config with max_connections = 200000 }

let make_configs () =
  let tls = match Hcs.Tls_config.Server.of_pem
      ~cert_file:"/certs/server.crt" ~key_file:"/certs/server.key" with
    | Ok tls -> tls
    | Error message -> failwith ("HttpArena TLS certificates: " ^ message)
  in
  let open Hcs.Server in
  [ ({ base_config with port = 8080; protocol = Auto_websocket }, true);
    ({ base_config with port = 8082; protocol = Http2_only }, false);
    ({ base_config with port = 8443; protocol = Auto;
        tls = Some (Hcs.Tls_config.Server.h2_or_http11 tls) }, false);
    ({ base_config with port = 8081; protocol = Http1_only;
        tls = Some (Hcs.Tls_config.Server.h1_only tls) }, false) ]

(* Spawn [domains] domains; each runs all listeners on SO_REUSEPORT sockets.
   This keeps the total domain count at [domains] regardless of listener count
   (vs. run_parallel-per-port, which would multiply it). *)
let run_all env ~domains ~configs ~database =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let dm = Eio.Stdenv.domain_mgr env in
  let serve_one () =
    Eio.Switch.run @@ fun sw ->
    let static_root =
      Eio.Path.open_dir ~sw Eio.Path.(Eio.Stdenv.fs env / "/data/static")
    in
    let handler = make_handler static_root database in
    Eio.Fiber.all
      (List.map
         (fun (cfg, use_ws) () ->
           if use_ws then
             Hcs.Server.run ~sw ~net ~clock ~config:cfg ~ws_handler handler
           else Hcs.Server.run ~sw ~net ~clock ~config:cfg handler)
         configs)
  in
  Eio.Fiber.all
    (List.init domains (fun i () ->
         if i = 0 then serve_one ()
         else Eio.Domain_manager.run dm serve_one))

(* Prefer Eio's io_uring backend, but fall back to epoll if io_uring is
   unavailable (e.g. denied by an enforcing SELinux policy inside a container,
   which surfaces as EACCES from io_uring_queue_init). Eio's own auto-fallback
   doesn't cover that error, so handle it here. *)
let run_eio fn =
  try Eio_main.run fn
  with Unix.Unix_error (Unix.EACCES, "io_uring_queue_init", _) ->
    Printf.eprintf "[arena] io_uring unavailable — falling back to epoll\n%!";
    Eio_posix.run fn

let () =
  dataset := load_dataset "/data/dataset.json";
  let database = match Sys.getenv_opt "DATABASE_URL" with
    | Some url when url <> "" ->
        let size = match Sys.getenv_opt "DATABASE_MAX_CONN" with
          | Some s -> max 1 (Option.value ~default:256 (int_of_string_opt s))
          | None -> 256
        in
        Some (Db_pool.create ~max_size:size ~conninfo:url (), Eio.Semaphore.make size)
    | _ -> None
  in
  (* The runtime respects CPU affinity, including Docker's --cpuset-cpus. *)
  let domains = Domain.recommended_domain_count () in
  run_eio @@ fun env ->
  run_all env ~domains ~configs:(make_configs ()) ~database
