import prologue
import std/[json, strutils, math, os, tables, posix]
import db_connector/db_sqlite
import zippy

type
  Rating = object
    score: float
    count: int

  DatasetItem = object
    id: int
    name: string
    category: string
    price: float
    quantity: int
    active: bool
    tags: seq[string]
    rating: Rating

var dataset: seq[DatasetItem]
var jsonLargeResponse: string
var staticFiles: Table[string, (string, string)] # filename -> (data, content_type)
var db: DbConn
var dbAvailable: bool

proc getMime(ext: string): string =
  case ext
  of ".css": "text/css"
  of ".js": "application/javascript"
  of ".html": "text/html"
  of ".woff2": "font/woff2"
  of ".svg": "image/svg+xml"
  of ".webp": "image/webp"
  of ".json": "application/json"
  else: "application/octet-stream"

proc loadDataset() =
  let path = getEnv("DATASET_PATH", "/data/dataset.json")
  if not fileExists(path):
    return
  let data = readFile(path)
  let j = parseJson(data)
  dataset = @[]
  for item in j:
    var tags: seq[string] = @[]
    for tag in item["tags"]:
      tags.add(tag.getStr())
    dataset.add(DatasetItem(
      id: item["id"].getInt(),
      name: item["name"].getStr(),
      category: item["category"].getStr(),
      price: item["price"].getFloat(),
      quantity: item["quantity"].getInt(),
      active: item["active"].getBool(),
      tags: tags,
      rating: Rating(
        score: item["rating"]["score"].getFloat(),
        count: item["rating"]["count"].getInt()
      )
    ))

proc buildProcessedJson(items: seq[DatasetItem]): string =
  var processed = newJArray()
  for d in items:
    let total = round(d.price * float(d.quantity) * 100.0) / 100.0
    var tagsArr = newJArray()
    for t in d.tags:
      tagsArr.add(newJString(t))
    processed.add(%*{
      "id": d.id,
      "name": d.name,
      "category": d.category,
      "price": d.price,
      "quantity": d.quantity,
      "active": d.active,
      "tags": tagsArr,
      "rating": {"score": d.rating.score, "count": d.rating.count},
      "total": total
    })
  result = $(%*{"items": processed, "count": processed.len})

proc loadDatasetLarge() =
  let path = "/data/dataset-large.json"
  if not fileExists(path):
    return
  let data = readFile(path)
  let j = parseJson(data)
  var items: seq[DatasetItem] = @[]
  for item in j:
    var tags: seq[string] = @[]
    for tag in item["tags"]:
      tags.add(tag.getStr())
    items.add(DatasetItem(
      id: item["id"].getInt(),
      name: item["name"].getStr(),
      category: item["category"].getStr(),
      price: item["price"].getFloat(),
      quantity: item["quantity"].getInt(),
      active: item["active"].getBool(),
      tags: tags,
      rating: Rating(
        score: item["rating"]["score"].getFloat(),
        count: item["rating"]["count"].getInt()
      )
    ))
  jsonLargeResponse = buildProcessedJson(items)

proc loadStaticFiles() =
  let dir = "/data/static"
  if not dirExists(dir):
    return
  for kind, path in walkDir(dir):
    if kind == pcFile:
      let filename = extractFilename(path)
      let data = readFile(path)
      let ext = if '.' in filename: filename[filename.rfind('.') .. ^1] else: ""
      let ct = getMime(ext)
      staticFiles[filename] = (data, ct)

proc loadDb() =
  try:
    db = open("/data/benchmark.db", "", "", "")
    dbAvailable = true
  except:
    dbAvailable = false

const validMethodStrs = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]

proc getBody(ctx: Context): string =
  ## Get request body — asynchttpserver already decodes chunked transfer-encoding
  return ctx.request.body

proc parseQuerySum(query: string): int =
  result = 0
  for pair in query.split('&'):
    let parts = pair.split('=', 1)
    if parts.len == 2:
      try:
        result += parseInt(parts[1])
      except ValueError:
        discard

let pipelineHandler: HandlerAsync = proc(ctx: Context) {.async, closure, gcsafe.} =
  ctx.response.setHeader("Content-Type", "text/plain")
  resp "ok"

let baseline11Handler: HandlerAsync = proc(ctx: Context) {.async, closure, gcsafe.} =
  var sum = 0
  let query = ctx.request.query
  if query.len > 0:
    sum = parseQuerySum(query)

  let body = getBody(ctx)
  if body.len > 0:
    try:
      sum += parseInt(body.strip())
    except ValueError:
      discard

  ctx.response.setHeader("Content-Type", "text/plain")
  resp $sum

let baseline2Handler: HandlerAsync = proc(ctx: Context) {.async, closure, gcsafe.} =
  var sum = 0
  let query = ctx.request.query
  if query.len > 0:
    sum = parseQuerySum(query)
  ctx.response.setHeader("Content-Type", "text/plain")
  resp $sum

let jsonHandler: HandlerAsync = proc(ctx: Context) {.async, closure, gcsafe.} =
  {.cast(gcsafe).}:
    let jsonStr = buildProcessedJson(dataset)
    ctx.response.setHeader("Content-Type", "application/json")
    resp jsonStr

