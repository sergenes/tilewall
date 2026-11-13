// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tilewall",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "TilewallCore"),
        .executableTarget(name: "tilewall", dependencies: ["TilewallCore"]),
        .testTarget(name: "TilewallCoreTests", dependencies: ["TilewallCore"]),
    ]
)
