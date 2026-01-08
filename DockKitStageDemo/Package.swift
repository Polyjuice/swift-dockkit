// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DockKitStageDemo",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "../DockKit")
    ],
    targets: [
        .executableTarget(
            name: "DockKitStageDemo",
            dependencies: ["DockKit"],
            path: "DockKitStageDemo"
        )
    ]
)
