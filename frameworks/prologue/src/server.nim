import prologue
import std/[json, strutils, math, os, tables]
import std/db_sqlite
import std/zippy

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

proc parseQuerySum(query: string): int =
  result = 0
  for pair in query.split('&'):
    let parts = pair.split('=', 1)
    if parts.len == 2:
      try:
        result += parseInt(parts[1])
      except ValueError:
        discard

proc pipelineHandler(ctx: Context) {.async.} =
  ctx.response.setHeader("Content-Type", "text/plain")
  resp "ok"

proc baseline11Handler(ctx: Context) {.async.} =
  var sum = 0
  let query = ctx.request.query
  if query.len > 0:
    sum = parseQuerySum(query)

  let body = ctx.request.body
  if body.len > 0:
    try:
      sum += parseInt(body.strip())
    except ValueError:
      discard

  ctx.response.setHeader("Content-Type", "text/plain")
  resp $sum

proc baseline2Handler(ctx: Context) {.async.} =
  var sum = 0
  let query = ctx.request.query
  if query.len > 0:
    sum = parseQuerySum(query)
  ctx.response.setHeader("Content-Type", "text/plain")
  resp $sum

proc jsonHandler(ctx: Context) {.async.} =
  let jsonStr = buildProcessedJson(dataset)
  ctx.response.setHeader("Content-Type", "application/json")
  resp jsonStr

proc compressionHandler(ctx: Context) {.async.} =
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

proc uploadHandler(ctx: Context) {.async.} =
  let body = ctx.request.body
  ctx.response.setHeader("Content-Type", "text/plain")
  resp $body.len

proc dbHandler(ctx: Context) {.async.} =
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

proc staticHandler(ctx: Context) {.async.} =
  let filename = ctx.getPathParams("filename")
  if filename in staticFiles:
    let (data, ct) = staticFiles[filename]
    ctx.response.setHeader("Content-Type", ct)
    resp data
  else:
    resp Http404

# Set up and run
loadDataset()
loadDatasetLarge()
loadStaticFiles()
loadDb()

let settings = newSettings(
  port = Port(8080),
  debug = false,
  address = "0.0.0.0"
)

var app = newApp(settings = settings)

proc addServerHeader(ctx: Context) {.async.} =
  ctx.response.setHeader("Server", "prologue")
  await switch(ctx)

app.use(addServerHeader)

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
