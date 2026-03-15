import envoy
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/http.{Get, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import logging
import mist.{type Connection, type ResponseData}
import simplifile
import sqlight

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type Context {
  Context(
    dataset: List(DatasetItem),
    json_cache: BitArray,
    json_large_cache: BitArray,
    static_files: List(#(String, StaticFile)),
    db_available: Bool,
  )
}

pub type DatasetItem {
  DatasetItem(
    id: Int,
    name: String,
    category: String,
    price: Float,
    quantity: Int,
    active: Bool,
    tags: List(String),
    rating_score: Float,
    rating_count: Int,
  )
}

pub type StaticFile {
  StaticFile(data: BitArray, content_type: String)
}

// ---------------------------------------------------------------------------
// Dataset decoder
// ---------------------------------------------------------------------------

fn dataset_item_decoder() -> decode.Decoder(DatasetItem) {
  use id <- decode.field("id", decode.int)
  use name <- decode.field("name", decode.string)
  use category <- decode.field("category", decode.string)
  use price <- decode.field("price", decode.float)
  use quantity <- decode.field("quantity", decode.int)
  use active <- decode.field("active", decode.bool)
  use tags <- decode.field("tags", decode.list(decode.string))
  use rating_score <- decode.subfield(["rating", "score"], decode.float)
  use rating_count <- decode.subfield(["rating", "count"], decode.int)
  decode.success(DatasetItem(
    id:,
    name:,
    category:,
    price:,
    quantity:,
    active:,
    tags:,
    rating_score:,
    rating_count:,
  ))
}

// ---------------------------------------------------------------------------
// Data loading
// ---------------------------------------------------------------------------

fn load_dataset(path: String) -> List(DatasetItem) {
  case simplifile.read(path) {
    Ok(data) -> {
      case json.parse(data, decode.list(dataset_item_decoder())) {
        Ok(items) -> items
        Error(_) -> []
      }
    }
    Error(_) -> []
  }
}

fn load_static_files() -> List(#(String, StaticFile)) {
  case simplifile.read_directory("/data/static") {
    Ok(entries) -> {
      list.filter_map(entries, fn(name) {
        let path = "/data/static/" <> name
        case simplifile.read_bits(path) {
          Ok(data) -> Ok(#(name, StaticFile(data:, content_type: get_mime(name))))
          Error(_) -> Error(Nil)
        }
      })
    }
    Error(_) -> []
  }
}

fn get_mime(filename: String) -> String {
  case string.ends_with(filename, ".css") {
    True -> "text/css"
    False ->
      case string.ends_with(filename, ".js") {
        True -> "application/javascript"
        False ->
          case string.ends_with(filename, ".html") {
            True -> "text/html"
            False ->
              case string.ends_with(filename, ".woff2") {
                True -> "font/woff2"
                False ->
                  case string.ends_with(filename, ".svg") {
                    True -> "image/svg+xml"
                    False ->
                      case string.ends_with(filename, ".webp") {
                        True -> "image/webp"
                        False ->
                          case string.ends_with(filename, ".json") {
                            True -> "application/json"
                            False -> "application/octet-stream"
                          }
                      }
                  }
              }
          }
      }
  }
}

fn build_json_response(dataset: List(DatasetItem)) -> BitArray {
  let items =
    list.map(dataset, fn(d) {
      let total = round2(d.price *. int.to_float(d.quantity))
      json.object([
        #("id", json.int(d.id)),
        #("name", json.string(d.name)),
        #("category", json.string(d.category)),
        #("price", json.float(d.price)),
        #("quantity", json.int(d.quantity)),
        #("active", json.bool(d.active)),
        #("tags", json.array(d.tags, json.string)),
        #(
          "rating",
          json.object([
            #("score", json.float(d.rating_score)),
            #("count", json.int(d.rating_count)),
          ]),
        ),
        #("total", json.float(total)),
      ])
    })
  let resp =
    json.object([
      #("items", json.preprocessed_array(items)),
      #("count", json.int(list.length(dataset))),
    ])
  <<json.to_string(resp):utf8>>
}

fn round2(x: Float) -> Float {
  let rounded = float.round(x *. 100.0)
  int.to_float(rounded) /. 100.0
}

// ---------------------------------------------------------------------------
// Query string helpers
// ---------------------------------------------------------------------------

fn parse_query_sum(query: String) -> Int {
  string.split(query, "&")
  |> list.fold(0, fn(acc, pair) {
    case string.split(pair, "=") {
      [_, val] ->
        case int.parse(val) {
          Ok(n) -> acc + n
          Error(_) -> acc
        }
      _ -> acc
    }
  })
}

fn get_query_float(
  query: option.Option(String),
  key: String,
  default: Float,
) -> Float {
  case query {
    None -> default
    Some(q) -> {
      string.split(q, "&")
      |> list.fold(default, fn(acc, pair) {
        case string.split_once(pair, "=") {
          Ok(#(k, v)) if k == key -> {
            case float.parse(v) {
              Ok(f) -> f
              Error(_) ->
                case int.parse(v) {
                  Ok(i) -> int.to_float(i)
                  Error(_) -> acc
                }
            }
          }
          _ -> acc
        }
      })
    }
  }
}

// ---------------------------------------------------------------------------
// Erlang zlib FFI for gzip compression
// ---------------------------------------------------------------------------

@external(erlang, "zlib", "gzip")
fn gzip(data: BitArray) -> BitArray

// ---------------------------------------------------------------------------
// Response helpers
// ---------------------------------------------------------------------------

fn text_response(body: String) -> Response(ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "text/plain")
  |> response.set_header("server", "gleam-mist")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn json_response(body: BitArray) -> Response(ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_header("server", "gleam-mist")
  |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(body)))
}

