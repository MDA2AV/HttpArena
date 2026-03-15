# Hummingbird — Swift HTTP Framework

[Hummingbird](https://github.com/hummingbird-project/hummingbird) is a lightweight, flexible HTTP server framework written in Swift, built on top of [SwiftNIO](https://github.com/apple/swift-nio).

## Why Hummingbird?

- **SwiftNIO-based**: Non-blocking I/O with Swift's structured concurrency
- **Minimal dependencies**: Designed to be lightweight with opt-in extensions
- **Modern Swift**: Uses async/await throughout
- **SSWG incubated**: Part of the Swift Server Work Group ecosystem

## Implementation Notes

- Uses Swift 5.10 with whole-module optimization
- SQLite via [SQLite.swift](https://github.com/stephencelis/SQLite.swift) for the `/db` endpoint
- Pre-cached JSON responses for `/json` and `/compression` endpoints
- Static files loaded into memory at startup
