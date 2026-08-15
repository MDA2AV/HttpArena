## HttpArena entry for HttpBeast, the epoll HTTP server behind most of the Nim
## web stack (Jester and Prologue both run on it).
##
## HttpBeast gives one event loop per thread, each with its own SO_REUSEPORT
## listener, so the thread count is the CPU count and there is no cluster
## primary. Routing, JSON and gzip are written here because the server has
## none of them: it hands over a parsed request and takes back a response.

import std/[asyncdispatch, options, os, strutils, json, cpuinfo]
import httpbeast
import zippy

const
  hdrText = "Content-Type: text/plain"
  hdrJson = "Content-Type: application/json"
  hdrJsonGzip = "Content-Type: application/json\c\LContent-Encoding: gzip"

type Dataset = object
  ## prefix[i] is the item JSON up to `"total":`, factor[i] is price*quantity.
  ## A request only appends total and the closing brace.
  prefix: seq[string]
  factor: seq[int]

proc loadDataset(): Dataset =
  let path = getEnv("DATASET_PATH", "/data/dataset.json")
  var doc: JsonNode
  try:
    doc = parseJson(readFile(path))
  except CatchableError:
    return  # no dataset file: serve an empty list instead of dying
  if doc.kind != JArray:
    return
  for item in doc:
    if item.kind != JObject:
      continue
    var prefix = $item              # compact, and keeps the file's field order
    prefix.setLen(prefix.len - 1)   # drop the closing brace
    prefix.add(",\"total\":")
    result.prefix.add(prefix)
    result.factor.add(item{"price"}.getInt * item{"quantity"}.getInt)

# Read once, before any worker thread exists, and never written again.
let dataset = loadDataset()

proc parseIntIn(s: string, first, last: int, value: var int): bool =
  ## Leading integer of s[first ..< last]. Never raises: a parameter that is
  ## not a number is skipped, the same way the other entries skip a NaN.
  var i = first
  var negative = false
  if i < last and (s[i] == '-' or s[i] == '+'):
    negative = s[i] == '-'
    inc i
  var digits = 0
  var n = 0
  while i < last and s[i] in '0'..'9':
    if digits < 18:
      n = n * 10 + (ord(s[i]) - ord('0'))
    inc digits
    inc i
  if digits == 0 or digits > 18:
    return false
  value = if negative: -n else: n
  true

iterator queryPairs(target: string, qmark: int): (int, int, int) =
  ## Yields (nameStart, nameEnd, valueEnd) for every `name=value` in the query.
  if qmark >= 0:
    var i = qmark + 1
    while i < target.len:
      var stop = i
      while stop < target.len and target[stop] != '&': inc stop
      var eq = i
      while eq < stop and target[eq] != '=': inc eq
      if eq < stop:
        yield (i, eq, stop)
      i = stop + 1

proc sumQuery(target: string, qmark: int): int =
  for (nameStart, eq, stop) in queryPairs(target, qmark):
    var v = 0
    if parseIntIn(target, eq + 1, stop, v):
      result += v

proc queryInt(target: string, qmark: int, name: string, value: var int): bool =
  for (nameStart, eq, stop) in queryPairs(target, qmark):
    if eq - nameStart == name.len and target[nameStart ..< eq] == name:
      return parseIntIn(target, eq + 1, stop, value)

proc jsonBody(count, m: int): string {.gcsafe.} =
  # The cast is the dataset read: it is built before run() starts a thread and
  # never written afterwards, which Nim cannot prove on a global.
  {.cast(gcsafe).}:
    var n = count
    if n < 0: n = 0
    if n > dataset.prefix.len: n = dataset.prefix.len
    var size = 24
    for i in 0 ..< n:
      size += dataset.prefix[i].len + 24
    result = newStringOfCap(size)
    result.add("{\"items\":[")
    for i in 0 ..< n:
      if i > 0: result.add(',')
      result.add(dataset.prefix[i])
      result.addInt(dataset.factor[i] * m)
      result.add('}')
    result.add("],\"count\":")
    result.addInt(n)
    result.add('}')

proc acceptsGzip(req: Request): bool =
  let headers = req.headers
  if headers.isNone:
    return false
  let accepted: string = headers.get().getOrDefault("accept-encoding")
  result = accepted.toLowerAscii().contains("gzip")

proc onRequest(req: Request): Future[void] {.gcsafe.} =
  let httpMethod = req.httpMethod
  if httpMethod.isNone:
    return
  let target = req.path.get("")
  var qmark = -1
  for i in 0 ..< target.len:
    if target[i] == '?':
      qmark = i
      break
  let route = if qmark < 0: target else: target[0 ..< qmark]

  case httpMethod.get()
  of HttpGet:
    if route == "/pipeline":
      req.send(Http200, "ok", hdrText)
    elif route == "/baseline11":
      req.send(Http200, $sumQuery(target, qmark), hdrText)
    elif route.len > 6 and route.startsWith("/json/"):
      var count = 0
      discard parseIntIn(route, 6, route.len, count)
      var m = 0
      if not queryInt(target, qmark, "m", m) or m == 0:
        m = 1
      let body = jsonBody(count, m)
      # json-comp: httpbeast has no compression middleware, so gzip is done
      # here with zippy, only when the client asked for it.
      if acceptsGzip(req):
        req.send(Http200, compress(body, DefaultCompression, dfGzip), hdrJsonGzip)
      else:
        req.send(Http200, body, hdrJson)
    else:
      req.send(Http404)
  of HttpPost:
    if route == "/baseline11":
      var total = sumQuery(target, qmark)
      let body = req.body
      if body.isSome:
        let text = body.get().strip()
        var n = 0
        if parseIntIn(text, 0, text.len, n):
          total += n
      req.send(Http200, $total, hdrText)
    elif route == "/upload":
      let body = req.body
      req.send(Http200, $(if body.isSome: body.get().len else: 0), hdrText)
    else:
      req.send(Http404)
  else:
    req.send(Http404)

proc cpuCount(): int =
  ## Same shape as koa's getCPUCount: the cgroup quota when there is one,
  ## the host CPU count otherwise.
  try:
    let parts = readFile("/sys/fs/cgroup/cpu.max").strip().split(' ')
    if parts.len == 2 and parts[0] != "max":
      let n = parseInt(parts[0]) div parseInt(parts[1])
      if n >= 1: return n
  except CatchableError:
    discard
  try:
    let quota = parseInt(readFile("/sys/fs/cgroup/cpu/cpu.cfs_quota_us").strip())
    let period = parseInt(readFile("/sys/fs/cgroup/cpu/cpu.cfs_period_us").strip())
    if quota > 0 and period > 0 and quota div period >= 1:
      return quota div period
  except CatchableError:
    discard
  result = countProcessors()
  if result < 1:
    result = 1

when isMainModule:
  run(onRequest, initSettings(port = Port(8080), bindAddr = "0.0.0.0",
                              numThreads = cpuCount()))
