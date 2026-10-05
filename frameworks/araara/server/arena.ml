(* HttpArena benchmark server for HCS.
   https://github.com/MDA2AV/HttpArena

   One process, four listeners:
     8080  plaintext, Auto_websocket  — all H/1.1 endpoints + WebSocket /ws
     8443  TLS, ALPN h2,http/1.1      — /baseline2, /static (baseline-h2, static-h2)
     8081  TLS, ALPN http/1.1 only    — /json (json-tls), /echo (8gbit)
     8082  cleartext Http2_only (h2c) — /baseline2, /json (baseline-h2c, json-h2c)

   See arena/README.md for the endpoint contract and scope notes. *)

(* Use the same application APIs in both modes. Only server configuration
   differs; routing, serialization, compression and static serving are not
   replaced by benchmark-specific fast paths. *)
module Json = Simdjsont.Json

let html_ct = "text/html; charset=utf-8"

let respond ?(status = `OK) ~ct ?(extra = []) body =
  Hcs.Response.make ~status ~headers:(("content-type", ct) :: extra) body

let not_found () = Hcs.Response.not_found ()
let respond_json ?(status = `OK) value =
  Hcs.Response.json ~status (Json.to_string value)

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

let handle_upload req =
  Hcs.Response.text (string_of_int (Hcs.Request.body_length req))

let handle_echo req =
  respond ~ct:"application/octet-stream" (Hcs.Request.body req)

(* ── Postgres-backed endpoints (async-db, crud, fortunes) ───────────────── *)

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

(* ── CRUD: cache-aside REST API over the items table ────────────────────── *)

let cache : (int, item * float) Hashtbl.t = Hashtbl.create 4096
let cache_mutex = Mutex.create ()
let cache_ttl = 0.2 (* 200 ms *)

let cache_get id =
  Mutex.lock cache_mutex;
  let r =
    match Hashtbl.find_opt cache id with
    | Some (item, exp) when Unix.gettimeofday () < exp -> Some item
    | _ -> None
  in
  Mutex.unlock cache_mutex;
  r

let cache_put id item =
  Mutex.lock cache_mutex;
  Hashtbl.replace cache id (item, Unix.gettimeofday () +. cache_ttl);
  Mutex.unlock cache_mutex

let cache_del id =
  Mutex.lock cache_mutex;
  Hashtbl.remove cache id;
  Mutex.unlock cache_mutex

