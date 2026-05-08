// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MultiMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MultiMonitor",
            path: "Sources/MultiMonitor"
        )
    ]
)
