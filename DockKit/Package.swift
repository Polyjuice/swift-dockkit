// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DockKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Dynamic: always-on's app and its `panels` extension bundle share ONE
        // copy of DockKit (a panel made in the bundle is docked by the app's
        // manager), so the product is a dylib, shipped in the app's
        // Contents/Frameworks (always-on docs/macos-extensions.plan.md §1.1).
        .library(
            name: "DockKit",
            type: .dynamic,
            targets: ["DockKit"]
        )
    ],
    targets: [
        .target(
            name: "DockKit",
            dependencies: []
        ),
        .testTarget(
            name: "DockKitTests",
            dependencies: ["DockKit"]
        )
    ]
)
