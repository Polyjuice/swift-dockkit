// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftUIAnimatedTest",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SwiftUIAnimatedTest",
            path: "Sources/SwiftUIAnimatedTest"
        )
    ]
)
