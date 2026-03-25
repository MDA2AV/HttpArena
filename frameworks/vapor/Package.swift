// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "httparena-vapor",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.100.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"]),
            ]
        ),
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            providers: [
                .apt(["zlib1g-dev"]),
            ]
        ),
        .executableTarget(
            name: "Server",
            dependencies: [
                "CSQLite",
                "CZlib",
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "src"
        ),
    ]
)
