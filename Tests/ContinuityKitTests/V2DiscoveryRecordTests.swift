import Foundation
import XCTest
import ContinuityKit

final class V2DiscoveryRecordTests: XCTestCase {
    private func fixture(_ name: String) throws -> [Data] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("docs/wire/v2/fixtures/discovery-\(name).txt")
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
    }

    func testPublishedAdvertisements() throws {
        let ifly = try XCTUnwrap(ContinuityV2DiscoveryRecord(txtItems: fixture("ifly")))
        XCTAssertEqual(ifly.app, .ifly)
        XCTAssertEqual(ContinuityV2DiscoveryRecord(txtItems: ifly.txtItems), ifly)
        XCTAssertEqual(ifly.capabilities, [.library, .handoff])
        XCTAssertEqual(ifly.systems, ["dreamcast"])
        XCTAssertEqual(ifly.origins.last?.host, "fixture-mac.local")
        XCTAssertEqual(ifly.runningGame?.title, "Example Disc – Test")

        let icube = try XCTUnwrap(ContinuityV2DiscoveryRecord(txtItems: fixture("icube")))
        XCTAssertEqual(icube.app, .icube)
        XCTAssertEqual(icube.systems, ["gamecube", "wii"])
        XCTAssertNil(icube.runningGame)

        let presence = try XCTUnwrap(ContinuityV2DiscoveryRecord(txtItems: fixture("presence")))
        XCTAssertEqual(presence.app, .provenance)
        XCTAssertTrue(presence.capabilities.isEmpty)
        XCTAssertTrue(presence.origins.isEmpty)
    }

    func testKnownDuplicatesAndGapsFailButUnknownKeysAreIgnored() throws {
        let base = try fixture("ifly")
        XCTAssertNil(ContinuityV2DiscoveryRecord(txtItems: base + [Data("app=icube".utf8)]))
        XCTAssertNil(ContinuityV2DiscoveryRecord(txtItems: base + [Data("sys2=wii".utf8)]))
        XCTAssertNil(ContinuityV2DiscoveryRecord(txtItems: base + [Data("u3=http://192.0.2.2".utf8)]))
        let extended = try XCTUnwrap(ContinuityV2DiscoveryRecord(txtItems: base + [
            Data("future=1".utf8), Data("future=2".utf8), Data("sys1=wii".utf8)
        ]))
        XCTAssertEqual(extended.systems, ["dreamcast", "wii"])
    }
}
