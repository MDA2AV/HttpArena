import Foundation
import Vapor
import CZlib

#if canImport(CSQLite)
import CSQLite
#elseif canImport(SQLite3)
import SQLite3
#endif

// MARK: - Data Models

struct Rating: Content {
    let score: Double
    let count: Int
}

struct DatasetItem: Content {
    let id: Int
    let name: String
    let category: String
    let price: Double
    let quantity: Int
    let active: Bool
    let tags: [String]
    let rating: Rating
}

struct ProcessedItem: Content {
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

struct JsonResponse: Content {
    let items: [ProcessedItem]
    let count: Int
}

// MARK: - State

final class AppState: Sendable {
    let dataset: [DatasetItem]
    let jsonLargeCache: [UInt8]
    let staticFiles: [String: StaticFile]
    let dbPath: String
    let dbAvailable: Bool

    init(dataset: [DatasetItem], jsonLargeCache: [UInt8],
         staticFiles: [String: StaticFile], dbPath: String, dbAvailable: Bool) {
        self.dataset = dataset
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
    let encoder = JSONEncoder()
    let data = (try? encoder.encode(resp)) ?? Data()
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

// MARK: - Gzip Helper

func gzipCompress(_ data: [UInt8], level: Int32 = 1) -> [UInt8] {
    var stream = z_stream()
    // windowBits = 15 + 16 = 31 for gzip format
    let rc = deflateInit2_(&stream, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                           ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard rc == Z_OK else { return data }

    let bufferSize = deflateBound(&stream, UInt(data.count))
    var output = [UInt8](repeating: 0, count: Int(bufferSize))

    data.withUnsafeBufferPointer { inputPtr in
        stream.next_in = UnsafeMutablePointer(mutating: inputPtr.baseAddress!)
        stream.avail_in = uInt(data.count)

        output.withUnsafeMutableBufferPointer { outputPtr in
            stream.next_out = outputPtr.baseAddress!
            stream.avail_out = uInt(outputPtr.count)
            deflate(&stream, Z_FINISH)
        }
    }

    let compressedSize = Int(stream.total_out)
    deflateEnd(&stream)
    return Array(output.prefix(compressedSize))
}

// MARK: - Main

let datasetPath = ProcessInfo.processInfo.environment["DATASET_PATH"] ?? "/data/dataset.json"
let dataset = loadDataset(path: datasetPath)

let largeDataset = loadDataset(path: "/data/dataset-large.json")
let jsonLargeCache = buildJsonCache(largeDataset)

let dbPath = "/data/benchmark.db"
let dbAvailable = FileManager.default.fileExists(atPath: dbPath)

let state = AppState(
    dataset: dataset,
    jsonLargeCache: jsonLargeCache,
    staticFiles: loadStaticFiles(),
    dbPath: dbPath,
    dbAvailable: dbAvailable
)

// Configure Vapor
var env = try Environment.detect()
let app = Application(env)
defer { app.shutdown() }

// Disable Vapor's default logging noise
app.logger.logLevel = .error

// Server config
app.http.server.configuration.hostname = "0.0.0.0"
app.http.server.configuration.port = 8080
app.http.server.configuration.serverName = "vapor"

// Note: NOT using Vapor's built-in responseCompression (.enabled uses zlib level 6).
// The /compression endpoint handles gzip manually at level 1 per spec.

// Routes

// GET /pipeline
app.get("pipeline") { req -> Response in
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "text/plain")
    headers.add(name: "server", value: "vapor")
    return Response(status: .ok, headers: headers, body: .init(string: "ok"))
}

// GET /baseline11
app.get("baseline11") { req -> Response in
    let sum = req.url.query.map(parseQuerySum) ?? 0
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "text/plain")
    headers.add(name: "server", value: "vapor")
    return Response(status: .ok, headers: headers, body: .init(string: "\(sum)"))
}

// POST /baseline11
app.on(.POST, "baseline11", body: .collect(maxSize: "1mb")) { req -> Response in
    var sum = req.url.query.map(parseQuerySum) ?? 0
    if let buffer = req.body.data {
        let bodyStr = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        if let n = Int(bodyStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            sum += n
        }
    }
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "text/plain")
    headers.add(name: "server", value: "vapor")
    return Response(status: .ok, headers: headers, body: .init(string: "\(sum)"))
}

// GET /baseline2
app.get("baseline2") { req -> Response in
    let sum = req.url.query.map(parseQuerySum) ?? 0
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "text/plain")
    headers.add(name: "server", value: "vapor")
    return Response(status: .ok, headers: headers, body: .init(string: "\(sum)"))
}

// GET /json
app.get("json") { req -> Response in
    if state.dataset.isEmpty {
        return Response(status: .internalServerError)
    }
    let jsonBytes = buildJsonCache(state.dataset)
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json")
    headers.add(name: "server", value: "vapor")
    return Response(status: .ok, headers: headers, body: .init(data: Data(jsonBytes)))
}

// GET /compression — manual gzip at level 1 (spec requirement)
app.get("compression") { req -> Response in
    let compressed = gzipCompress(state.jsonLargeCache, level: 1)
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json")
    headers.add(name: .contentEncoding, value: "gzip")
    headers.add(name: "server", value: "vapor")
    return Response(status: .ok, headers: headers, body: .init(data: Data(compressed)))
}

// POST /upload
app.on(.POST, "upload", body: .collect(maxSize: "25mb")) { req -> Response in
    let size = req.body.data?.readableBytes ?? 0
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "text/plain")
    headers.add(name: "server", value: "vapor")
    return Response(status: .ok, headers: headers, body: .init(string: "\(size)"))
}

// GET /db
app.get("db") { req -> Response in
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json")
    headers.add(name: "server", value: "vapor")

    guard state.dbAvailable else {
        return Response(status: .ok, headers: headers, body: .init(string: #"{"items":[],"count":0}"#))
    }
    let query = req.url.query ?? ""
    let minPrice = parseQueryParam(query, key: "min") ?? 10.0
    let maxPrice = parseQueryParam(query, key: "max") ?? 50.0
    let result = queryDb(dbPath: state.dbPath, minPrice: minPrice, maxPrice: maxPrice)
    return Response(status: .ok, headers: headers, body: .init(data: Data(result)))
}

// GET /static/:filename
app.get("static", ":filename") { req -> Response in
    let filename = req.parameters.get("filename") ?? ""
    guard let file = state.staticFiles[filename] else {
        return Response(status: .notFound)
    }
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: file.contentType)
    headers.add(name: "server", value: "vapor")
    return Response(status: .ok, headers: headers, body: .init(data: Data(file.data)))
}

try app.run()
