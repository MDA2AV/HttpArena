import Foundation
import Hummingbird
import HummingbirdCompression
import NIOCore

#if canImport(CSQLite)
import CSQLite
#elseif canImport(SQLite3)
import SQLite3
#endif

// MARK: - Data Models

struct Rating: Codable, Sendable {
    let score: Double
    let count: Int
}

struct DatasetItem: Codable, Sendable {
    let id: Int
    let name: String
    let category: String
    let price: Double
    let quantity: Int
    let active: Bool
    let tags: [String]
    let rating: Rating
}

struct ProcessedItem: Codable, Sendable {
    let id: Int
    let name: String
    let category: String
    let price: Double
    let quantity: Int
    let active: Bool
    let tags: [String]
    let rating: Rating
    let total: Double
}

struct JsonResponse: Codable, Sendable {
    let items: [ProcessedItem]
    let count: Int
}

// MARK: - State

final class AppState: Sendable {
    let dataset: [DatasetItem]
    let jsonCache: [UInt8]
    let jsonLargeCache: [UInt8]
    let staticFiles: [String: StaticFile]
    let dbPath: String
    let dbAvailable: Bool

    init(dataset: [DatasetItem], jsonCache: [UInt8], jsonLargeCache: [UInt8],
         staticFiles: [String: StaticFile], dbPath: String, dbAvailable: Bool) {
        self.dataset = dataset
        self.jsonCache = jsonCache
        self.jsonLargeCache = jsonLargeCache
        self.staticFiles = staticFiles
        self.dbPath = dbPath
        self.dbAvailable = dbAvailable
    }
}

struct StaticFile: Sendable {
    let data: [UInt8]
    let contentType: String
}

// MARK: - Helpers

func loadDataset(path: String) -> [DatasetItem] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    return (try? JSONDecoder().decode([DatasetItem].self, from: data)) ?? []
}

func buildJsonCache(_ items: [DatasetItem]) -> [UInt8] {
    let processed = items.map { item in
        ProcessedItem(
            id: item.id, name: item.name, category: item.category,
            price: item.price, quantity: item.quantity, active: item.active,
            tags: item.tags, rating: item.rating,
            total: (item.price * Double(item.quantity) * 100.0).rounded() / 100.0
        )
    }
    let resp = JsonResponse(items: processed, count: processed.count)
    let data = (try? JSONEncoder().encode(resp)) ?? Data()
    return [UInt8](data)
}

func loadStaticFiles() -> [String: StaticFile] {
    var files: [String: StaticFile] = [:]
    let dir = "/data/static"
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return files }
    for name in entries {
        let path = "\(dir)/\(name)"
        guard let data = FileManager.default.contents(atPath: path) else { continue }
        let ext = (name as NSString).pathExtension
        let ct: String
        switch ext {
        case "css": ct = "text/css"
        case "js": ct = "application/javascript"
        case "html": ct = "text/html"
        case "woff2": ct = "font/woff2"
        case "svg": ct = "image/svg+xml"
        case "webp": ct = "image/webp"
        case "json": ct = "application/json"
        default: ct = "application/octet-stream"
        }
        files[name] = StaticFile(data: [UInt8](data), contentType: ct)
    }
    return files
}

func parseQuerySum(_ query: String) -> Int {
    var sum = 0
    for pair in query.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        if parts.count == 2, let n = Int(parts[1]) {
            sum += n
        }
    }
    return sum
}

func parseQueryParam(_ query: String, key: String) -> Double? {
    for pair in query.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        if kv.count == 2, kv[0] == key {
            return Double(kv[1])
        }
    }
    return nil
}

// Simple SQLite query helper
func queryDb(dbPath: String, minPrice: Double, maxPrice: Double) -> [UInt8] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        return [UInt8](#"{"items":[],"count":0}"#.utf8)
    }
    defer { sqlite3_close(db) }

    sqlite3_exec(db, "PRAGMA mmap_size=268435456", nil, nil, nil)

    var stmt: OpaquePointer?
    let sql = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ?1 AND ?2 LIMIT 50"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        return [UInt8](#"{"items":[],"count":0}"#.utf8)
    }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_double(stmt, 1, minPrice)
    sqlite3_bind_double(stmt, 2, maxPrice)

    var items: [[String: Any]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let id = sqlite3_column_int64(stmt, 0)
        let name = String(cString: sqlite3_column_text(stmt, 1))
        let category = String(cString: sqlite3_column_text(stmt, 2))
        let price = sqlite3_column_double(stmt, 3)
        let quantity = sqlite3_column_int64(stmt, 4)
        let active = sqlite3_column_int64(stmt, 5) == 1
        let tagsStr = String(cString: sqlite3_column_text(stmt, 6))
        let tags = (try? JSONSerialization.jsonObject(with: Data(tagsStr.utf8))) ?? []
        let ratingScore = sqlite3_column_double(stmt, 7)
        let ratingCount = sqlite3_column_int64(stmt, 8)

        let item: [String: Any] = [
            "id": id,
            "name": name,
            "category": category,
            "price": price,
            "quantity": quantity,
            "active": active,
            "tags": tags,
            "rating": ["score": ratingScore, "count": ratingCount] as [String: Any],
        ]
        items.append(item)
    }

    let response: [String: Any] = ["items": items, "count": items.count]
    guard let jsonData = try? JSONSerialization.data(withJSONObject: response) else {
        return [UInt8](#"{"items":[],"count":0}"#.utf8)
    }
    return [UInt8](jsonData)
}