fn not_found() -> Response(ResponseData) {
  response.new(404)
  |> response.set_header("server", "gleam-mist")
  |> response.set_body(mist.Bytes(bytes_tree.from_string("Not Found")))
}

fn server_error() -> Response(ResponseData) {
  response.new(500)
  |> response.set_header("server", "gleam-mist")
  |> response.set_body(mist.Bytes(bytes_tree.from_string("Internal Server Error")))
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

fn handle_request(
  req: Request(Connection),
  ctx: Context,
) -> Response(ResponseData) {
  case request.path_segments(req) {
    ["pipeline"] -> handle_pipeline(req)
    ["baseline11"] -> handle_baseline11(req)
    ["baseline2"] -> handle_baseline2(req)
    ["json"] -> handle_json(req, ctx)
    ["compression"] -> handle_compression(req, ctx)
    ["upload"] -> handle_upload(req)
    ["db"] -> handle_db(req, ctx)
    ["static", filename] -> handle_static(req, ctx, filename)
    _ -> not_found()
  }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn handle_pipeline(req: Request(Connection)) -> Response(ResponseData) {
  case req.method {
    Get -> text_response("ok")
    _ -> not_found()
  }
}

fn handle_baseline11(req: Request(Connection)) -> Response(ResponseData) {
  case req.method {
    Get -> {
      let sum =
        req.query
        |> option.map(parse_query_sum)
        |> option.unwrap(0)
      text_response(int.to_string(sum))
    }
    Post -> {
      let query_sum =
        req.query
        |> option.map(parse_query_sum)
        |> option.unwrap(0)
      case mist.read_body(req, max_body_limit: 10_000_000) {
        Ok(req_with_body) -> {
          let body_str =
            req_with_body.body
            |> bit_array_to_string
            |> string.trim
          let body_val = result.unwrap(int.parse(body_str), 0)
          text_response(int.to_string(query_sum + body_val))
        }
        Error(_) -> text_response(int.to_string(query_sum))
      }
    }
    _ -> not_found()
  }
}

fn handle_baseline2(req: Request(Connection)) -> Response(ResponseData) {
  case req.method {
    Get -> {
      let sum =
        req.query
        |> option.map(parse_query_sum)
        |> option.unwrap(0)
      text_response(int.to_string(sum))
    }
    _ -> not_found()
  }
}

fn handle_json(
  req: Request(Connection),
  ctx: Context,
) -> Response(ResponseData) {
  case req.method {
    Get ->
      case ctx.dataset {
        [] -> server_error()
        _ -> json_response(ctx.json_cache)
      }
    _ -> not_found()
  }
}

fn handle_compression(
  req: Request(Connection),
  ctx: Context,
) -> Response(ResponseData) {
  case req.method {
    Get -> {
      let accepts_gzip =
        list.any(req.headers, fn(h) {
          case h {
            #("accept-encoding", val) -> string.contains(val, "gzip")
            _ -> False
          }
        })
      case accepts_gzip {
        True -> {
          let compressed = gzip(ctx.json_large_cache)
          response.new(200)
          |> response.set_header("content-type", "application/json")
          |> response.set_header("content-encoding", "gzip")
          |> response.set_header("server", "gleam-mist")
          |> response.set_body(
            mist.Bytes(bytes_tree.from_bit_array(compressed)),
          )
        }
        False -> json_response(ctx.json_large_cache)
      }
    }
    _ -> not_found()
  }
}

fn handle_upload(req: Request(Connection)) -> Response(ResponseData) {
  case req.method {
    Post -> {
      case mist.read_body(req, max_body_limit: 25_000_000) {
        Ok(req_with_body) -> {
          let size = bit_array.byte_size(req_with_body.body)
          text_response(int.to_string(size))
        }
        Error(_) ->
          response.new(400)
          |> response.set_header("server", "gleam-mist")
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string("Bad Request")),
          )
      }
    }
    _ -> not_found()
  }
}