let compressionHandler: HandlerAsync = proc(ctx: Context) {.async, closure, gcsafe.} =
  {.cast(gcsafe).}:
    let headers = ctx.request.headers
    let acceptEncoding = if headers.hasKey("Accept-Encoding"): $headers["Accept-Encoding"] else: ""
    ctx.response.setHeader("Content-Type", "application/json")
    if "gzip" in acceptEncoding:
      let compressed = compress(jsonLargeResponse, BestSpeed, dfGzip)
      ctx.response.setHeader("Content-Encoding", "gzip")
      resp compressed
    elif "deflate" in acceptEncoding:
      let compressed = compress(jsonLargeResponse, BestSpeed, dfDeflate)
      ctx.response.setHeader("Content-Encoding", "deflate")
      resp compressed
    else:
      resp jsonLargeResponse

let uploadHandler: HandlerAsync = proc(ctx: Context) {.async, closure, gcsafe.} =
  let body = getBody(ctx)
  ctx.response.setHeader("Content-Type", "text/plain")
  resp $body.len

let dbHandler: HandlerAsync = proc(ctx: Context) {.async, closure, gcsafe.} =
  {.cast(gcsafe).}:
    if not dbAvailable:
      ctx.response.setHeader("Content-Type", "application/json")
      resp "{\"items\":[],\"count\":0}"
      return

    let minPrice = try: parseFloat(ctx.getQueryParams("min", "10")) except ValueError: 10.0
    let maxPrice = try: parseFloat(ctx.getQueryParams("max", "50")) except ValueError: 50.0

    var items = newJArray()
    try:
      let rows = db.getAllRows(sql"SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50",
        $minPrice, $maxPrice)
      for row in rows:
        let tagsJson = try: parseJson(row[6]) except JsonParsingError: newJArray()
        items.add(%*{
          "id": parseInt(row[0]),
          "name": row[1],
          "category": row[2],
          "price": parseFloat(row[3]),
          "quantity": parseInt(row[4]),
          "active": parseInt(row[5]) == 1,
          "tags": tagsJson,
          "rating": {"score": parseFloat(row[7]), "count": parseInt(row[8])}
        })
    except:
      discard

    ctx.response.setHeader("Content-Type", "application/json")
    resp $(%*{"items": items, "count": items.len})

let staticHandler: HandlerAsync = proc(ctx: Context) {.async, closure, gcsafe.} =
  {.cast(gcsafe).}:
    let filename = ctx.getPathParams("filename")
    if filename in staticFiles:
      let (data, ct) = staticFiles[filename]
      ctx.response.setHeader("Content-Type", ct)
      resp data
    else:
      resp "Not Found", Http404

# ---------------------------------------------------------------------------
# Multi-process setup via SO_REUSEPORT + posix fork
# ---------------------------------------------------------------------------

proc getCpuCount(): int =
  try:
    result = parseInt(getEnv("NPROC", "0"))
    if result > 0:
      return result
  except:
    discard
  # Read from /proc/cpuinfo
  try:
    var count = 0
    for line in lines("/proc/cpuinfo"):
      if line.len >= 9 and line[0..8] == "processor":
        inc count
    result = max(1, count)
  except:
    result = 1

proc startWorker() =
  # Each worker loads data independently (post-fork, clean state)
  loadDataset()
  loadDatasetLarge()
  loadStaticFiles()
  loadDb()

  let settings = newSettings(
    port = Port(8080),
    debug = false,
    reusePort = true,
    address = "0.0.0.0"
  )
  # Set maxBody under the "prologue" key where asynchttpserver reads it
  # Default is 8MB (8388608) which is too small for the ~20MB upload benchmark
  settings["prologue"]["maxBody"] = newJInt(33554432)  # 32MB

  var app = newApp(settings = settings)

  let methodValidationMiddleware: HandlerAsync = proc(ctx: Context) {.async, closure, gcsafe.} =
    let methStr = $ctx.request.reqMethod
    if methStr notin validMethodStrs:
      ctx.response.setHeader("Content-Type", "text/plain")
      resp "Method Not Allowed", Http405
      return
    await switch(ctx)

  let serverHeaderMiddleware: HandlerAsync = proc(ctx: Context) {.async, closure, gcsafe.} =
    ctx.response.setHeader("Server", "prologue")
    await switch(ctx)

  app.use(methodValidationMiddleware)
  app.use(serverHeaderMiddleware)

  app.addRoute("/pipeline", pipelineHandler, HttpGet)
  app.addRoute("/baseline11", baseline11Handler, HttpGet)
  app.addRoute("/baseline11", baseline11Handler, HttpPost)
  app.addRoute("/baseline2", baseline2Handler, HttpGet)
  app.addRoute("/json", jsonHandler, HttpGet)
  app.addRoute("/compression", compressionHandler, HttpGet)
  app.addRoute("/upload", uploadHandler, HttpPost)
  app.addRoute("/db", dbHandler, HttpGet)
  app.addRoute("/static/{filename}", staticHandler, HttpGet)

  app.run()

var gChildPids: array[1024, Pid]
var gChildCount: int = 0

proc handleSignal(sig: cint) {.noconv.} =
  for i in 0 ..< gChildCount:
    discard kill(gChildPids[i], SIGTERM)
  quit(0)

let workerCount = getCpuCount()

if workerCount > 1:
  for i in 0 ..< workerCount:
    let pid = fork()
    if pid == 0:
      # Child process — run the server
      startWorker()
      quit(0)
    elif pid > 0:
      gChildPids[gChildCount] = pid
      inc gChildCount
    else:
      echo "Fork failed for worker ", i
      quit(1)

  # Parent process — handle signals and wait for children
  var sa: Sigaction
  sa.sa_handler = handleSignal
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  discard sigaction(SIGINT, sa, nil)
  discard sigaction(SIGTERM, sa, nil)

  while true:
    var status: cint
    let pid = wait(addr status)
    if pid < 0:
      break
else:
  startWorker()
