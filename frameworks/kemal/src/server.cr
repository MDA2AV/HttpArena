require "kemal"

# ── Dataset ─────────────────────────────────────────────────────────────────

struct Rating
  include JSON::Serializable

  getter score : Int64
  getter count : Int64
end

struct Item
  include JSON::Serializable

  getter id : Int64
  getter name : String
  getter category : String
  getter price : Int64
  getter quantity : Int64
  getter active : Bool
  getter tags : Array(String)
  getter rating : Rating

  # Stored fields as they are, rating still nested, then the computed total.
  def write(json : JSON::Builder, m : Int64) : Nil
    json.object do
      json.field "id", @id
      json.field "name", @name
      json.field "category", @category
      json.field "price", @price
      json.field "quantity", @quantity
      json.field "active", @active
      json.field "tags", @tags
      json.field "rating", @rating
      json.field "total", @price * @quantity * m
    end
  end
end

# A missing or unreadable file serves an empty list, it never stops the server.
def load_items : Array(Item)
  Array(Item).from_json(File.read(ENV["DATASET_PATH"]? || "/data/dataset.json"))
rescue
  [] of Item
end

ITEMS = load_items

# ── Worker count ────────────────────────────────────────────────────────────
#
# Crystal serves on one thread, so the server runs one process per core and
# they all accept on the same port through SO_REUSEPORT. The count comes from
# the container limits first, the host only when there is no limit set.

private def read_first_line(path : String) : String?
  File.read(path).strip
rescue
  nil
end

# cgroup v2 cpu.max, then the v1 pair. This is what `docker run --cpus` sets.
private def cgroup_quota : Int32?
  if line = read_first_line("/sys/fs/cgroup/cpu.max")
    parts = line.split(' ')
    if parts.size == 2 && parts[0] != "max"
      quota = parts[0].to_i64?
      period = parts[1].to_i64?
      if quota && period && quota > 0 && period > 0
        n = (quota // period).to_i32
        return n if n >= 1
      end
    end
  end

  quota = read_first_line("/sys/fs/cgroup/cpu/cpu.cfs_quota_us").try &.to_i64?
  period = read_first_line("/sys/fs/cgroup/cpu/cpu.cfs_period_us").try &.to_i64?
  if quota && period && quota > 0 && period > 0
    n = (quota // period).to_i32
    return n if n >= 1
  end

  nil
end

# The cpu list of the cgroup, "0-31,64-95" style. This is `--cpuset-cpus`,
# which the benchmark uses and which the quota above does not cover.
private def cgroup_cpuset : Int32?
  list = read_first_line("/sys/fs/cgroup/cpuset.cpus.effective") ||
         read_first_line("/sys/fs/cgroup/cpuset/cpuset.cpus")
  return nil if list.nil? || list.empty?

  total = 0
  list.split(',') do |part|
    if part.includes?('-')
      low, _, high = part.partition('-')
      l = low.to_i?
      h = high.to_i?
      total += h - l + 1 if l && h && h >= l
    elsif part.to_i?
      total += 1
    end
  end
  total > 0 ? total : nil
end

def worker_count : Int32
  cgroup_quota || cgroup_cpuset || System.cpu_count.to_i32
end

# ── Routes ──────────────────────────────────────────────────────────────────

def sum_query(params : HTTP::Params) : Int64
  sum = 0_i64
  params.each do |_, value|
    if n = value.to_i64?
      sum += n
    end
  end
  sum
end

get "/pipeline" do |env|
  env.response.content_type = "text/plain"
  "ok"
end

get "/baseline11" do |env|
  env.response.content_type = "text/plain"
  sum_query(env.params.query).to_s
end

post "/baseline11" do |env|
  total = sum_query(env.params.query)
  # Read the raw stream: the body is a bare number, not a form or a document
  if body = env.request.body
    if n = body.gets_to_end.strip.to_i64?
      total += n
    end
  end
  env.response.content_type = "text/plain"
  total.to_s
end

get "/json/:count" do |env|
  count = env.params.url["count"].to_i? || 0
  count = 0 if count < 0
  count = ITEMS.size if count > ITEMS.size
  m = env.params.query["m"]?.try(&.to_i64?) || 1_i64

  env.response.content_type = "application/json"
  # Straight into the response, so the items are never held twice in memory.
  # gzip, when the request asks for it, is the handler `gzip true` installs.
  JSON.build(env.response) do |json|
    json.object do
      json.field "items" do
        json.array do
          count.times { |i| ITEMS[i].write(json, m) }
        end
      end
      json.field "count", count
    end
  end
  nil
end

post "/upload" do |env|
  received = 0_i64
  if body = env.request.body
    buffer = Bytes.new(64 * 1024)
    while (read = body.read(buffer)) > 0
      received += read
    end
  end
  env.response.content_type = "text/plain"
  received.to_s
end

# ── Server ──────────────────────────────────────────────────────────────────

def serve
  logging false
  serve_static false
  gzip true
  Kemal.config.env = "production"
  Kemal.config.powered_by_header = false

  Kemal.run do |config|
    # Binding here keeps Kemal from binding itself, which is how the workers
    # get reuse_port and share the accept queue of port 8080.
    config.server.not_nil!.bind_tcp("0.0.0.0", 8080, reuse_port: true)
  end
end

workers = worker_count

if ENV["KEMAL_WORKER"]? || workers <= 1
  serve
else
  children = Array(Process).new(workers)
  workers.times do
    children << Process.new(
      Process.executable_path || "/server",
      env: {"KEMAL_WORKER" => "1"},
      input: Process::Redirect::Inherit,
      output: Process::Redirect::Inherit,
      error: Process::Redirect::Inherit
    )
  end

  Process.on_terminate do
    children.each { |child| child.terminate rescue nil }
    exit
  end

  children.each { |child| child.wait rescue nil }
end
