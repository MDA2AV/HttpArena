-- wrk Lua script for the echo-100k profile.
--
-- EXPERIMENT: the body is 10 KB here, not 100 KB. The profile name is unchanged
-- on purpose so the result lands in the same row and can be compared directly.
-- The point is .NET's Large Object Heap threshold, 85,000 bytes: at 100 KB every
-- per-request body buffer is an LOH allocation (gen2 collections, no compaction),
-- at 10 KB none of them are. If the C# entries jump, that is the cause.
--
-- POST /echo with the body below; the server returns it verbatim, so every
-- request moves that many bytes in and the same back out. Content-Length both ways: wrk frames
-- the request body itself and always emits Content-Length, so a chunked
-- variant is not expressible here (setting Transfer-Encoding as well produces a
-- request carrying both, which RFC 9112 6.1 makes an error). The chunked path
-- is covered by validate.sh instead.
--
-- Eight distinct bodies rather than one: with a single constant body a server
-- could return a canned 100 KB response without ever reading the request, and
-- the measurement would not notice. Rotating over eight makes that answer wrong
-- seven times out of eight. They are built once per thread, not per request.

local SIZE = 10240           -- 10 KB (was 102400)
local N    = 8

local bodies = {}
for i = 1, N do
  -- A distinct repeating unit per body, so the bytes differ throughout rather
  -- than only in a header. Truncated to exactly SIZE.
  local unit = string.format("echo-100k-body-%d:", i)
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
