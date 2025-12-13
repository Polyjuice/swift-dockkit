// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DockKitDesktopDemo",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "../DockKit")
    ],
    targets: [
        .executableTarget(
            name: "DockKitDesktopDemo",
            dependencies: ["DockKit"],
            path: "DockKitDesktopDemo"
        )
    ]
)
