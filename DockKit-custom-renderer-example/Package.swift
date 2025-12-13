// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DockKitCustomRendererExample",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "../DockKit")
    ],
    targets: [
        .executableTarget(
            name: "DockKitCustomRendererExample",
            dependencies: ["DockKit"],
            path: "Sources"
        )
    ]
)
