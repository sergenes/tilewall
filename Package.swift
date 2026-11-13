// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mosaic",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MosaicCore"),
        .executableTarget(name: "mosaic", dependencies: ["MosaicCore"]),
        .testTarget(name: "MosaicCoreTests", dependencies: ["MosaicCore"]),
    ]
)
