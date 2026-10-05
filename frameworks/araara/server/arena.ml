(* HttpArena benchmark server for HCS.
   https://github.com/MDA2AV/HttpArena

   One process, four listeners:
     8080  plaintext, Auto_websocket  — all H/1.1 endpoints + WebSocket /ws
     8443  TLS, ALPN h2,http/1.1      — /baseline2, /static (baseline-h2, static-h2)
     8081  TLS, ALPN http/1.1 only    — /json (json-tls), /echo (8gbit)
     8082  cleartext Http2_only (h2c) — /baseline2, /json (baseline-h2c, json-h2c)

   See arena/README.md for the endpoint contract and scope notes. *)

let server_name = "hcs"
let plaintext_ct = "text/plain"
let json_ct = "application/json"
let html_ct = "text/html; charset=utf-8"

(* ── Dataset (loaded once at boot) ──────────────────────────────────────── *)

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
}

let dataset : item array ref = ref [||]

let load_dataset path =
  match Yojson.Safe.from_file path with
  | exception _ -> [||]
  | json ->
      let open Yojson.Safe.Util in
      json |> to_list
      |> List.map (fun j ->
          {
            id = j |> member "id" |> to_int;
            name = j |> member "name" |> to_string;
            category = j |> member "category" |> to_string;
            price = j |> member "price" |> to_int;
            quantity = j |> member "quantity" |> to_int;
            active = j |> member "active" |> to_bool;
            tags = j |> member "tags" |> to_list |> List.map to_string;
            rating_score = j |> member "rating" |> member "score" |> to_int;
            rating_count = j |> member "rating" |> member "count" |> to_int;
          })
      |> Array.of_list

(* ── JSON helpers (plain Buffer, manual construction) ───────────────────── *)

let json_escape buf s =
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s

let add_str buf s =
  Buffer.add_char buf '"';
  json_escape buf s;
  Buffer.add_char buf '"'

(* {"id":..,"name":..,...,"tags":[..],"rating":{"score":..,"count":..},"total":T}
   [total] is included only when [total] is Some _. *)
let add_item_json buf (it : item) ~total =
  Buffer.add_string buf "{\"id\":";
  Buffer.add_string buf (string_of_int it.id);
  Buffer.add_string buf ",\"name\":";
  add_str buf it.name;
  Buffer.add_string buf ",\"category\":";
  add_str buf it.category;
  Buffer.add_string buf ",\"price\":";
  Buffer.add_string buf (string_of_int it.price);
  Buffer.add_string buf ",\"quantity\":";
  Buffer.add_string buf (string_of_int it.quantity);
  Buffer.add_string buf ",\"active\":";
  Buffer.add_string buf (if it.active then "true" else "false");
  Buffer.add_string buf ",\"tags\":[";
  List.iteri
    (fun i t ->
      if i > 0 then Buffer.add_char buf ',';
      add_str buf t)
    it.tags;
  Buffer.add_string buf "],\"rating\":{\"score\":";
  Buffer.add_string buf (string_of_int it.rating_score);
  Buffer.add_string buf ",\"count\":";
  Buffer.add_string buf (string_of_int it.rating_count);
  Buffer.add_char buf '}';
  (match total with
  | Some t ->
      Buffer.add_string buf ",\"total\":";
      Buffer.add_string buf (string_of_int t)
  | None -> ());
  Buffer.add_char buf '}'

(* ── Query / path parsing ───────────────────────────────────────────────── *)

let find_param query name =
  query |> String.split_on_char '&'
  |> List.find_map (fun part ->
      match String.index_opt part '=' with
      | None -> if part = name then Some "" else None
      | Some i ->
          let k = String.sub part 0 i in
          if k = name then
            Some (String.sub part (i + 1) (String.length part - i - 1))
          else None)

let int_param query name default =
  match Option.bind (find_param query name) int_of_string_opt with
  | Some n -> n
  | None -> default

(* ── Allocation-free target scanning (hot paths) ────────────────────────── *)

let is_digit c = c >= '0' && c <= '9'

(* Parse a (possibly signed) integer from s[off, lim), ignoring trailing
   non-digits. No allocation. *)
let parse_int_sub s off lim =
  let i = ref off and neg = ref false in
  if !i < lim && s.[!i] = '-' then (
    neg := true;
    incr i);
  let n = ref 0 in
  while !i < lim && is_digit s.[!i] do
    n := (!n * 10) + (Char.code s.[!i] - Char.code '0');
    incr i
  done;
  if !neg then - !n else !n

