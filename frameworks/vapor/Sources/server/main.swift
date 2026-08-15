import Foundation
import Vapor

struct Rating: Content {
    let score: Int
    let count: Int
}

struct DatasetItem: Content {
    let id: Int
    let name: String
    let category: String
    let price: Int
    let quantity: Int
    let active: Bool
    let tags: [String]
    let rating: Rating
}

struct ProcessedItem: Content {
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

struct ProcessResponse: Content {
    let items: [ProcessedItem]
    let count: Int
}

let datasetPath = Environment.get("DATASET_PATH") ?? "/data/dataset.json"
let dataset: [DatasetItem] = {
    guard let data = FileManager.default.contents(atPath: datasetPath),
          let items = try? JSONDecoder().decode([DatasetItem].self, from: data)
    else {
        return []
    }
    return items
}()

func plain(_ body: String) -> Response {
    Response(status: .ok, headers: ["content-type": "text/plain"], body: .init(string: body))
}

func querySum(_ request: Request) -> Int {
    guard let query = request.url.query else { return 0 }
    var sum = 0
    for pair in query.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        if parts.count == 2, let value = Int(parts[1]) {
            sum += value
        }
    }
    return sum
}

let app = try await Application.make(.production)
app.logger.logLevel = .error
app.http.server.configuration.hostname = "0.0.0.0"
app.http.server.configuration.port = 8080
app.http.server.configuration.responseCompression = .enabled

app.get("pipeline") { _ in plain("ok") }

app.on(.GET, "baseline11") { request in
    plain(String(querySum(request)))
}

app.on(.POST, "baseline11", body: .collect(maxSize: "1mb")) { request -> Response in
    var sum = querySum(request)
    if let buffer = request.body.data,
       let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes),
       let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        sum += value
    }
    return plain(String(sum))
}

app.get("json", ":count") { request -> ProcessResponse in
    let requested = request.parameters.get("count", as: Int.self) ?? 0
    let count = max(0, min(requested, dataset.count))
    let m = (try? request.query.get(Int.self, at: "m")) ?? 1

    let items = dataset.prefix(count).map { item in
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
    return ProcessResponse(items: items, count: items.count)
}

app.on(.POST, "upload", body: .stream) { request -> Response in
    var size = 0
    for try await chunk in request.body {
        size += chunk.readableBytes
    }
    return plain(String(size))
}

try await app.execute()
try await app.asyncShutdown()