let fetch_item id =
  let sql = Printf.sprintf "SELECT %s FROM items WHERE id = $1" item_columns in
  match
    with_conn (fun c -> Pg.query c sql ~params:[| Repodb.Driver.Value.Int id |])
  with
  | Error _ -> Error `Db
  | Ok [] -> Ok None
  | Ok (row :: _) ->
      Ok (Some (pg_item row))

let item_response ?(extra = []) item =
  Hcs.Response.json (Simdjsont.Codec.encode_string item_codec item)
  |> Hcs.Response.with_headers extra

let handle_crud_get id =
  match cache_get id with
  | Some item -> item_response ~extra:[ ("x-cache", "HIT") ] item
  | None -> (
      match fetch_item id with
      | Error _ -> db_error_response ()
      | Ok None -> not_found ()
      | Ok (Some item) ->
          cache_put id item;
          item_response ~extra:[ ("x-cache", "MISS") ] item)

let handle_crud_list req =
  let category = Hcs.Request.query_or ~default:"" req "category" in
  let page = max 1 (Hcs.Request.query_int_or ~default:1 req "page") in
  let limit = max 1 (Hcs.Request.query_int_or ~default:10 req "limit") in
  let offset = (page - 1) * limit in
  let list_sql =
    Printf.sprintf
      "SELECT %s FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3"
      item_columns
  in
  let count_sql = "SELECT COUNT(*) AS n FROM items WHERE category = $1" in
  match
    with_conn (fun c ->
        match
          Pg.query c list_sql
            ~params:
              [|
                Repodb.Driver.Value.Text category;
                Repodb.Driver.Value.Int limit;
                Repodb.Driver.Value.Int offset;
              |]
        with
        | Error e -> Error e
        | Ok rows -> (
            match
              Pg.query c count_sql
                ~params:[| Repodb.Driver.Value.Text category |]
            with
            | Error e -> Error e
            | Ok crows ->
                let total =
                  match crows with [ r ] -> row_int r "n" | _ -> 0
                in
                Ok (rows, total)))
  with
  | Error _ -> db_error_response ()
  | Ok (rows, total) ->
      respond_json Json.(Object [
          "items", Array (List.map (fun row ->
              Simdjsont.Codec.to_json item_codec (pg_item row)) rows);
          "total", Int (Int64.of_int total);
          "page", Int (Int64.of_int page) ])

let json_member j k =
  match j with Json.Object fields -> List.assoc_opt k fields | _ -> None

let json_member_int j k default =
  match json_member j k with
  | Some (Json.Int n) -> Int64.to_int n
  | _ -> default

let json_member_str j k default =
  match json_member j k with Some (Json.String s) -> s | _ -> default

let handle_crud_create ~body =
  match Simdjsont.Codec.decode_string Simdjsont.Codec.value body with
  | Error _ -> Hcs.Response.bad_request ()
  | Ok j ->
      let id = json_member_int j "id" 0 in
      let name = json_member_str j "name" "" in
      let category = json_member_str j "category" "" in
      let price = json_member_int j "price" 0 in
      let quantity = json_member_int j "quantity" 0 in
      let sql =
        "INSERT INTO items (id, name, category, price, quantity, active, tags, \
         rating_score, rating_count) VALUES ($1,$2,$3,$4,$5,true,'[]',0,0) ON \
         CONFLICT (id) DO UPDATE SET name=EXCLUDED.name, \
         category=EXCLUDED.category, price=EXCLUDED.price, \
         quantity=EXCLUDED.quantity"
      in
      (match
         with_conn (fun c ->
             Pg.exec c sql
               ~params:
                 [|
                   Repodb.Driver.Value.Int id;
                   Repodb.Driver.Value.Text name;
                   Repodb.Driver.Value.Text category;
                   Repodb.Driver.Value.Int price;
                   Repodb.Driver.Value.Int quantity;
                 |])
       with
      | Error _ -> ()
      | Ok () -> cache_del id);
      respond_json ~status:`Created Json.(Object [ "status", String "created" ])

let handle_crud_update id ~body =
  match Simdjsont.Codec.decode_string Simdjsont.Codec.value body with
  | Error _ -> Hcs.Response.bad_request ()
  | Ok j ->
      let name = json_member_str j "name" "" in
      let category = json_member_str j "category" "" in
      let price = json_member_int j "price" 0 in
      let quantity = json_member_int j "quantity" 0 in
      let sql =
        "UPDATE items SET name=$2, category=$3, price=$4, quantity=$5 WHERE \
         id=$1"
      in
      (match
         with_conn (fun c ->
             Pg.exec c sql
               ~params:
                 [|
                   Repodb.Driver.Value.Int id;
                   Repodb.Driver.Value.Text name;
                   Repodb.Driver.Value.Text category;
                   Repodb.Driver.Value.Int price;
                   Repodb.Driver.Value.Int quantity;
                 |])
       with
      | Error _ -> ()
      | Ok () -> cache_del id);
      respond_json Json.(Object [ "status", String "updated" ])

(* ── Fortunes: DB rows + runtime row, sorted by message, HTML table ─────── *)

let html_escape buf s =
  String.iter
    (function
      | '&' -> Buffer.add_string buf "&amp;"
      | '<' -> Buffer.add_string buf "&lt;"
      | '>' -> Buffer.add_string buf "&gt;"
      | '"' -> Buffer.add_string buf "&quot;"
      | '\'' -> Buffer.add_string buf "&#39;"
      | c -> Buffer.add_char buf c)
    s

