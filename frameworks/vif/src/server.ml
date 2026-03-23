open Vif

(* ---------------------------------------------------------------------------
   Startup: load datasets once
   --------------------------------------------------------------------------- *)

let dataset_path =
  try Sys.getenv "DATASET_PATH" with Not_found -> "/data/dataset.json"

let large_dataset_path = "/data/dataset-large.json"
let db_path = "/data/benchmark.db"

let read_file path =
  if Sys.file_exists path then begin
    let ic = open_in path in
    let n = in_channel_length ic in
    let s = Bytes.create n in
    really_input ic s 0 n;
    close_in ic;
    Some (Bytes.unsafe_to_string s)
  end else None

(* Process items: add "total" = price * quantity rounded to 2 decimals *)
let process_items (items : Yojson.Basic.t list) : Yojson.Basic.t list =
  List.map (fun item ->
    match item with
    | `Assoc fields ->
      let price = match List.assoc_opt "price" fields with
        | Some (`Float f) -> f
        | Some (`Int n) -> Float.of_int n
        | _ -> 0.0 in
      let quantity = match List.assoc_opt "quantity" fields with
        | Some (`Int n) -> n
        | Some (`Float f) -> Float.to_int f
        | _ -> 0 in
      let total = Float.round (price *. Float.of_int quantity *. 100.0) /. 100.0 in
      `Assoc (fields @ [("total", `Float total)])
    | other -> other
  ) items

(* Small dataset — raw JSON array *)
let dataset_raw : Yojson.Basic.t list option =
  match read_file dataset_path with
  | Some s ->
    (match Yojson.Basic.from_string s with
     | `List items -> Some items
     | _ -> None
     | exception _ -> None)
  | None -> None

(* Large dataset — pre-processed JSON string *)
let large_payload : string option =
  match read_file large_dataset_path with
  | Some s ->
    (match Yojson.Basic.from_string s with
     | `List items ->
       let processed = process_items items in
       let result = `Assoc [
         ("items", `List processed);
         ("count", `Int (List.length processed))
       ] in
       Some (Yojson.Basic.to_string result)
     | _ -> None
     | exception _ -> None)
  | None -> None

(* ---------------------------------------------------------------------------
   Helpers
   --------------------------------------------------------------------------- *)

let server_header () =
  Response.add ~field:"server" "vif"

let sum_query_params req =
  let params = Queries.all req in
  List.fold_left (fun acc (_key, values) ->
    List.fold_left (fun acc v ->
      match int_of_string_opt v with
      | Some n -> acc + n
      | None -> acc
    ) acc values
  ) 0 params

let read_body req =
  let src = Request.source req in
  let stream = Flux.Stream.from src in
  Flux.Stream.into Flux.Sink.string stream

let count_body_bytes req =
  let src = Request.source req in
  let stream = Flux.Stream.from src in
  Flux.Stream.into (Flux.Sink.fold (fun acc chunk -> acc + String.length chunk) 0) stream

(* ---------------------------------------------------------------------------
   Routes
   --------------------------------------------------------------------------- *)

(* GET /pipeline — simple "ok" response *)
let pipeline req _server () =
  let open Response.Syntax in
  let* () = server_header () in
  let* () = Response.add ~field:"content-type" "text/plain" in
  let* () = Response.with_string req "ok" in
  Response.respond `OK

(* GET /baseline11 — sum query params *)
let baseline11_get req _server () =
  let open Response.Syntax in
  let* () = server_header () in
  let total = sum_query_params req in
  let* () = Response.add ~field:"content-type" "text/plain" in
  let* () = Response.with_string req (string_of_int total) in
  Response.respond `OK

(* POST /baseline11 — sum query params + body *)
let baseline11_post req _server () =
  let open Response.Syntax in
  let* () = server_header () in
  let total = sum_query_params req in
  let body = String.trim (read_body req) in
  let body_val = match int_of_string_opt body with
    | Some n -> n
    | None -> 0 in
  let* () = Response.add ~field:"content-type" "text/plain" in
  let* () = Response.with_string req (string_of_int (total + body_val)) in
  Response.respond `OK

(* GET /baseline2 — sum query params *)
let baseline2 req _server () =
  let open Response.Syntax in
  let* () = server_header () in
  let total = sum_query_params req in
  let* () = Response.add ~field:"content-type" "text/plain" in
  let* () = Response.with_string req (string_of_int total) in
  Response.respond `OK

(* GET /json — process dataset and return JSON *)
let json_endpoint req _server () =
  let open Response.Syntax in
  let* () = server_header () in
  match dataset_raw with
  | Some items ->
    let processed = process_items items in
    let result = `Assoc [
      ("items", `List processed);
      ("count", `Int (List.length processed))
    ] in
    let s = Yojson.Basic.to_string result in
    let* () = Response.add ~field:"content-type" "application/json" in
    let* () = Response.with_string req s in
    Response.respond `OK
  | None ->
    let* () = Response.add ~field:"content-type" "text/plain" in
    let* () = Response.with_string req "No dataset" in
    Response.respond `Internal_server_error

(* GET /compression — gzip compressed large dataset *)
let compression req _server () =
  let open Response.Syntax in
  let* () = server_header () in
  match large_payload with
  | Some payload ->
    let* () = Response.add ~field:"content-type" "application/json" in
    let* () = Response.with_string ~compression:`Gzip req payload in
    Response.respond `OK
  | None ->
    let* () = Response.add ~field:"content-type" "text/plain" in
    let* () = Response.with_string req "No dataset" in
    Response.respond `Internal_server_error

(* POST /upload — count received bytes *)
let upload req _server () =
  let open Response.Syntax in
  let* () = server_header () in
  let byte_count = count_body_bytes req in
  let* () = Response.add ~field:"content-type" "text/plain" in
  let* () = Response.with_string req (string_of_int byte_count) in
  Response.respond `OK

(* GET /db — SQLite query *)
let db_endpoint req _server () =
  let open Response.Syntax in
  let* () = server_header () in
  if not (Sys.file_exists db_path) then begin
    let* () = Response.add ~field:"content-type" "application/json" in
    let* () = Response.with_string req {|{"items":[],"count":0}|} in
    Response.respond `OK
  end else begin
    let min_val = match Queries.get req "min" with
      | v :: _ -> (match float_of_string_opt v with Some f -> f | None -> 10.0)
      | [] -> 10.0 in
    let max_val = match Queries.get req "max" with
      | v :: _ -> (match float_of_string_opt v with Some f -> f | None -> 50.0)
      | [] -> 50.0 in
    let db = Sqlite3.db_open ~mode:`READONLY db_path in
    let sql = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50" in
    let stmt = Sqlite3.prepare db sql in
    ignore (Sqlite3.bind stmt 1 (Sqlite3.Data.FLOAT min_val));
    ignore (Sqlite3.bind stmt 2 (Sqlite3.Data.FLOAT max_val));
    let items = ref [] in
    while Sqlite3.step stmt = Sqlite3.Rc.ROW do
      let id = match Sqlite3.column stmt 0 with
        | Sqlite3.Data.INT i -> `Int (Int64.to_int i) | _ -> `Int 0 in
      let name = match Sqlite3.column stmt 1 with
        | Sqlite3.Data.TEXT s -> `String s | _ -> `String "" in
      let category = match Sqlite3.column stmt 2 with
        | Sqlite3.Data.TEXT s -> `String s | _ -> `String "" in
      let price = match Sqlite3.column stmt 3 with
        | Sqlite3.Data.FLOAT f -> `Float f | _ -> `Float 0.0 in
      let quantity = match Sqlite3.column stmt 4 with
        | Sqlite3.Data.INT i -> `Int (Int64.to_int i) | _ -> `Int 0 in
      let active = match Sqlite3.column stmt 5 with
        | Sqlite3.Data.INT i -> `Bool (i <> 0L) | _ -> `Bool false in
      let tags = match Sqlite3.column stmt 6 with
        | Sqlite3.Data.TEXT s ->
          (try Yojson.Basic.from_string s with _ -> `List [])
        | _ -> `List [] in
      let rs = match Sqlite3.column stmt 7 with
        | Sqlite3.Data.FLOAT f -> f | _ -> 0.0 in
      let rc = match Sqlite3.column stmt 8 with
        | Sqlite3.Data.INT i -> Int64.to_int i | _ -> 0 in
      let item = `Assoc [
        ("id", id); ("name", name); ("category", category);
        ("price", price); ("quantity", quantity); ("active", active);
        ("tags", tags);
        ("rating", `Assoc [("score", `Float rs); ("count", `Int rc)])
      ] in
      items := item :: !items
    done;
    ignore (Sqlite3.finalize stmt);
    ignore (Sqlite3.db_close db);
    let items_list = List.rev !items in
    let result = `Assoc [
      ("items", `List items_list);
      ("count", `Int (List.length items_list))
    ] in
    let s = Yojson.Basic.to_string result in
    let* () = Response.add ~field:"content-type" "application/json" in
    let* () = Response.with_string req s in
    Response.respond `OK
  end

(* ---------------------------------------------------------------------------
   Server config
   --------------------------------------------------------------------------- *)

let routes =
  let open Uri in
  let open Route in
  let open Type in
  [ get  (rel / "pipeline" /?? any) --> pipeline
  ; get  (rel / "baseline11" /?? any) --> baseline11_get
  ; post any (rel / "baseline11" /?? any) --> baseline11_post
  ; get  (rel / "baseline2" /?? any) --> baseline2
  ; get  (rel / "json" /?? any) --> json_endpoint
  ; get  (rel / "compression" /?? any) --> compression
  ; post any (rel / "upload" /?? any) --> upload
  ; get  (rel / "db" /?? any) --> db_endpoint
  ]

let () =
  Miou_unix.run @@ fun () ->
  let addr = Unix.ADDR_INET (Unix.inet_addr_any, 8080) in
  let cfg = Vif.config ~level:(Some Logs.Error) addr in
  Vif.run ~cfg routes ()
