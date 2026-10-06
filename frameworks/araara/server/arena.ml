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

(* Caqti's PostgreSQL driver waits through Eio, and prepares this query once
   per connection. The pool is local to each HTTP worker domain. *)
let db_item =
  let open Caqti.Template.Row_type in
  let tags = custom
      ~encode:(fun tags -> Ok (Simdjsont.Codec.encode_string
          Simdjsont.Codec.(list string) tags))
      ~decode:(Simdjsont.Codec.decode_string Simdjsont.Codec.(list string))
      string
  in
  product (fun id name category price quantity active tags rating_score rating_count ->
      Ok { id; name; category; price; quantity; active; tags;
           rating_score; rating_count; total = None })
  @@ proj int (fun i -> i.id)
  @@ proj string (fun i -> i.name)
  @@ proj string (fun i -> i.category)
  @@ proj int (fun i -> i.price)
  @@ proj int (fun i -> i.quantity)
  @@ proj bool (fun i -> i.active)
  @@ proj tags (fun i -> i.tags)
  @@ proj int (fun i -> i.rating_score)
  @@ proj int (fun i -> i.rating_count)
  @@ proj_end

let select_items =
  let open Caqti.Templater in
  static T.(t3 int int int -->* db_item)
    "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count \
     FROM items WHERE price BETWEEN ? AND ? LIMIT ?"

let handle_async_db pool req =
  let mn = Hcs.Request.query_int_or ~default:10 req "min" in
  let mx = Hcs.Request.query_int_or ~default:50 req "max" in
  let lim = max 1 (min 50 (Hcs.Request.query_int_or ~default:50 req "limit")) in
  let items = match pool with
    | None -> []
    | Some pool ->
        match Caqti_eio.Pool.use (fun (module Db : Caqti_eio.CONNECTION) ->
            Db.collect_list select_items (mn, mx, lim)) pool with
        | Ok items -> items
        | Error _ -> []
  in
  respond_items items

(* ── Framework routing and middleware ─────────────────────────────────── *)

let make_handler static_root pool =
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
      get "/async-db" (ignore_params (handle_async_db pool));
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
  let serve_one index () =
    Eio.Switch.run @@ fun sw ->
    let pool = Option.map (fun (uri, budget) ->
        (* Divide the supplied connection budget without exceeding it across
           domains. Caqti pools and connections stay on their owning domain. *)
        let size = budget / domains + (if index < budget mod domains then 1 else 0) in
        Caqti_eio_unix.connect_pool ~sw ~stdenv:(env :> Caqti_eio.stdenv)
          ~pool_config:(Caqti.Pool.Config.create ~max_size:size ()) uri
        |> Caqti_eio.or_fail) database
    in
    let static_root =
      Eio.Path.open_dir ~sw Eio.Path.(Eio.Stdenv.fs env / "/data/static")
    in
    let handler = make_handler static_root pool in
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
         if i = 0 then serve_one i ()
         else Eio.Domain_manager.run dm (serve_one i)))

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
        Some (Uri.of_string url, size)
    | _ -> None
  in
  (* The runtime respects CPU affinity, including Docker's --cpuset-cpus. *)
  let domains = Domain.recommended_domain_count () in
  let domains = match database with
    | Some (_, budget) -> min domains budget
    | None -> domains
  in
  run_eio @@ fun env ->
  run_all env ~domains ~configs:(make_configs ()) ~database