let handle_fortunes () =
  match
    with_conn (fun c ->
        Pg.query c "SELECT id, message FROM fortune" ~params:[||])
  with
  | Error _ -> db_error_response ()
  | Ok rows ->
      let fortunes =
        List.map (fun r -> (row_int r "id", row_text r "message")) rows
      in
      let fortunes =
        (0, "Additional fortune added at request time.") :: fortunes
      in
      let fortunes =
        List.sort (fun (_, a) (_, b) -> String.compare a b) fortunes
      in
      let buf = Buffer.create 16384 in
      Buffer.add_string buf
        "<!DOCTYPE \
         html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>";
      List.iter
        (fun (id, msg) ->
          Buffer.add_string buf "<tr><td>";
          Buffer.add_string buf (string_of_int id);
          Buffer.add_string buf "</td><td>";
          html_escape buf msg;
          Buffer.add_string buf "</td></tr>")
        fortunes;
      Buffer.add_string buf "</table></body></html>";
      respond ~ct:html_ct (Buffer.contents buf)

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
  let with_id f params req =
    match Hcs.Router.param_int "id" params with
    | None -> Hcs.Response.not_found ()
    | Some id -> f id req
  in
  let router = Hcs.Router.compile Hcs.Router.Route.[
      get "/baseline11" handle_baseline;
      post "/baseline11" handle_baseline;
      get "/baseline2" handle_baseline;
      get "/pipeline" (fun _ _ -> Hcs.Response.text "ok");
      get "/json/:count" handle_json |> plug (Hcs.Plug.Compress.create ());
      get "/static/*" handle_static |> plug (Hcs.Plug.Compress.create ());
      post "/echo" (ignore_params handle_echo);
      post "/upload" (ignore_params handle_upload);
      get "/async-db" (ignore_params handle_async_db);
      get "/fortunes" (fun _ _ -> handle_fortunes ());
      get "/crud/items" (ignore_params handle_crud_list);
      post "/crud/items" (ignore_params (fun req ->
          handle_crud_create ~body:(Hcs.Request.body req)));
      get "/crud/items/:id" (with_id (fun id _ -> handle_crud_get id));
      put "/crud/items/:id" (with_id (fun id req ->
          handle_crud_update id ~body:(Hcs.Request.body req)));
      post "/crud/items/:id" (with_id (fun id req ->
          handle_crud_update id ~body:(Hcs.Request.body req)));
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

(* GC tuning. Profiling at the physical-core domain count showed the dominant
   remaining cost is major-GC marking/sweeping of per-request allocations that
   survive a minor collection (always some in flight under load → promoted). A
   larger minor heap lets more die young; a higher space_overhead runs the major
   collector less often. Both are env-tunable for experimentation. *)
let gc_tuning () =
  let env name default =
    match Sys.getenv_opt name with
    | Some s -> (
        match int_of_string_opt s with Some n -> n | None -> default)
    | None -> default
  in
  Hcs.Server.Gc_tune.
    {
      minor_heap_size = env "HCS_MINOR_HEAP_MB" 128 * 1024 * 1024;
      major_heap_increment = 64 * 1024 * 1024;
      space_overhead = env "HCS_SPACE_OVERHEAD" 400;
      max_overhead = 1000;
    }

let is_standard_mode () = Sys.getenv_opt "HCS_ARENA_MODE" = Some "standard"

let base_config =
  let open Hcs.Server in
  if is_standard_mode () then { default_config with reuse_port = true }
  else
    {
      default_config with
      max_connections = 200000;
      reuse_port = true;
      (* Keep the default whole-body buffering: /echo must return the bytes,
         including bodies larger than the retired upload profile's 256 KiB
         buffering cap. That cap discards bytes instead of retaining them. *)
      (* No GC tuning by default: the aggressive tuning (large minor heap + high
         space_overhead) was tuned for the old allocation-heavy ocaml-h1/h2
         server; with the lean http.* codec it cost 2-3.5x RSS for ~2-8% rps, so
         stock OCaml GC is the better balance. Opt back in with HCS_GC_TUNE=on. *)
      gc_tuning =
        (if Sys.getenv_opt "HCS_GC_TUNE" = Some "on" then Some (gc_tuning ())
         else None);
    }

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
          max_body_size = Some 26_214_400L (* 25 MiB for /upload *);
        },
      true )
  in
  (* depth 1 = inline: the h2 library multiplexes streams itself. A higher
     depth blocks the handler on the token pool once streams-per-connection
     exceeds it, deadlocking the read loop. *)
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

