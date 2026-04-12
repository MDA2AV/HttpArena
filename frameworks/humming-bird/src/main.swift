import Foundation
import Hummingbird
import HummingbirdCompression
import NIOCore
import NIOFoundationCompat
import PostgresNIO

#if canImport(CSQLite)
    import CSQLite
#elseif canImport(SQLite3)
    import SQLite3
#endif

// MARK: - Data Models

struct Rating: Codable, Sendable {
    let score: Int
    let count: Int
}

struct DatasetItem: Codable, Sendable {
    let id: Int
    let name: String
    let category: String
    let price: Int
    let quantity: Int
    let active: Bool
    let tags: [String]
    let rating: Rating
}

struct ProcessedItem: Codable, Sendable {
    let id: Int
    let name: String
    let category: String
    let price: Int
    let quantity: Int
    let active: Bool
    let tags: [String]
    let rating: Rating
    let total: Int
}

struct JsonResponse: Codable, Sendable {
    let items: [ProcessedItem]
    let count: Int
}

// MARK: - State

final class AppState: Sendable {
    let dataset: [DatasetItem]
    let staticFiles: [String: StaticFile]
    let dbPath: String
    let dbAvailable: Bool

    init(
        dataset: [DatasetItem],
        staticFiles: [String: StaticFile],
        dbPath: String,
        dbAvailable: Bool
    ) {
        self.dataset = dataset
        self.staticFiles = staticFiles
        self.dbPath = dbPath
        self.dbAvailable = dbAvailable
    }
}

struct StaticFile: Sendable {
    let data: ByteBuffer
    let contentType: String
    let br: ByteBuffer?
    let gz: ByteBuffer?
}

// MARK: - Helpers

func loadDataset(path: String) -> [DatasetItem] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    return (try? JSONDecoder().decode([DatasetItem].self, from: data)) ?? []
}

func parseQueryIntParam(_ query: String, key: String) -> Int? {
    for pair in query.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        if kv.count == 2, kv[0] == key {
            return Int(kv[1])
        }
    }
    return nil
}

func loadStaticFiles() -> [String: StaticFile] {
    var files: [String: StaticFile] = [:]
    let dir = "/data/static"
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
        return files
    }
    for name in entries {
        if name.hasSuffix(".br") || name.hasSuffix(".gz") { continue }
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
        let brData = FileManager.default.contents(atPath: path + ".br")
        let gzData = FileManager.default.contents(atPath: path + ".gz")
        files[name] = StaticFile(
            data: ByteBuffer(data: data),
            contentType: ct,
            br: brData.map { ByteBuffer(data: $0) },
            gz: gzData.map { ByteBuffer(data: $0) }
        )
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

func parseQueryParam(_ query: String, key: String) -> Int? {
    for pair in query.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        if kv.count == 2, kv[0] == key {
            return Int(kv[1])
        }
    }
    return nil
}

