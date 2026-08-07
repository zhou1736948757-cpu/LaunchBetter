// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LaunchUI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LaunchUI", targets: ["LaunchUI"])
    ],
    dependencies: [
        .package(path: "../LaunchCore")
    ],
    targets: [
        .target(
            name: "LaunchUI",
            dependencies: ["LaunchCore"],
            path: "Sources/LaunchUI"
        ),
    ]
)
