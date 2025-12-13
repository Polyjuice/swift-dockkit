// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DockKitExample",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "../DockKit")
    ],
    targets: [
        .executableTarget(
            name: "DockKitExample",
            dependencies: ["DockKit"],
            path: "DockKitExample"
        )
    ]
)
