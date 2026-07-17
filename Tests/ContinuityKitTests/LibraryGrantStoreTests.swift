import Foundation
import XCTest
@testable import ContinuityKit

final class LibraryGrantStoreTests: XCTestCase {
    private func makeStore() -> (FileLibraryGrantStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grant-tests-\(UUID().uuidString)/library-grants.json")
        return (FileLibraryGrantStore(fileURL: url), url)
    }

    func testGrantRoundTripAndOverwrite() async {
        let (store, _) = makeStore()
        let initial = await store.grant(forPeerId: "peer-a")
        XCTAssertNil(initial)
        await store.setGrant(.everything, forPeerId: "peer-a")
        let granted = await store.grant(forPeerId: "peer-a")
        XCTAssertEqual(granted, .everything)
        await store.setGrant(.denied, forPeerId: "peer-a")
        let overwritten = await store.grant(forPeerId: "peer-a")
        XCTAssertEqual(overwritten, .denied)
    }

    func testPersistsAcrossInstances() async {
        let (store, url) = makeStore()
        await store.setGrant(.denied, forPeerId: "peer-b")
        let reloaded = FileLibraryGrantStore(fileURL: url)
        let grant = await reloaded.grant(forPeerId: "peer-b")
        XCTAssertEqual(grant, .denied)
    }

    func testRemoveGrantAndRemoveAll() async {
        let (store, _) = makeStore()
        await store.setGrant(.everything, forPeerId: "p1")
        await store.setGrant(.denied, forPeerId: "p2")
        await store.removeGrant(forPeerId: "p1")
        let removed = await store.grant(forPeerId: "p1")
        XCTAssertNil(removed)
        let kept = await store.grant(forPeerId: "p2")
        XCTAssertEqual(kept, .denied)
        await store.removeAll()
        let cleared = await store.grant(forPeerId: "p2")
        XCTAssertNil(cleared)
    }
}
