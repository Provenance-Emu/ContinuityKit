import Foundation
import XCTest
@testable import ContinuityKit

final class LibraryManifestCodecTests: XCTestCase {
    func testManifestRoundTrips() throws {
        let manifest = ContinuityLibraryManifest(
            version: ContinuityLibraryManifest.currentVersion,
            peerId: "peer-1",
            deviceName: "Joe's iPad",
            games: [
                .init(title: "Ikaruga", platform: "Dreamcast", md5: "abc123",
                      sizeBytes: 1_234_567, artKey: "ikaruga_cover.jpg",
                      saveStateCount: 2, vmuFileCount: nil),
                .init(title: "Unhashed", platform: "Naomi", md5: nil,
                      sizeBytes: 42, artKey: nil, saveStateCount: 0, vmuFileCount: nil)
            ]
        )
        let decoded = try ContinuityLibraryManifest.decoded(from: manifest.encoded())
        XCTAssertEqual(decoded, manifest)
        XCTAssertNil(decoded.games[1].md5)
    }

    func testArtURLEncodesKeyQuery() throws {
        let url = ContinuityRoutes.libraryArtURL(
            base: try XCTUnwrap(URL(string: "http://host.local:8080")), key: "cover one.jpg"
        )
        XCTAssertEqual(url.path, ContinuityRoutes.libraryArt)
        XCTAssertEqual(url.query?.contains("key=cover%20one.jpg"), true)
    }

    func testComputeVersionIsOrderIndependent() {
        let a: ContinuityLibraryManifest.Game = .init(
            title: "Ikaruga", platform: "Dreamcast", md5: "abc", sizeBytes: 100,
            artKey: "a.jpg", saveStateCount: 0, vmuFileCount: nil)
        let b: ContinuityLibraryManifest.Game = .init(
            title: "Crazy Taxi", platform: "Dreamcast", md5: "def", sizeBytes: 200,
            artKey: "b.jpg", saveStateCount: 0, vmuFileCount: nil)

        let forward = ContinuityLibraryManifest.computeVersion(games: [a, b])
        let reversed = ContinuityLibraryManifest.computeVersion(games: [b, a])
        XCTAssertEqual(forward, reversed)
        XCTAssertTrue(forward.hasPrefix("v1-"))
    }

    func testComputeVersionChangesWhenFavoriteFlips() {
        let base: ContinuityLibraryManifest.Game = .init(
            title: "Ikaruga", platform: "Dreamcast", md5: "abc", sizeBytes: 100,
            artKey: "a.jpg", saveStateCount: 0, vmuFileCount: nil, favorite: false)
        var favorited = base
        favorited.favorite = true

        let before = ContinuityLibraryManifest.computeVersion(games: [base])
        let after = ContinuityLibraryManifest.computeVersion(games: [favorited])
        XCTAssertNotEqual(before, after)
    }
}
