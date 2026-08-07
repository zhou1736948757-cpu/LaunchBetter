// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LaunchPlatform",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LaunchPlatform", targets: ["LaunchPlatform"])
    ],
    dependencies: [
        .package(path: "../LaunchCore")
    ],
    targets: [
        .target(
            name: "LaunchPlatform",
            dependencies: ["LaunchCore"],
            path: "Sources/LaunchPlatform"
        ),
        .testTarget(
            name: "LaunchPlatformTests",
            dependencies: ["LaunchPlatform", "LaunchCore"],
            path: "Tests/LaunchPlatformTests"
        ),
    ]
)
