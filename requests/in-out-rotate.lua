-- wrk Lua script for the in-out profile.
--
-- POST /echo with a 100 KB body; the server returns it verbatim, so every
-- request moves 100 KB in and 100 KB out. Content-Length both ways: wrk frames
-- the request body itself and always emits Content-Length, so a chunked
-- variant is not expressible here (setting Transfer-Encoding as well produces a
-- request carrying both, which RFC 9112 6.1 makes an error). The chunked path
-- is covered by validate.sh instead.
--
-- Eight distinct bodies rather than one: with a single constant body a server
-- could return a canned 100 KB response without ever reading the request, and
-- the measurement would not notice. Rotating over eight makes that answer wrong
-- seven times out of eight. They are built once per thread, not per request.

local SIZE = 102400          -- 100 KB
local N    = 8

local bodies = {}
for i = 1, N do
  -- A distinct repeating unit per body, so the bytes differ throughout rather
  -- than only in a header. Truncated to exactly SIZE.
  local unit = string.format("in-out-body-%d:", i)
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
