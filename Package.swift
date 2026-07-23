// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CursorGauge",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "CursorGauge", targets: ["CursorGauge"]),
        .executable(name: "CursorGaugeCoreTests", targets: ["CursorGaugeCoreTests"]),
        .library(name: "CursorGaugeCore", targets: ["CursorGaugeCore"]),
    ],
    targets: [
        .target(
            name: "CursorGaugeCore",
            path: "Sources/CursorGaugeCore"
        ),
        .executableTarget(
            name: "CursorGauge",
            dependencies: ["CursorGaugeCore"],
            path: "Sources/CursorGauge",
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
        // CLT-only environments lack XCTest; use a small assert runner instead.
        .executableTarget(
            name: "CursorGaugeCoreTests",
            dependencies: ["CursorGaugeCore"],
            path: "Tests/CursorGaugeCoreTests"
        ),
    ]
)