// Simple SQLite query helper
func queryDb(dbPath: String, minPrice: Int, maxPrice: Int) -> [UInt8] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        return [UInt8](#"{"items":[],"count":0}"#.utf8)
    }
    defer { sqlite3_close(db) }

    sqlite3_exec(db, "PRAGMA mmap_size=268435456", nil, nil, nil)

    var stmt: OpaquePointer?
    let sql =
        "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ?1 AND ?2 LIMIT 50"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        return [UInt8](#"{"items":[],"count":0}"#.utf8)
    }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_int64(stmt, 1, Int64(minPrice))
    sqlite3_bind_int64(stmt, 2, Int64(maxPrice))

    var items: [[String: Any]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let id = sqlite3_column_int64(stmt, 0)
        let name = String(cString: sqlite3_column_text(stmt, 1))
        let category = String(cString: sqlite3_column_text(stmt, 2))
        let price = Int(sqlite3_column_int64(stmt, 3))
        let quantity = sqlite3_column_int64(stmt, 4)
        let active = sqlite3_column_int64(stmt, 5) == 1
        let tagsStr = String(cString: sqlite3_column_text(stmt, 6))
        let tags = (try? JSONSerialization.jsonObject(with: Data(tagsStr.utf8))) ?? []
        let ratingScore = Int(sqlite3_column_int64(stmt, 7))
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

// MARK: - Postgres

func parseDatabaseURL(_ url: String) -> PostgresClient.Configuration? {
    guard let u = URL(string: url.replacingOccurrences(of: "postgres://", with: "postgresql://"))
    else { return nil }
    let user = u.user ?? "bench"
    let password = u.password ?? "bench"
    let host = u.host ?? "localhost"
    let port = u.port ?? 5432
    let database = String(u.path.dropFirst())
    let config = PostgresClient.Configuration(
        host: host, port: port, username: user, password: password, database: database,
        tls: .disable
    )
    return config
}

func queryPgDb(client: PostgresClient, minPrice: Int, maxPrice: Int, limit: Int) async -> [UInt8] {
    do {
        let rows = try await client.query(
            "SELECT id, name, category, price, quantity, active, tags::text, rating_score, rating_count FROM items WHERE price BETWEEN \(minPrice) AND \(maxPrice) LIMIT \(limit)"
        )
        var items: [[String: Any]] = []
        for try await row in rows {
            let (id, name, category, price, quantity, active, tagsStr, ratingScore, ratingCount) =
                try row.decode(
                    (Int, String, String, Int, Int, Bool, String, Int, Int).self,
                    context: .default)
            let tags = (try? JSONSerialization.jsonObject(with: Data(tagsStr.utf8))) ?? []
            items.append([
                "id": id, "name": name, "category": category,
                "price": price, "quantity": quantity, "active": active,
                "tags": tags,
                "rating": ["score": ratingScore, "count": ratingCount] as [String: Any],
            ])
        }
        let response: [String: Any] = ["items": items, "count": items.count]
        if let jsonData = try? JSONSerialization.data(withJSONObject: response) {
            return [UInt8](jsonData)
        }
    } catch {}
    return [UInt8](#"{"items":[],"count":0}"#.utf8)
}

// MARK: - Main

let datasetPath = ProcessInfo.processInfo.environment["DATASET_PATH"] ?? "/data/dataset.json"
let dataset = loadDataset(path: datasetPath)

let dbPath = "/data/benchmark.db"
let dbAvailable = FileManager.default.fileExists(atPath: dbPath)

let state = AppState(
    dataset: dataset,
    staticFiles: loadStaticFiles(),
    dbPath: dbPath,
    dbAvailable: dbAvailable
)

let pgConfig = ProcessInfo.processInfo.environment["DATABASE_URL"].flatMap(parseDatabaseURL)
nonisolated(unsafe) var pgClient: PostgresClient? = nil
if let cfg = pgConfig {
    pgClient = PostgresClient(configuration: cfg)
}

let router = Router()

// Add response compression (only activates when client sends accept-encoding)
router.middlewares.add(
    ResponseCompressionMiddleware(
        minimumResponseSizeToCompress: 512,
        zlibCompressionLevel: .fastestCompression
    )
)

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
    if let n = Int(String(buffer: body).trimmingCharacters(in: .whitespacesAndNewlines)) {
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

// GET /json/{count}
router.get("json/{count}") { request, context -> Response in
    if state.dataset.isEmpty {
        return Response(status: .internalServerError)
    }
    let countParam = context.parameters.get("count").flatMap(Int.init) ?? 0
    let count = max(0, min(countParam, state.dataset.count))
    let query = request.uri.query ?? ""
    let m = parseQueryIntParam(query, key: "m") ?? 1
    let processed = Array(state.dataset.prefix(count)).map { item in
        ProcessedItem(
            id: item.id,
            name: item.name,
            category: item.category,
            price: item.price,
            quantity: item.quantity,
            active: item.active,
            tags: item.tags,
            rating: item.rating,
            total: item.price * item.quantity * m
        )
    }
    let resp = JsonResponse(items: processed, count: count)
    let jsonBytes = (try? JSONEncoder().encodeAsByteBuffer(resp, allocator: ByteBufferAllocator()))
        ?? ByteBuffer()
    return Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: jsonBytes)
    )
}

// POST /upload
router.post("upload") { request, _ -> Response in
    var size = 0
    for try await buffer in request.body {
        size += buffer.readableBytes
    }
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
    let minPrice = parseQueryParam(query, key: "min") ?? 10
    let maxPrice = parseQueryParam(query, key: "max") ?? 50
    let result = queryDb(dbPath: state.dbPath, minPrice: minPrice, maxPrice: maxPrice)
    return Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(bytes: result))
    )
}

// GET /async-db
router.get("async-db") { request, _ -> Response in
    guard let client = pgClient else {
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: #"{"items":[],"count":0}"#))
        )
    }
    let query = request.uri.query ?? ""
    let minPrice = parseQueryParam(query, key: "min") ?? 10
    let maxPrice = parseQueryParam(query, key: "max") ?? 50
    let limitRaw = parseQueryParam(query, key: "limit") ?? 50
    let limit = max(1, min(limitRaw, 50))
    let result = await queryPgDb(client: client, minPrice: minPrice, maxPrice: maxPrice, limit: limit)
    return Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(bytes: result))
    )
}

// GET /static/{filename}
router.get("static/{filename}") { request, context -> Response in
    let filename = context.parameters.get("filename") ?? ""
    guard let file = state.staticFiles[filename] else {
        return Response(status: .notFound)
    }
    let ae = request.headers[values: .acceptEncoding].first ?? ""
    if let brBuf = file.br, ae.contains("br") {
        return Response(
            status: .ok,
            headers: [.contentType: file.contentType, .contentEncoding: "br"],
            body: .init(byteBuffer: brBuf)
        )
    }
    if let gzBuf = file.gz, ae.contains("gzip") {
        return Response(
            status: .ok,
            headers: [.contentType: file.contentType, .contentEncoding: "gzip"],
            body: .init(byteBuffer: gzBuf)
        )
    }
    return Response(
        status: .ok,
        headers: [.contentType: file.contentType],
        body: .init(byteBuffer: file.data)
    )
}

// Start server
var app = Application(
    router: router,
    configuration: .init(address: .hostname("0.0.0.0", port: 8080), serverName: "hummingbird")
)

if let client = pgClient {
    app.addServices(client)
}
try await app.runService()
