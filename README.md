# ContinuityKit

Cross-device "continue this game" handoff for Swift: manifests, file transfer, Bonjour
discovery and library browse. Used by iFly; documented with the other shared packages at
[wiki.provenance-emu.com/help/shared-frameworks](https://wiki.provenance-emu.com/help/shared-frameworks#continuitykit).

```swift
.package(url: "https://github.com/Provenance-Emu/ContinuityKit.git", .upToNextMajor(from: "1.0.1"))
```

Two products: `ContinuityKit`, and `ContinuityKitTesting` with support code for a
consumer's tests. Run `swift test` to verify the package.

This is distinct from [PVContinuity](https://github.com/Provenance-Emu/PVContinuity),
which iCube uses: their APIs and wire protocols differ.

## Prebuilt XCFrameworks

A version tag resolves to prebuilt XCFrameworks: the tag's `Package.swift` is a
`binaryTarget` pointing at the tag's GitHub Release, so an app that depends on a version
compiles none of this package. `main` and every other branch build from source.

To build a tagged version from source (to step into it in the debugger, say), set
`PV_BUILD_FROM_SOURCE=1` in the environment `xcodebuild` or Xcode starts in, then resolve
packages again.

To release, run **Release XCFramework** from the Actions tab with the new version. Do not
push version tags by hand: such a tag has no binary and builds from source.
[How releases work](https://github.com/Provenance-Emu/.github/blob/main/docs/xcframework-releases.md).

ZIPFoundation is linked inside `ContinuityKit.framework` and is not part of its interface.
An app that also uses ZIPFoundation carries its own copy.

## Continuity v2

See the [v2 wire specification and fixtures](docs/wire/v2/README.md).