fn handle_db(
  req: Request(Connection),
  ctx: Context,
) -> Response(ResponseData) {
  case req.method {
    Get -> {
      case ctx.db_available {
        False ->
          json_response(<<"{\"items\":[],\"count\":0}":utf8>>)
        True -> {
          let min_price = get_query_float(req.query, "min", 10.0)
          let max_price = get_query_float(req.query, "max", 50.0)

          let db_result =
            sqlight.with_connection(
              "file:/data/benchmark.db?mode=ro",
              fn(conn) {
                let _ = sqlight.exec("PRAGMA mmap_size=268435456", conn)
                let row_decoder = {
                  use id <- decode.field(0, decode.int)
                  use name <- decode.field(1, decode.string)
                  use category <- decode.field(2, decode.string)
                  use price <- decode.field(3, decode.float)
                  use quantity <- decode.field(4, decode.int)
                  use active_int <- decode.field(5, decode.int)
                  use tags_str <- decode.field(6, decode.string)
                  use rating_score <- decode.field(7, decode.float)
                  use rating_count <- decode.field(8, decode.int)
                  decode.success(#(
                    id,
                    name,
                    category,
                    price,
                    quantity,
                    active_int,
                    tags_str,
                    rating_score,
                    rating_count,
                  ))
                }
                sqlight.query(
                  "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ?1 AND ?2 LIMIT 50",
                  conn,
                  [sqlight.float(min_price), sqlight.float(max_price)],
                  row_decoder,
                )
              },
            )

          case db_result {
            Ok(rows) -> {
              let items =
                list.map(rows, fn(row) {
                  let #(
                    id,
                    name,
                    category,
                    price,
                    quantity,
                    active_int,
                    tags_str,
                    rating_score,
                    rating_count,
                  ) = row
                  let active = active_int != 0
                  let tags =
                    case json.parse(tags_str, decode.list(decode.string)) {
                      Ok(t) -> t
                      Error(_) -> []
                    }
                  json.object([
                    #("id", json.int(id)),
                    #("name", json.string(name)),
                    #("category", json.string(category)),
                    #("price", json.float(price)),
                    #("quantity", json.int(quantity)),
                    #("active", json.bool(active)),
                    #("tags", json.array(tags, json.string)),
                    #(
                      "rating",
                      json.object([
                        #("score", json.float(rating_score)),
                        #("count", json.int(rating_count)),
                      ]),
                    ),
                  ])
                })
              let resp =
                json.object([
                  #("items", json.preprocessed_array(items)),
                  #("count", json.int(list.length(rows))),
                ])
              json_response(<<json.to_string(resp):utf8>>)
            }
            Error(_) ->
              json_response(<<"{\"items\":[],\"count\":0}":utf8>>)
          }
        }
      }
    }
    _ -> not_found()
  }
}

fn handle_static(
  req: Request(Connection),
  ctx: Context,
  filename: String,
) -> Response(ResponseData) {
  case req.method {
    Get -> {
      case list.key_find(ctx.static_files, filename) {
        Ok(sf) -> {
          response.new(200)
          |> response.set_header("content-type", sf.content_type)
          |> response.set_header("server", "gleam-mist")
          |> response.set_body(
            mist.Bytes(bytes_tree.from_bit_array(sf.data)),
          )
        }
        Error(_) -> not_found()
      }
    }
    _ -> not_found()
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn bit_array_to_string(data: BitArray) -> String {
  case bit_array.to_string(data) {
    Ok(s) -> s
    Error(_) -> ""
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  let dataset_path = case envoy.get("DATASET_PATH") {
    Ok(p) -> p
    Error(_) -> "/data/dataset.json"
  }
  let dataset = load_dataset(dataset_path)
  let json_cache = build_json_response(dataset)

  let large_dataset = load_dataset("/data/dataset-large.json")
  let json_large_cache = build_json_response(large_dataset)

  let static_files = load_static_files()

  let db_available = case simplifile.is_file("/data/benchmark.db") {
    Ok(True) -> True
    _ -> False
  }

  let ctx =
    Context(
      dataset:,
      json_cache:,
      json_large_cache:,
      static_files:,
      db_available:,
    )

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      handle_request(req, ctx)
    }
    |> mist.new
    |> mist.port(8080)
    |> mist.bind("0.0.0.0")
    |> mist.start

  process.sleep_forever()
}