let parse_int_trimmed s =
  let len = String.length s in
  let i = ref 0 in
  let ws c = c = ' ' || c = '\t' || c = '\n' || c = '\r' in
  while !i < len && ws s.[!i] do
    incr i
  done;
  let lim = ref len in
  while !lim > !i && ws s.[!lim - 1] do
    decr lim
  done;
  parse_int_sub s !i !lim

(* Sum the integer values of the "a" and "b" query params in [target], scanning
   the string once with no intermediate allocation (à la fasthttp's arg access). *)
let baseline_query_sum target =
  let len = String.length target in
  let i =
    ref (match String.index_opt target '?' with Some q -> q + 1 | None -> len)
  in
  let sum = ref 0 in
  while !i < len do
    let ks = !i in
    while !i < len && target.[!i] <> '=' && target.[!i] <> '&' do
      incr i
    done;
    if !i < len && target.[!i] = '=' then begin
      let ke = !i in
      incr i;
      let vs = !i in
      while !i < len && target.[!i] <> '&' do
        incr i
      done;
      if ke - ks = 1 && (target.[ks] = 'a' || target.[ks] = 'b') then
        sum := !sum + parse_int_sub target vs !i
    end;
    if !i < len && target.[!i] = '&' then incr i
  done;
  !sum

(* Length of the path portion of [target] (up to '?'), no allocation. *)
let path_len target =
  let len = String.length target in
  let rec go i = if i >= len || target.[i] = '?' then i else go (i + 1) in
  go 0

(* The path portion of [target] (length [plen]) equals [lit], no allocation. *)
let path_eq target plen lit =
  String.length lit = plen
  &&
  let rec go i = i = plen || (target.[i] = lit.[i] && go (i + 1)) in
  go 0

(* ── Responses ──────────────────────────────────────────────────────────── *)

let respond ?(status = `OK) ~ct ?(extra = []) body =
  Hcs.Server.respond ~status
    ~headers:(("content-type", ct) :: ("server", server_name) :: extra)
    body

(* Cstruct (bigarray) body — emitted by the server zero-copy (by reference), so
   a shared in-memory file is never copied per response, even under HTTP/2
   stream fan-out. *)
let respond_cstruct ?(status = `OK) ~ct ?(extra = []) cs =
  Hcs.Response.cstruct ~status
    ~headers:(("content-type", ct) :: ("server", server_name) :: extra)
    cs

let not_found () = respond ~status:`Not_found ~ct:plaintext_ct "Not Found"

(* Header lists allocated once and reused, so the hot paths don't rebuild them
   per request. *)
let plaintext_headers =
  [ ("content-type", plaintext_ct); ("server", server_name) ]

let json_headers = [ ("content-type", json_ct); ("server", server_name) ]
let respond_plaintext body = Hcs.Server.respond ~headers:plaintext_headers body
let respond_json body = Hcs.Server.respond ~headers:json_headers body

(* /pipeline always returns the same bytes — serve a fully pre-serialized
   response (headers + body cached) instead of rebuilding it each request. *)
let pipeline_resp =
  Hcs.Server.Prebuilt.create ~status:`OK ~headers:plaintext_headers "ok"

(* True if the Accept-Encoding header lists gzip. *)
let accepts_gzip (req : Hcs.Server.request) =
  match Hcs.Request.header req "accept-encoding" with
  | None -> false
  | Some v ->
      let v = String.lowercase_ascii v in
      let len = String.length v in
      let rec scan i =
        i + 4 <= len && (String.sub v i 4 = "gzip" || scan (i + 1))
      in
      scan 0

let gzip_headers = [ ("content-encoding", "gzip"); ("vary", "Accept-Encoding") ]

(* ── Baseline: sum a+b (+ integer body on POST) ─────────────────────────── *)

let handle_baseline ~target ~body =
  let sum = baseline_query_sum target in
  let sum =
    if String.length body = 0 then sum else sum + parse_int_trimmed body
  in
  respond_plaintext (string_of_int sum)

(* ── JSON: first {count} dataset items, each + total = price*quantity*m ──── *)

let handle_json ~req ~count_str ~query =
  let count =
    match int_of_string_opt count_str with
    | Some n -> max 0 (min n (Array.length !dataset))
    | None -> 0
  in
  let m = int_param query "m" 1 in
  let buf = Buffer.create ((count * 160) + 32) in
  Buffer.add_string buf "{\"items\":[";
  for i = 0 to count - 1 do
    if i > 0 then Buffer.add_char buf ',';
    let it = !dataset.(i) in
    add_item_json buf it ~total:(Some (it.price * it.quantity * m))
  done;
  Buffer.add_string buf "],\"count\":";
  Buffer.add_string buf (string_of_int count);
  Buffer.add_char buf '}';
  let body = Buffer.contents buf in
  (* json-comp: body is generated per request, so compress inline when accepted. *)
  if accepts_gzip req && String.length body >= 256 then
    let z = Hcs.Plug.Compress.gzip_compress ~level:6 body in
    respond ~ct:json_ct ~extra:gzip_headers z
  else respond_json body

(* ── Static files (loaded into memory at boot) ──────────────────────────── *)

(* In-memory static cache (like go-fasthttp's FS{Compress:true}): each file is
   loaded once at boot with a precomputed gzip variant for compressible types. *)
(* bodies are held as Cstruct (bigarray) so the server emits them zero-copy *)
type static_entry = { raw : Cstruct.t; gzip : Cstruct.t option; ctype : string }

let static_table : (string, static_entry) Hashtbl.t = Hashtbl.create 64

let compressible_ctype = function
  | "text/css" | "application/javascript" | "text/html" | "image/svg+xml"
  | "application/json" ->
      true
  | _ ->
      false (* webp/woff2/png are already compressed — gzip wastes CPU/space *)

let mime_of_ext name =
  let ext =
    match String.rindex_opt name '.' with
    | Some i -> String.sub name i (String.length name - i)
    | None -> ""
  in
  match ext with
  | ".css" -> "text/css"
  | ".js" -> "application/javascript"
  | ".html" -> "text/html"
  | ".json" -> "application/json"
  | ".woff2" -> "font/woff2"
  | ".svg" -> "image/svg+xml"
  | ".webp" -> "image/webp"
  | ".png" -> "image/png"
  | _ -> "application/octet-stream"

let load_static dir =
  match Sys.readdir dir with
  | exception _ -> ()
  | names ->
      Array.iter
        (fun name ->
          let path = Filename.concat dir name in
          if try Sys.is_directory path with _ -> true then ()
          else
            match In_channel.with_open_bin path In_channel.input_all with
            | raw ->
                let ctype = mime_of_ext name in
                let gzip =
                  if compressible_ctype ctype && String.length raw >= 256 then
                    let z = Hcs.Plug.Compress.gzip_compress ~level:6 raw in
                    if String.length z < String.length raw then
                      Some (Cstruct.of_string z)
                    else None
                  else None
                in
                Hashtbl.replace static_table name
                  { raw = Cstruct.of_string raw; gzip; ctype }
            | exception _ -> ())
        names

let handle_static ~req path =
  (* path is "/static/<name>" *)
  let name = String.sub path 8 (String.length path - 8) in
  match Hashtbl.find_opt static_table name with
  | None -> not_found ()
  | Some e -> (
      match e.gzip with
      | Some z when accepts_gzip req ->
          respond_cstruct ~ct:e.ctype ~extra:gzip_headers z
      | _ -> respond_cstruct ~ct:e.ctype e.raw)

(* ── Upload: return byte count of body ──────────────────────────────────── *)

(* Report the body byte count without materializing it as a string (uses the
   codec's bigstring length directly). *)
let handle_upload req =
  respond ~ct:plaintext_ct (string_of_int (Hcs.Request.body_length req))

(* Echo the decoded bytes, including binary and chunked request bodies. All
   listeners share this handler, including HTTP/1.1 over TLS on port 8081. *)
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

(* tags is a JSONB column; the driver returns it as a JSON-array text we embed
   verbatim. active is boolean. Builds one item object into [buf]. *)
let add_pg_item buf row =
  Buffer.add_string buf "{\"id\":";
  Buffer.add_string buf (string_of_int (row_int row "id"));
  Buffer.add_string buf ",\"name\":";
  add_str buf (row_text row "name");
  Buffer.add_string buf ",\"category\":";
  add_str buf (row_text row "category");
  Buffer.add_string buf ",\"price\":";
  Buffer.add_string buf (string_of_int (row_int row "price"));
  Buffer.add_string buf ",\"quantity\":";
  Buffer.add_string buf (string_of_int (row_int row "quantity"));
  Buffer.add_string buf ",\"active\":";
  Buffer.add_string buf (if row_bool row "active" then "true" else "false");
  Buffer.add_string buf ",\"tags\":";
  Buffer.add_string buf (row_text row "tags");
  Buffer.add_string buf ",\"rating\":{\"score\":";
  Buffer.add_string buf (string_of_int (row_int row "rating_score"));
  Buffer.add_string buf ",\"count\":";
  Buffer.add_string buf (string_of_int (row_int row "rating_count"));
  Buffer.add_string buf "}}"

let item_columns =
  "id, name, category, price, quantity, active, tags, rating_score, \
   rating_count"

let db_error_response () =
  respond ~status:`Internal_server_error ~ct:plaintext_ct
    "Internal Server Error"

(* async-db: items WHERE price BETWEEN min AND max LIMIT limit *)
let handle_async_db ~query =
  let mn = int_param query "min" 10 in
  let mx = int_param query "max" 50 in
  let lim = max 1 (min 50 (int_param query "limit" 50)) in
  if !pool = None then respond ~ct:json_ct "{\"items\":[],\"count\":0}"
  else
    let sql =
      Printf.sprintf
        "SELECT %s FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3"
        item_columns
    in
    match
      with_conn (fun c ->
          Pg.query c sql
            ~params:
              [|
                Repodb.Driver.Value.Int mn;
                Repodb.Driver.Value.Int mx;
                Repodb.Driver.Value.Int lim;
              |])
    with
    | Error _ -> db_error_response ()
    | Ok rows ->
        let buf = Buffer.create 4096 in
        Buffer.add_string buf "{\"items\":[";
        List.iteri
          (fun i row ->
            if i > 0 then Buffer.add_char buf ',';
            add_pg_item buf row)
          rows;
        Buffer.add_string buf "],\"count\":";
        Buffer.add_string buf (string_of_int (List.length rows));
        Buffer.add_char buf '}';
        respond ~ct:json_ct (Buffer.contents buf)

(* ── CRUD: cache-aside REST API over the items table ────────────────────── *)

let cache : (int, string * float) Hashtbl.t = Hashtbl.create 4096
let cache_mutex = Mutex.create ()
let cache_ttl = 0.2 (* 200 ms *)

let cache_get id =
  Mutex.lock cache_mutex;
  let r =
    match Hashtbl.find_opt cache id with
    | Some (body, exp) when Unix.gettimeofday () < exp -> Some body
    | _ -> None
  in
  Mutex.unlock cache_mutex;
  r

let cache_put id body =
  Mutex.lock cache_mutex;
  Hashtbl.replace cache id (body, Unix.gettimeofday () +. cache_ttl);
  Mutex.unlock cache_mutex

let cache_del id =
  Mutex.lock cache_mutex;
  Hashtbl.remove cache id;
  Mutex.unlock cache_mutex

let fetch_item_json id =
  let sql = Printf.sprintf "SELECT %s FROM items WHERE id = $1" item_columns in
  match
    with_conn (fun c -> Pg.query c sql ~params:[| Repodb.Driver.Value.Int id |])
  with
  | Error _ -> Error `Db
  | Ok [] -> Ok None
  | Ok (row :: _) ->
      let buf = Buffer.create 256 in
      add_pg_item buf row;
      Ok (Some (Buffer.contents buf))

let handle_crud_get id =
  match cache_get id with
  | Some body -> respond ~ct:json_ct ~extra:[ ("x-cache", "HIT") ] body
  | None -> (
      match fetch_item_json id with
      | Error `Db -> db_error_response ()
      | Ok None -> not_found ()
      | Ok (Some body) ->
          cache_put id body;
          respond ~ct:json_ct ~extra:[ ("x-cache", "MISS") ] body)

let handle_crud_list ~query =
  let category = Option.value ~default:"" (find_param query "category") in
  let page = max 1 (int_param query "page" 1) in
  let limit = max 1 (int_param query "limit" 10) in
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
      let buf = Buffer.create 4096 in
      Buffer.add_string buf "{\"items\":[";
      List.iteri
        (fun i row ->
          if i > 0 then Buffer.add_char buf ',';
          add_pg_item buf row)
        rows;
      Buffer.add_string buf "],\"total\":";
      Buffer.add_string buf (string_of_int total);
      Buffer.add_string buf ",\"page\":";
      Buffer.add_string buf (string_of_int page);
      Buffer.add_char buf '}';
      respond ~ct:json_ct (Buffer.contents buf)

let json_member_int j k default =
  try Yojson.Safe.Util.(j |> member k |> to_int) with _ -> default

let json_member_str j k default =
  try Yojson.Safe.Util.(j |> member k |> to_string) with _ -> default

let handle_crud_create ~body =
  match Yojson.Safe.from_string body with
  | exception _ -> respond ~status:`Bad_request ~ct:plaintext_ct "Bad Request"
  | j ->
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
      respond ~status:`Created ~ct:json_ct "{\"status\":\"created\"}"

let handle_crud_update id ~body =
  match Yojson.Safe.from_string body with
  | exception _ -> respond ~status:`Bad_request ~ct:plaintext_ct "Bad Request"
  | j ->
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
      respond ~ct:json_ct "{\"status\":\"updated\"}"

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

(* ── Main request router ────────────────────────────────────────────────── *)

let crud_id_of path =
  (* path = "/crud/items/<id>" → Some id *)
  let prefix = "/crud/items/" in
  let pl = String.length prefix in
  if String.length path > pl && String.sub path 0 pl = prefix then
    int_of_string_opt (String.sub path pl (String.length path - pl))
  else None

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(* Cold routes: split the target once and dispatch on the path. These do real
   work (DB, JSON building, file serving), so the split cost is negligible. *)
let handle_cold (req : Hcs.Server.request) path query : Hcs.Server.response =
  match (Hcs.Request.meth req, path) with
  | `GET, "/async-db" -> handle_async_db ~query
  | `GET, "/fortunes" -> handle_fortunes ()
  | `GET, "/crud/items" -> handle_crud_list ~query
  | `POST, "/crud/items" -> handle_crud_create ~body:(Hcs.Request.body req)
  | `GET, p when starts_with ~prefix:"/json/" p ->
      handle_json ~req ~count_str:(String.sub p 6 (String.length p - 6)) ~query
  | `GET, p when starts_with ~prefix:"/static/" p -> handle_static ~req p
  | `GET, p when crud_id_of p <> None ->
      handle_crud_get (Option.get (crud_id_of p))
  | (`PUT | `POST), p when crud_id_of p <> None ->
      handle_crud_update
        (Option.get (crud_id_of p))
        ~body:(Hcs.Request.body req)
  | _ -> not_found ()

let handler (req : Hcs.Server.request) : Hcs.Server.response =
  let t = Hcs.Request.target req in
  let pl = path_len t in
  match Hcs.Request.meth req with
  | `GET when path_eq t pl "/baseline11" || path_eq t pl "/baseline2" ->
      handle_baseline ~target:t ~body:""
  | `POST when path_eq t pl "/baseline11" ->
      handle_baseline ~target:t ~body:(Hcs.Request.body req)
  | `GET when path_eq t pl "/pipeline" ->
      Hcs.Server.respond_prebuilt pipeline_resp
  | `POST when path_eq t pl "/upload" -> handle_upload req
  | `POST when path_eq t pl "/echo" -> handle_echo req
  | _ ->
      let path = String.sub t 0 pl in
      let query =
        if pl < String.length t then
          String.sub t (pl + 1) (String.length t - pl - 1)
        else ""
      in
      handle_cold req path query

(* ── WebSocket echo ─────────────────────────────────────────────────────── *)

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
let run_all env ~domains ~configs =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let dm = Eio.Stdenv.domain_mgr env in
  let serve_one () =
    Eio.Switch.run @@ fun sw ->
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
    load_static static_dir;
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
      "[arena] HCS HttpArena server: %d domains, dataset=%d items, static=%d \
       files, db=%b\n\
       %!"
      domains (Array.length !dataset)
      (Hashtbl.length static_table)
      (!pool <> None);
    Printf.printf
      "[arena] listeners: 8080 (h1/h2c/ws) 8443 (h2 TLS) 8081 (h1 TLS) 8082 \
       (h2c)\n\
       %!";
    run_eio @@ fun env ->
    let configs =
      make_configs ~certs_dir ~port ~h2_port ~h1tls_port ~h2c_port
    in
    run_all env ~domains ~configs

let () = Climate.Command.run command ()
