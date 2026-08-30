-- wrk Lua script: POST /echo with a rotating 10 KB body.
--
-- NOT the 8gbit profile's generator any more - that profile is driven by
-- zrk, paced, with a single body (see scripts/lib/tools/zrk.sh). This is kept
-- for open-loop testing by hand, where rotating bodies are still useful: with
-- one constant body a server could return a canned buffer of the right size
-- without ever reading the request, and rotating over eight makes that answer
-- wrong seven times out of eight.
--
-- Content-Length, not chunked: wrk frames the request body itself and always
-- emits Content-Length, and setting Transfer-Encoding as well produces a
-- request carrying both, which RFC 9112 6.1 makes an error. The chunked path
-- is covered by validate.sh instead.

local SIZE = 10240           -- 10 KB
local N    = 8

local bodies = {}
for i = 1, N do
  -- A distinct repeating unit per body, so the bytes differ throughout rather
  -- than only in a header. Truncated to exactly SIZE.
  local unit = string.format("8gbit-body-%d:", i)
  local reps = math.ceil(SIZE / #unit)
  bodies[i] = string.sub(string.rep(unit, reps), 1, SIZE)
end

wrk.method = "POST"
wrk.headers["Content-Type"] = "application/octet-stream"

local counter = 0

request = function()
  counter = counter + 1
  return wrk.format("POST", "/echo", nil, bodies[(counter % N) + 1])
end
