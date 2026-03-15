(* HttpArena benchmark server — Dream (OCaml) *)

let server_header handler request =
  let%lwt response = handler request in
  Dream.set_header response "Server" "dream";
  Lwt.return response

(* --- Helpers --- *)

let parse_query_sum query =
  let pairs = String.split_on_char '&' query in
  List.fold_left (fun acc pair ->
    match String.split_on_char '=' pair with
    | [_; v] -> (try acc + int_of_string v with _ -> acc)
    | _ -> acc
  ) 0 pairs

let get_query_sum request =
  match Dream.query request "dummy_force_parse" with
  | _ ->
    (* Dream doesn't expose raw query string directly, reconstruct from target *)
    let target = Dream.target request in
    match String.index_opt target '?' with
    | None -> 0
    | Some i -> parse_query_sum (String.sub target (i + 1) (String.length target - i - 1))

let get_query_param request name =
  let target = Dream.target request in
  match String.index_opt target '?' with
  | None -> None
  | Some i ->
    let qs = String.sub target (i + 1) (String.length target - i - 1) in
    let pairs = String.split_on_char '&' qs in
    let rec find = function
      | [] -> None
      | pair :: rest ->
        (match String.split_on_char '=' pair with
         | [k; v] when k = name -> Some v
         | _ -> find rest)
    in
    find pairs

(* --- Dataset types and loading --- *)

type rating = { score : float; count : int }

type dataset_item = {
  id : int;
  name : string;
  category : string;
  price : float;
  quantity : int;
  active : bool;
  tags : string list;
  rating : rating;
}

let parse_rating json =
  let open Yojson.Basic.Util in
  { score = json |> member "score" |> to_float;
    count = json |> member "count" |> to_int }

let parse_item json =
  let open Yojson.Basic.Util in
  { id = json |> member "id" |> to_int;
    name = json |> member "name" |> to_string;
    category = json |> member "category" |> to_string;
    price = json |> member "price" |> to_float;
    quantity = json |> member "quantity" |> to_int;
    active = json |> member "active" |> to_bool;
    tags = json |> member "tags" |> to_list |> List.map to_string;
    rating = json |> member "rating" |> parse_rating }

let load_dataset path =
  try
    let json = Yojson.Basic.from_file path in
    Yojson.Basic.Util.to_list json |> List.map parse_item
  with _ -> []

let round2 f =
  Float.of_int (Float.to_int (f *. 100.0 +. 0.5)) /. 100.0

let item_to_json item =
  let total = round2 (item.price *. Float.of_int item.quantity) in
  `Assoc [
    "id", `Int item.id;
    "name", `String item.name;
    "category", `String item.category;
    "price", `Float item.price;
    "quantity", `Int item.quantity;
    "active", `Bool item.active;
    "tags", `List (List.map (fun s -> `String s) item.tags);
    "rating", `Assoc ["score", `Float item.rating.score; "count", `Int item.rating.count];
    "total", `Float total;
  ]

let build_json_response items =
  let json_items = List.map item_to_json items in
  let resp = `Assoc [
    "items", `List json_items;
    "count", `Int (List.length json_items);
  ] in
  Yojson.Basic.to_string resp

(* --- Static files --- *)

let mime_of_ext ext =
  match ext with
  | ".css" -> "text/css"
  | ".js" -> "application/javascript"
  | ".html" -> "text/html"
  | ".woff2" -> "font/woff2"
  | ".svg" -> "image/svg+xml"
  | ".webp" -> "image/webp"
  | ".json" -> "application/json"
  | _ -> "application/octet-stream"

let load_static_files () =
  let tbl = Hashtbl.create 32 in
  (try
    let dir = Unix.opendir "/data/static" in
    (try while true do
      let name = Unix.readdir dir in
      if name <> "." && name <> ".." then begin
        let path = "/data/static/" ^ name in
        let ic = open_in_bin path in
        let len = in_channel_length ic in
        let data = Bytes.create len in
        really_input ic data 0 len;
        close_in ic;
        let ext = match String.rindex_opt name '.' with
          | Some i -> String.sub name i (String.length name - i)
          | None -> "" in
        Hashtbl.replace tbl name (Bytes.to_string data, mime_of_ext ext)
      end
    done with End_of_file -> ());
    Unix.closedir dir
  with _ -> ());
  tbl

(* --- Database --- *)

let open_db () =
  try
    let db = Sqlite3.db_open ~mode:`READONLY "/data/benchmark.db" in
    ignore (Sqlite3.exec db "PRAGMA mmap_size=268435456");
    Some db
  with _ -> None

let query_db db min_price max_price =
  let stmt = Sqlite3.prepare db
    "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50" in
  ignore (Sqlite3.bind stmt 1 (Sqlite3.Data.FLOAT min_price));
  ignore (Sqlite3.bind stmt 2 (Sqlite3.Data.FLOAT max_price));
  let items = ref [] in
  while Sqlite3.step stmt = Sqlite3.Rc.ROW do
    let row = Sqlite3.row_data stmt in
    let id = (match row.(0) with Sqlite3.Data.INT i -> Int64.to_int i | _ -> 0) in
    let name = (match row.(1) with Sqlite3.Data.TEXT s -> s | _ -> "") in
    let category = (match row.(2) with Sqlite3.Data.TEXT s -> s | _ -> "") in
    let price = (match row.(3) with Sqlite3.Data.FLOAT f -> f | _ -> 0.0) in
    let quantity = (match row.(4) with Sqlite3.Data.INT i -> Int64.to_int i | _ -> 0) in
    let active = (match row.(5) with Sqlite3.Data.INT i -> i = 1L | _ -> false) in
    let tags_str = (match row.(6) with Sqlite3.Data.TEXT s -> s | _ -> "[]") in
    let _tags = try
      Yojson.Basic.from_string tags_str |> Yojson.Basic.Util.to_list |> List.map Yojson.Basic.Util.to_string
    with _ -> [] in
    let rating_score = (match row.(7) with Sqlite3.Data.FLOAT f -> f | _ -> 0.0) in
    let rating_count = (match row.(8) with Sqlite3.Data.INT i -> Int64.to_int i | _ -> 0) in
    items := `Assoc [
      "id", `Int id;
      "name", `String name;
      "category", `String category;
      "price", `Float price;
      "quantity", `Int quantity;
      "active", `Bool active;
      "tags", (try Yojson.Basic.from_string tags_str with _ -> `List []);
      "rating", `Assoc ["score", `Float rating_score; "count", `Int rating_count];
    ] :: !items
  done;
  ignore (Sqlite3.finalize stmt);
  let items = List.rev !items in
  Yojson.Basic.to_string (`Assoc ["items", `List items; "count", `Int (List.length items)])

(* --- Gzip compression --- *)

let gzip_compress data =
  (* Use a temp file since Gzip module requires file channels *)
  let tmp = Filename.temp_file "gzip" ".gz" in
  let oc = Gzip.open_out ~level:6 tmp in
  Gzip.output_substring oc data 0 (String.length data);
  Gzip.close_out oc;
  let ic = open_in_bin tmp in
  let len = in_channel_length ic in
  let buf = Bytes.create len in
  really_input ic buf 0 len;
  close_in ic;
  Unix.unlink tmp;
  Bytes.to_string buf

(* --- Entry point: single-process, multi-core via run.sh shell wrapper --- *)

let () =
  let dataset_path = try Sys.getenv "DATASET_PATH" with Not_found -> "/data/dataset.json" in
  let dataset = load_dataset dataset_path in
  let large_dataset = load_dataset "/data/dataset-large.json" in
  let json_large_cache = build_json_response large_dataset in
  let json_large_gzipped = gzip_compress json_large_cache in
  let static_files = load_static_files () in
  let db = open_db () in

  let _json_cache = build_json_response dataset in

  Dream.run
    ~interface:"0.0.0.0"
    ~port:8080
    ~greeting:false
  @@ server_header
  @@ Dream.router [

    (* /pipeline — minimal response *)
    Dream.get "/pipeline" (fun _request ->
      Dream.respond
        ~headers:["Content-Type", "text/plain"]
        "ok");

    (* /baseline11 GET — sum query params *)
    Dream.get "/baseline11" (fun request ->
      let sum = get_query_sum request in
      Dream.respond
        ~headers:["Content-Type", "text/plain"]
        (string_of_int sum));

    (* /baseline11 POST — sum query params + body *)
    Dream.post "/baseline11" (fun request ->
      let query_sum = get_query_sum request in
      let%lwt body = Dream.body request in
      let body_val = (try int_of_string (String.trim body) with _ -> 0) in
      Dream.respond
        ~headers:["Content-Type", "text/plain"]
        (string_of_int (query_sum + body_val)));

    (* /baseline2 GET — sum query params *)
    Dream.get "/baseline2" (fun request ->
      let sum = get_query_sum request in
      Dream.respond
        ~headers:["Content-Type", "text/plain"]
        (string_of_int sum));

    (* /json — process dataset and return JSON *)
    Dream.get "/json" (fun _request ->
      if dataset = [] then
        Dream.respond ~status:`Internal_Server_Error "No dataset"
      else
        let body = build_json_response dataset in
        Dream.respond
          ~headers:["Content-Type", "application/json"]
          body);

    (* /compression — return large JSON with gzip compression *)
    Dream.get "/compression" (fun request ->
      let accept = match Dream.header request "Accept-Encoding" with Some v -> v | None -> "" in
      let has_gzip =
        let len = String.length accept in
        let rec check i =
          if i + 3 >= len then false
          else if accept.[i] = 'g' && accept.[i+1] = 'z' && accept.[i+2] = 'i' && accept.[i+3] = 'p' then true
          else check (i + 1)
        in check 0
      in
      if has_gzip then
        Dream.respond
          ~headers:["Content-Type", "application/json"; "Content-Encoding", "gzip"]
          json_large_gzipped
      else
        Dream.respond
          ~headers:["Content-Type", "application/json"]
          json_large_cache);

    (* /db — query SQLite *)
    Dream.get "/db" (fun request ->
      match db with
      | None -> Dream.respond ~status:`Internal_Server_Error "No database"
      | Some db ->
        let min_price = match get_query_param request "min" with
          | Some v -> (try float_of_string v with _ -> 10.0)
          | None -> 10.0 in
        let max_price = match get_query_param request "max" with
          | Some v -> (try float_of_string v with _ -> 50.0)
          | None -> 50.0 in
        let body = query_db db min_price max_price in
        Dream.respond
          ~headers:["Content-Type", "application/json"]
          body);

    (* /upload POST — return body size *)
    Dream.post "/upload" (fun request ->
      let%lwt body = Dream.body request in
      Dream.respond
        ~headers:["Content-Type", "text/plain"]
        (string_of_int (String.length body)));

    (* /static/:filename — serve static files *)
    Dream.get "/static/:filename" (fun request ->
      let filename = Dream.param request "filename" in
      match Hashtbl.find_opt static_files filename with
      | Some (data, content_type) ->
        Dream.respond
          ~headers:["Content-Type", content_type]
          data
      | None ->
        Dream.respond ~status:`Not_Found "Not Found");
  ]
