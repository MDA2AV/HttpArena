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
  rating_score : int;
  rating_count : int;
  total : int option;
}

let rating_codec =
  let open Simdjsont.Codec in
  Obj.field (fun score count -> (score, count))
  |> Obj.mem "score" int ~enc:fst
  |> Obj.mem "count" int ~enc:snd
  |> Obj.finish

let item_codec =
  let open Simdjsont.Codec in
  Obj.field (fun id name category price quantity active tags
                 (rating_score, rating_count) total ->
      { id; name; category; price; quantity; active; tags;
        rating_score; rating_count; total })
  |> Obj.mem "id" int ~enc:(fun i -> i.id)
  |> Obj.mem "name" string ~enc:(fun i -> i.name)
  |> Obj.mem "category" string ~enc:(fun i -> i.category)
  |> Obj.mem "price" int ~enc:(fun i -> i.price)
  |> Obj.mem "quantity" int ~enc:(fun i -> i.quantity)
  |> Obj.mem "active" bool ~enc:(fun i -> i.active)
  |> Obj.mem "tags" (list string) ~enc:(fun i -> i.tags)
  |> Obj.mem "rating" rating_codec ~enc:(fun i -> (i.rating_score, i.rating_count))
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

(* ── Endpoint handlers ─────────────────────────────────────────────────── *)

let handle_baseline _params req =
  let sum =
    Hcs.Request.query_int_or ~default:0 req "a"
    + Hcs.Request.query_int_or ~default:0 req "b"
  in
  let body_sum =
    if Hcs.Request.is_post req then
      Option.value ~default:0
        (int_of_string_opt (String.trim (Hcs.Request.body req)))
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

module Pg = Repodb_postgresql

let pool : Pg.connection Repodb.Pool.t option ref = ref None

let make_pool url ~size =
  Repodb.Pool.create
    {
      max_size = size;
      connect =
        (fun () ->
          match Pg.connect url with Ok c -> Ok c | Error e -> Error e);
      close = Pg.close;
      validate = None;
    }

(* Run [f] with a pooled connection. Returns Error on pool/db failure. *)
let with_conn f =
  match !pool with
  | None -> Error "no database"
  | Some p -> (
      match Repodb.Pool.with_connection_blocking p f with
      | Ok (Ok v) -> Ok v
      | Ok (Error e) -> Error e
      | Error e -> Error (Repodb.Pool.error_to_string e))

let row_int row col =
  Repodb.Driver.Value.to_int (Repodb.Driver.row_get_exn row col)

let row_text row col =
  Repodb.Driver.Value.to_string (Repodb.Driver.row_get_exn row col)

let row_bool row col =
  match Repodb.Driver.row_get_exn row col with
  | Repodb.Driver.Value.Bool b -> b
  | Repodb.Driver.Value.Int n -> n <> 0
  | Repodb.Driver.Value.Text s -> s = "t" || s = "true" || s = "1"
  | _ -> false

let pg_item row =
  let tags =
    Simdjsont.Codec.decode_string_exn
      Simdjsont.Codec.(list string) (row_text row "tags")
  in
  { id = row_int row "id";
    name = row_text row "name";
    category = row_text row "category";
    price = row_int row "price";
    quantity = row_int row "quantity";
    active = row_bool row "active";
    tags;
    rating_score = row_int row "rating_score";
    rating_count = row_int row "rating_count";
    total = None }

let item_columns =
  "id, name, category, price, quantity, active, tags, rating_score, rating_count"

let db_error_response () = Hcs.Response.internal_error ()

let handle_async_db req =
  let mn = Hcs.Request.query_int_or ~default:10 req "min" in
  let mx = Hcs.Request.query_int_or ~default:50 req "max" in
  let lim = max 1 (min 50 (Hcs.Request.query_int_or ~default:50 req "limit")) in
  let sql =
    Printf.sprintf "SELECT %s FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3"
      item_columns
  in
  match with_conn (fun c -> Pg.query c sql
      ~params:Repodb.Driver.Value.[| Int mn; Int mx; Int lim |]) with
  | Error _ -> db_error_response ()
  | Ok rows -> respond_items (List.map pg_item rows)

(* ── Framework routing and middleware ─────────────────────────────────── *)

