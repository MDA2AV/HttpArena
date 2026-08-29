local lapis = require("lapis")
local json = require("cjson")

local function load_dataset()
  local path = os.getenv("DATASET_PATH") or "/data/dataset.json"
  local file = io.open(path, "r")
  if not file then
    return {}
  end
  local content = file:read("*a")
  file:close()
  local ok, decoded = pcall(json.decode, content)
  if not ok then
    return {}
  end
  return decoded
end

local dataset = load_dataset()

-- The request body, byte for byte. read_body() undoes the framing (a chunked
-- request included), after which the bytes are in memory unless they outgrew
-- client_body_buffer_size, in which case nginx spooled them to a temp file that
-- has to be read back. Lua strings are 8-bit clean, so binary survives both.
local function body_bytes()
  ngx.req.read_body()
  local data = ngx.req.get_body_data()
  if data then
    return data
  end
  local path = ngx.req.get_body_file()
  if not path then
    return ""
  end
  local file = io.open(path, "rb")
  if not file then
    return ""
  end
  local content = file:read("*a")
  file:close()
  return content or ""
end

local app = lapis.Application()

app:get("/pipeline", function(self)
  return { layout = false, content_type = "text/plain", "ok" }
end)

local function baseline11(self)
  local total = 0
  for _, value in pairs(self.params) do
    total = total + (tonumber(value) or 0)
  end
  if ngx.req.get_method() == "POST" then
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if body then
      total = total + (tonumber(body) or 0)
    end
  end
  return { layout = false, content_type = "text/plain", tostring(total) }
end

app:get("/baseline11", baseline11)
app:post("/baseline11", baseline11)

app:get("/json/:count", function(self)
  local count = tonumber(self.params.count) or 0
  if count < 0 then
    count = 0
  end
  if count > #dataset then
    count = #dataset
  end
  local m = tonumber(self.params.m) or 1

  local items = {}
  for i = 1, count do
    local source = dataset[i]
    local item = {}
    for key, value in pairs(source) do
      item[key] = value
    end
    item.total = source.price * source.quantity * m
    items[i] = item
  end

  return { json = { items = items, count = count } }
end)

app:post("/echo", function(self)
  return { layout = false, content_type = "application/octet-stream", body_bytes() }
end)

return app
