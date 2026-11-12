// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipDown",
    platforms: [.macOS(.v14)],
    targets: [
        // Core: history store, clipboard monitor, plugin API. No UI, no concrete plugins.
        .target(name: "ClipCore"),
        // A built-in plugin living in its own module: depends only on ClipCore's plugin API.
        .target(name: "MarkdownPlugin", dependencies: ["ClipCore"]),
        // The app shell wires core + plugins + UI together.
        .executableTarget(name: "ClipDown", dependencies: ["ClipCore", "MarkdownPlugin"]),
        .testTarget(name: "MarkdownPluginTests", dependencies: ["ClipCore", "MarkdownPlugin"]),
    ]
)
