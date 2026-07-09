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
    dependencies: [
        // .iflypkg archives (share-sheet / AirDrop transport). Same pin as the app.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.20"))
    ],
    targets: [
        .target(
            name: "ContinuityKit",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
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
