// swift-tools-version:6.0
import Foundation
import PackageDescription

// A version tag resolves to the prebuilt XCFrameworks from that tag's GitHub release;
// `main` always builds from source. The release workflow fills this in on the tagged
// commit only, so it stays `nil` on every branch.
// Set PV_BUILD_FROM_SOURCE=1 to build a tagged version from source instead.
let binaryRelease: (version: String, checksums: [String: String])? = ("1.0.3", ["ContinuityKit": "01687939fc95e7fae052ea50b4a999370b256203ca925b4f4354b1c19eeca960", "ContinuityKitTesting": "1b37d8744f367b144163daba4286e21fceb8ed7ea13c93974ac4d6f374f228c7"])

let environment = ProcessInfo.processInfo.environment
let buildFromSource = binaryRelease == nil || environment["PV_BUILD_FROM_SOURCE"] != nil
// The release workflow builds the frameworks it publishes from dynamic products, one
// module at a time, and names the ones already built so later modules link them
// instead of compiling them in again.
let buildingRelease = environment["PV_XCFRAMEWORK_BUILD"] != nil
let libraryType: Product.Library.LibraryType? = buildingRelease ? .dynamic : nil
let prebuilt = Set((environment["PV_XCFRAMEWORK_PREBUILT"] ?? "").split(separator: " ").map(String.init))

let module: (Target) -> Target = { source in
    prebuilt.contains(source.name)
        ? .binaryTarget(name: source.name, path: ".xcframework-build/\(source.name).xcframework")
        : source
}
// A product made only of a prebuilt framework cannot ask for a linkage type.
let libraryTypeFor: (String) -> Product.Library.LibraryType? = { module in
    prebuilt.contains(module) ? nil : libraryType
}

let sourceTargets: [Target] = [
    // ZIPFoundation is an `internal import`: it is linked inside ContinuityKit's framework
    // and stays out of its Swift interface, so a release needs no ZIPFoundation package.
    module(.target(
        name: "ContinuityKit",
        dependencies: [
            .product(name: "ZIPFoundation", package: "ZIPFoundation")
        ]
    )),
    module(.target(
        name: "ContinuityKitTesting",
        dependencies: ["ContinuityKit"]
    ))
] + (buildingRelease ? [] : [
    .testTarget(
        name: "ContinuityKitTests",
        dependencies: ["ContinuityKit", "ContinuityKitTesting"]
    )
])

let binaryTargets: [Target] = binaryRelease.map { release in
    release.checksums.sorted { $0.key < $1.key }.map { module, checksum in
        .binaryTarget(
            name: module,
            url: "https://github.com/Provenance-Emu/ContinuityKit/releases/download/\(release.version)/\(module).xcframework.zip",
            checksum: checksum
        )
    }
} ?? []

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
    // Product names are the same in both modes, so consumers never change.
    products: buildFromSource ? [
        .library(name: "ContinuityKit", type: libraryTypeFor("ContinuityKit"), targets: ["ContinuityKit"]),
        .library(name: "ContinuityKitTesting", type: libraryTypeFor("ContinuityKitTesting"), targets: ["ContinuityKitTesting"])
    ] : [
        .library(name: "ContinuityKit", targets: ["ContinuityKit"]),
        .library(name: "ContinuityKitTesting", targets: ["ContinuityKitTesting", "ContinuityKit"])
    ],
    dependencies: buildFromSource ? [
        // .iflypkg archives (share-sheet / AirDrop transport). Same pin as the app.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.20"))
    ] : [],
    targets: buildFromSource ? sourceTargets : binaryTargets,
    swiftLanguageModes: [.v6]
)
