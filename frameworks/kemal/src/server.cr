require "kemal"
require "json"
require "compress/gzip"
require "sqlite3"

# ---------------------------------------------------------------------------
# Startup: load datasets once
# ---------------------------------------------------------------------------

DATASET_PATH       = ENV.fetch("DATASET_PATH", "/data/dataset.json")
LARGE_DATASET_PATH = "/data/dataset-large.json"
DB_PATH            = "/data/benchmark.db"
DB_QUERY           = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50"

# Process a raw JSON array of items → add "total" field
def process_items(raw : Array(JSON::Any)) : Array(JSON::Any)
  raw.map do |item|
    obj = item.as_h.dup
    price = item["price"].as_f
    quantity = item["quantity"].as_i
    obj["total"] = JSON::Any.new((price * quantity * 100).round / 100)
    JSON::Any.new(obj)
  end
end

# Small dataset – processed per-request like Flask does
DATASET_ITEMS = begin
  if File.exists?(DATASET_PATH)
    Array(JSON::Any).from_json(File.read(DATASET_PATH))
  else
    nil
  end
rescue
  nil
end

# Large dataset – pre-process at startup, compress per-request
LARGE_PAYLOAD = begin
  if File.exists?(LARGE_DATASET_PATH)
    raw = Array(JSON::Any).from_json(File.read(LARGE_DATASET_PATH))
    items = process_items(raw)
    {items: items, count: items.size}.to_json
  else
    nil
  end
rescue
  nil
end

DB_AVAILABLE = File.exists?(DB_PATH)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

macro server_header(env)
  {{env}}.response.headers["Server"] = "kemal"
end

# Thread-local (fiber-local) DB connections
class DBPool
  @@connections = Hash(UInt64, DB::Database).new

  def self.get : DB::Database
    fid = Fiber.current.object_id
    @@connections[fid] ||= DB.open("sqlite3://#{DB_PATH}?mode=ro")
  end
end

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

get "/pipeline" do |env|
  server_header(env)
  env.response.content_type = "text/plain"
  "ok"
end

get "/baseline11" do |env|
  server_header(env)
  total = 0_i64
  env.params.query.each do |_key, value|
    total += value.to_i64 rescue next
  end
  env.response.content_type = "text/plain"
  total.to_s
end

post "/baseline11" do |env|
  server_header(env)
  total = 0_i64
  env.params.query.each do |_key, value|
    total += value.to_i64 rescue next
  end
  body = env.request.body.try(&.gets_to_end)
  if body && !body.empty?
    begin
      total += body.strip.to_i64
    rescue
    end
  end
  env.response.content_type = "text/plain"
  total.to_s
end

get "/baseline2" do |env|
  server_header(env)
  total = 0_i64
  env.params.query.each do |_key, value|
    total += value.to_i64 rescue next
  end
  env.response.content_type = "text/plain"
  total.to_s
end

get "/json" do |env|
  server_header(env)
  if items_raw = DATASET_ITEMS
    items = process_items(items_raw)
    env.response.content_type = "application/json"
    {items: items, count: items.size}.to_json
  else
    env.response.status_code = 500
    "No dataset"
  end
end

get "/compression" do |env|
  server_header(env)
  if payload = LARGE_PAYLOAD
    env.response.content_type = "application/json"
    env.response.headers["Content-Encoding"] = "gzip"
    Compress::Gzip::Writer.open(env.response, level: Compress::Gzip::BEST_SPEED) do |gz|
      gz.print payload
    end
    nil
  else
    env.response.status_code = 500
    "No dataset"
  end
end

get "/db" do |env|
  server_header(env)
  env.response.content_type = "application/json"

  unless DB_AVAILABLE
    next %({"items":[],"count":0})
  end

  min_val = (env.params.query["min"]?.try(&.to_f) || 10.0)
  max_val = (env.params.query["max"]?.try(&.to_f) || 50.0)

  db = DBPool.get
  items = [] of Hash(String, JSON::Any)

  db.query(DB_QUERY, min_val, max_val) do |rs|
    rs.each do
      item = Hash(String, JSON::Any).new
      item["id"] = JSON::Any.new(rs.read(Int64))
      item["name"] = JSON::Any.new(rs.read(String))
      item["category"] = JSON::Any.new(rs.read(String))
      item["price"] = JSON::Any.new(rs.read(Float64))
      item["quantity"] = JSON::Any.new(rs.read(Int64))
      item["active"] = JSON::Any.new(rs.read(Int64) != 0)
      tags_raw = rs.read(String)
      item["tags"] = JSON::Any.new(Array(JSON::Any).from_json(tags_raw))
      rating_score = rs.read(Float64)
      rating_count = rs.read(Int64)
      item["rating"] = JSON::Any.new({"score" => JSON::Any.new(rating_score), "count" => JSON::Any.new(rating_count)})
      items << item
    end
  end

  {items: items, count: items.size}.to_json
end

post "/upload" do |env|
  server_header(env)
  body = env.request.body.try(&.gets_to_end) || ""
  env.response.content_type = "text/plain"
  body.bytesize.to_s
end

# ---------------------------------------------------------------------------
# Server config
# ---------------------------------------------------------------------------

Kemal.config.port = 8080
Kemal.config.env = "production"
Kemal.config.shutdown_message = false
Kemal.config.logging = false

Kemal.run
