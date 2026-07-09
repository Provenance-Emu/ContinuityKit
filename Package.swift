// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ContinuityKit",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .macOS(.v13),
        .macCatalyst(.v17),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "ContinuityKit",
            targets: ["ContinuityKit"]
        ),
        .library(
            name: "ContinuityKitTesting",
            targets: ["ContinuityKitTesting"]
        )
    ],
    targets: [
        .target(
            name: "ContinuityKit"
        ),
        .target(
            name: "ContinuityKitTesting",
            dependencies: ["ContinuityKit"]
        ),
        .testTarget(
            name: "ContinuityKitTests",
            dependencies: ["ContinuityKit", "ContinuityKitTesting"]
        )
    ],
    swiftLanguageModes: [.v6]
)
