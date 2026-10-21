// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Monibar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Monibar", path: "Sources/Monibar")
    ]
)
