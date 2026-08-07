// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LaunchCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LaunchCore", targets: ["LaunchCore"])
    ],
    targets: [
        .target(
            name: "LaunchCore"
        ),
        .testTarget(
            name: "LaunchCoreTests",
            dependencies: ["LaunchCore"]
        ),
    ]
)
