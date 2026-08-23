// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "httparena-hummingbird",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.21.1"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-compression.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.25.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"])
            ]
        ),
        .executableTarget(
            name: "Server",
            dependencies: [
                "CSQLite",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "HummingbirdCompression", package: "hummingbird-compression"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            path: "src"
        ),
    ]
)
