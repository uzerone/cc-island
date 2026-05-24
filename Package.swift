// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CCIsland",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "CCIsland", path: "Sources/CCIsland")
    ]
)
