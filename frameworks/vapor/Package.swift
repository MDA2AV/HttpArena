// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "server",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.0")
    ],
    targets: [
        .executableTarget(
            name: "server",
            dependencies: [.product(name: "Vapor", package: "vapor")]
        )
    ]
)
