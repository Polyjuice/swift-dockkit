// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DockKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "DockKit",
            targets: ["DockKit"]
        )
    ],
    targets: [
        .target(
            name: "DockKit",
            dependencies: []
        )
    ]
)