let make_handler static_root =
  let static = Hcs.Plug.Static.server static_root in
  let handle_static params (req : Hcs.Server.request) =
    (* Mount the framework handler under /static. The router captures the
       suffix; Plug.Static owns path validation, filesystem reads and MIME. *)
    let suffix = Hcs.Router.param_or "*" ~default:"" params in
    let response = static { req with target = "/" ^ suffix } in
    (* HCS 0.18.0's server derives Content-Length from the response body.
       Plug.Static also sets it, so remove that redundant header: duplicate
       lengths are rejected by HTTP/2 clients. File bytes remain untouched. *)
    { response with headers = List.filter (fun (name, _) ->
          String.lowercase_ascii name <> "content-length") response.headers }
  in
  let ignore_params f _params req = f req in
  let router = Hcs.Router.compile Hcs.Router.Route.[
      get "/baseline11" handle_baseline;
      post "/baseline11" handle_baseline;
      get "/baseline2" handle_baseline;
      get "/pipeline" (fun _ _ -> Hcs.Response.text "ok");
      get "/json/:count" handle_json |> plug (Hcs.Plug.Compress.create ());
      get "/static/*" handle_static |> plug (Hcs.Plug.Compress.create ());
      post "/echo" (ignore_params handle_echo);
      get "/async-db" (ignore_params handle_async_db);
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

let make_configs ~certs_dir ~port ~h2_port ~h1tls_port ~h2c_port =
  let tls_of alpn =
    match
      Hcs.Tls_config.Server.of_pem
        ~cert_file:(Filename.concat certs_dir "server.crt")
        ~key_file:(Filename.concat certs_dir "server.key")
    with
    | Ok t -> Some (alpn t)
    | Error msg ->
        Printf.eprintf "[arena] TLS load failed (%s): %s\n%!" certs_dir msg;
        None
  in
  let h2_tls = tls_of Hcs.Tls_config.Server.h2_or_http11 in
  let h1_tls = tls_of Hcs.Tls_config.Server.h1_only in
  (* (config, use_ws) *)
  let plain =
    ( Hcs.Server.
        {
          base_config with
          port;
          protocol = Auto_websocket;
        },
      true )
  in
  let h2c =
    ( Hcs.Server.{ base_config with port = h2c_port; protocol = Http2_only },
      false )
  in
  let configs = [ plain; h2c ] in
  let configs =
    match h2_tls with
    | Some tls ->
        ( Hcs.Server.
            { base_config with port = h2_port; protocol = Auto; tls = Some tls },
          false )
        :: configs
    | None -> configs
  in
  let configs =
    match h1_tls with
    | Some tls ->
        ( Hcs.Server.
            {
              base_config with
              port = h1tls_port;
              protocol = Http1_only;
              tls = Some tls;
            },
          false )
        :: configs
    | None -> configs
  in
  configs

(* Spawn [domains] domains; each runs all listeners on SO_REUSEPORT sockets.
   This keeps the total domain count at [domains] regardless of listener count
   (vs. run_parallel-per-port, which would multiply it). *)
let run_all env ~domains ~configs ~static_dir =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let dm = Eio.Stdenv.domain_mgr env in
  let serve_one () =
    Eio.Switch.run @@ fun sw ->
    let static_root =
      Eio.Path.open_dir ~sw Eio.Path.(Eio.Stdenv.fs env / static_dir)
    in
    let handler = make_handler static_root in
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
         if i = 0 then serve_one () else Eio.Domain_manager.run dm serve_one))

(* Use one domain per physical core; fall back to the runtime's CPU count. *)
let physical_core_count () =
  let fallback = Domain.recommended_domain_count () in
  try
    let base = "/sys/devices/system/cpu" in
    let seen = Hashtbl.create 64 in
    Array.iter
      (fun entry ->
        if
          String.length entry > 3
          && String.sub entry 0 3 = "cpu"
          && match entry.[3] with '0' .. '9' -> true | _ -> false
        then
          let path =
            Filename.concat base (entry ^ "/topology/core_cpus_list")
          in
          match In_channel.with_open_bin path In_channel.input_all with
          | siblings -> Hashtbl.replace seen (String.trim siblings) ()
          | exception _ -> ())
      (Sys.readdir base);
    let n = Hashtbl.length seen in
    if n > 0 then n else fallback
  with _ -> fallback

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
  (match Sys.getenv_opt "DATABASE_URL" with
  | Some url when String.length url > 0 ->
      let size =
        match Sys.getenv_opt "DATABASE_MAX_CONN" with
        | Some s -> Option.value ~default:128 (int_of_string_opt s)
        | None -> 128
      in
      pool := Some (make_pool url ~size)
  | _ -> ());
  run_eio @@ fun env ->
  let configs =
    make_configs ~certs_dir:"/certs" ~port:8080 ~h2_port:8443
      ~h1tls_port:8081 ~h2c_port:8082
  in
  run_all env ~domains:(physical_core_count ()) ~configs ~static_dir:"/data/static"
