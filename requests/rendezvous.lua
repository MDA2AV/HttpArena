-- wrk script for the rendezvous profile: GET /rendezvous/{key}?v={value}.
--
-- Each thread numbers its requests and gives every two in a row the same key. A
-- connection holds one request at a time, and the first of a pair cannot be answered
-- until the second arrives, so the two always go out on different connections. Which
-- two is decided by which connections happen to be free, so a server cannot arrange
-- for a pair to land on the same worker: the key only shows up once they are both in.
--
-- Nothing can deadlock as long as a thread has two connections. Only the newest
-- request can be missing its partner, every older pair completes, and that frees a
-- connection to send the partner.
--
-- Keys are never reused: the nonce separates runs against the same container, so a
-- waiter left behind by the previous run's exit cannot pair with this run's request.

local threads = 0
local nonce = os.time()

function setup(thread)
  threads = threads + 1
  thread:set("id", threads)
  thread:set("nonce", nonce)
end

function init(args)
  prefix = "GET /rendezvous/" .. nonce .. "-" .. id .. "-"
  suffix = " HTTP/1.1\r\nHost: " .. wrk.host .. ":" .. wrk.port .. "\r\n\r\n"
  -- wrk calls request() once on the first thread to check the script, before any
  -- connection opens, and that call never reaches the server. Start one early there
  -- so it does not take the first half of a pair with it.
  n = (id == 1) and -1 or 0
end

request = function()
  local i = n
  n = n + 1
  return prefix .. math.floor(i / 2) .. "?v=" .. id .. "x" .. (i + 1) .. suffix
end
