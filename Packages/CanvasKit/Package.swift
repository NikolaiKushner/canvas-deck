// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CanvasKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CanvasKit", targets: ["CanvasCore", "Usage"]),
        // Foundation-only slice for the canvas-notify helper.
        .library(name: "CanvasUsage", targets: ["Usage"]),
        // Issue trackers: Linear through its MCP server.
        .library(name: "CanvasTrackers", targets: ["Trackers"]),
    ],
    targets: [
        .target(name: "CanvasCore"),
        .target(name: "Usage"),
        .target(name: "Trackers"),
        .testTarget(name: "CanvasCoreTests", dependencies: ["CanvasCore"]),
        .testTarget(name: "UsageTests", dependencies: ["Usage"]),
        .testTarget(name: "TrackersTests", dependencies: ["Trackers"]),
    ]
)