(* ── CLI ────────────────────────────────────────────────────────────────── *)

(* Default domain count = PHYSICAL cores, not logical CPUs.
   [Domain.recommended_domain_count ()] returns logical CPUs (= SMT threads).
   Oversubscribing one domain per hyperthread is actively harmful for an
   allocation-heavy server: every minor GC is a stop-the-world rendezvous across
   ALL domains, so more domains means more frequent and more expensive STW
   barriers. Profiling showed ~30% of CPU lost to STW spin at 32 domains on a
   16-core/32-thread part; dropping to 16 domains (one per physical core) erased
   it and raised throughput ~13-15% across H1 and H2.
   We count unique [core_cpus_list] topology entries (Linux); each physical
   core's sibling threads share one, so the unique count is the physical-core
   count. Fall back to the logical count where the topology isn't readable. *)
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

let command =
  Climate.Command.singleton ~doc:"HttpArena benchmark server (HCS)"
  @@
  let open Climate.Arg_parser in
  let+ domains =
    named_with_default [ "d"; "domains"; "cpus" ] int
      ~default:(physical_core_count ())
      ~doc:"Number of server domains (default: physical core count)"
  and+ dataset_path =
    named_with_default [ "dataset" ] string ~default:"/data/dataset.json"
      ~doc:"Path to dataset.json"
  and+ static_dir =
    named_with_default [ "static-dir" ] string ~default:"/data/static"
      ~doc:"Static files directory"
  and+ certs_dir =
    named_with_default [ "certs-dir" ] string ~default:"/certs"
      ~doc:"TLS certificate directory (server.crt/server.key)"
  and+ port =
    named_with_default [ "p"; "port" ] int ~default:8080
      ~doc:"Plaintext H/1.1+h2c+WebSocket port (default: 8080)"
  and+ h2_port =
    named_with_default [ "h2-port" ] int ~default:8443
      ~doc:"HTTP/2 over TLS port (default: 8443)"
  and+ h1tls_port =
    named_with_default [ "h1tls-port" ] int ~default:8081
      ~doc:"HTTP/1.1 over TLS port (default: 8081)"
  and+ h2c_port =
    named_with_default [ "h2c-port" ] int ~default:8082
      ~doc:"HTTP/2 cleartext (prior-knowledge) port (default: 8082)"
  in
  fun () ->
    dataset := load_dataset dataset_path;
    (match Sys.getenv_opt "DATABASE_URL" with
    | Some url when String.length url > 0 ->
        let size =
          (* Decoupled from domain count: DB-bound profiles (async-db, crud) are
             limited by pool concurrency, not CPU, so the pool must not shrink
             when we drop to the physical-core domain count. 128 matched the old
             32-domain pool and stays within the bench Postgres limit. *)
          match Sys.getenv_opt "DATABASE_MAX_CONN" with
          | Some s -> (
              match int_of_string_opt s with Some n -> n | None -> 128)
          | None -> 128
        in
        pool := Some (make_pool url ~size)
    | _ -> pool := None);
    Printf.printf
      "[arena] HCS HttpArena server: %d domains, dataset=%d items, static=%s, db=%b\n%!"
      domains (Array.length !dataset) static_dir (!pool <> None);
    Printf.printf
      "[arena] listeners: 8080 (h1/h2c/ws) 8443 (h2 TLS) 8081 (h1 TLS) 8082 \
       (h2c)\n\
       %!";
    run_eio @@ fun env ->
    let configs =
      make_configs ~certs_dir ~port ~h2_port ~h1tls_port ~h2c_port
    in
    run_all env ~domains ~configs ~static_dir

let () = Climate.Command.run command ()
