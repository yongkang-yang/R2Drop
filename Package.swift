// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "R2Drop",
    platforms: [.macOS(.v14)],
    targets: [
        // R2 signing, object keys and link formats. No UI, so it can be tested.
        .target(
            name: "R2DropKit",
            path: "Sources/R2DropKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Menu bar app: status item, uploads, settings.
        .executableTarget(
            name: "R2Drop",
            dependencies: ["R2DropKit"],
            path: "Sources/R2Drop",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "R2DropKitTests",
            dependencies: ["R2DropKit"],
            path: "Tests/R2DropKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