// MARK: - Main

let datasetPath = ProcessInfo.processInfo.environment["DATASET_PATH"] ?? "/data/dataset.json"
let dataset = loadDataset(path: datasetPath)
let jsonCache = buildJsonCache(dataset)

let largeDataset = loadDataset(path: "/data/dataset-large.json")
let jsonLargeCache = buildJsonCache(largeDataset)

let dbPath = "/data/benchmark.db"
let dbAvailable = FileManager.default.fileExists(atPath: dbPath)

let state = AppState(
    dataset: dataset,
    jsonCache: jsonCache,
    jsonLargeCache: jsonLargeCache,
    staticFiles: loadStaticFiles(),
    dbPath: dbPath,
    dbAvailable: dbAvailable
)

let router = Router()

// Add response compression (only activates when client sends accept-encoding)
router.middlewares.add(ResponseCompressionMiddleware(minimumResponseSizeToCompress: 512))

// Server header middleware
struct ServerHeaderMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        var response = try await next(request, context)
        response.headers[.server] = "hummingbird"
        return response
    }
}
router.middlewares.add(ServerHeaderMiddleware())

// GET /pipeline
router.get("pipeline") { _, _ -> Response in
    Response(
        status: .ok,
        headers: [.contentType: "text/plain"],
        body: .init(byteBuffer: ByteBuffer(string: "ok"))
    )
}

// GET /baseline11
router.get("baseline11") { request, _ -> Response in
    let sum = request.uri.query.map(parseQuerySum) ?? 0
    return Response(
        status: .ok,
        headers: [.contentType: "text/plain"],
        body: .init(byteBuffer: ByteBuffer(string: "\(sum)"))
    )
}

// POST /baseline11
router.post("baseline11") { request, _ -> Response in
    var sum = request.uri.query.map(parseQuerySum) ?? 0
    let body = try await request.body.collect(upTo: 1_048_576)
    if let bodyStr = body.getString(at: body.readerIndex, length: body.readableBytes),
       let n = Int(bodyStr.trimmingCharacters(in: .whitespacesAndNewlines))
    {
        sum += n
    }
    return Response(
        status: .ok,
        headers: [.contentType: "text/plain"],
        body: .init(byteBuffer: ByteBuffer(string: "\(sum)"))
    )
}

// GET /baseline2
router.get("baseline2") { request, _ -> Response in
    let sum = request.uri.query.map(parseQuerySum) ?? 0
    return Response(
        status: .ok,
        headers: [.contentType: "text/plain"],
        body: .init(byteBuffer: ByteBuffer(string: "\(sum)"))
    )
}

// GET /json
router.get("json") { _, _ -> Response in
    if state.dataset.isEmpty {
        return Response(status: .internalServerError)
    }
    let jsonBytes = buildJsonCache(state.dataset)
    return Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(bytes: jsonBytes))
    )
}

// GET /compression — returns large JSON; ResponseCompressionMiddleware handles gzip
router.get("compression") { _, _ -> Response in
    let jsonBytes = buildJsonCache(state.largeDataset)
    return Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(bytes: jsonBytes))
    )
}

// POST /upload
router.post("upload") { request, _ -> Response in
    let body = try await request.body.collect(upTo: 25 * 1024 * 1024)
    let size = body.readableBytes
    return Response(
        status: .ok,
        headers: [.contentType: "text/plain"],
        body: .init(byteBuffer: ByteBuffer(string: "\(size)"))
    )
}

// GET /db
router.get("db") { request, _ -> Response in
    guard state.dbAvailable else {
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: #"{"items":[],"count":0}"#))
        )
    }
    let query = request.uri.query ?? ""
    let minPrice = parseQueryParam(query, key: "min") ?? 10.0
    let maxPrice = parseQueryParam(query, key: "max") ?? 50.0
    let result = queryDb(dbPath: state.dbPath, minPrice: minPrice, maxPrice: maxPrice)
    return Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(bytes: result))
    )
}

// GET /static/{filename}
router.get("static/{filename}") { _, context -> Response in
    let filename = context.parameters.get("filename") ?? ""
    guard let file = state.staticFiles[filename] else {
        return Response(status: .notFound)
    }
    return Response(
        status: .ok,
        headers: [.contentType: file.contentType],
        body: .init(byteBuffer: ByteBuffer(bytes: file.data))
    )
}

// Start server
let app = Application(
    router: router,
    configuration: .init(address: .hostname("0.0.0.0", port: 8080))
)

try await app.runService()
