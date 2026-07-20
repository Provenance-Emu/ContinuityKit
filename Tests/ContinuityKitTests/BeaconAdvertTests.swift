import ContinuityKit
import Foundation
import XCTest

final class BeaconAdvertTests: XCTestCase {

    // MARK: - New-key round trip

    func testCapDtIcRoundTripInTXT() {
        var advert = ContinuityAdvertisement(
            sessionId: "session-1",
            token: "",
            game: nil,
            urlCandidates: [URL(string: "http://ifly.local:8080")!],
            sharesLibrary: true,
            peerId: "peer-abc"
        )
        advert.capabilities = "bc"
        advert.deviceType = "pd"
        advert.icloudHash = "0123456789abcdef"

        let txt = ContinuityTXTRecord.encode(advert)
        XCTAssertEqual(txt["cap"], "bc")
        XCTAssertEqual(txt["dt"], "pd")
        XCTAssertEqual(txt["ic"], "0123456789abcdef")

        let decoded = ContinuityTXTRecord.decode(txt)
        XCTAssertEqual(decoded?.capabilities, "bc")
        XCTAssertEqual(decoded?.deviceType, "pd")
        XCTAssertEqual(decoded?.icloudHash, "0123456789abcdef")
    }

    // MARK: - Old adverts unaffected (never gate on payloadVersion)

    func testOldAdvertWithoutNewKeysDecodesUnchanged() {
        let txt: [String: String] = [
            "v": "1",
            "sid": "session-old",
            "lib": "1",
            "pid": "peer-old",
            "u0": "http://ifly.local:8080"
        ]
        let decoded = ContinuityTXTRecord.decode(txt)
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.capabilities)
        XCTAssertNil(decoded?.deviceType)
        XCTAssertNil(decoded?.icloudHash)
        XCTAssertTrue(decoded?.sharesLibrary ?? false)
        XCTAssertEqual(decoded?.peerId, "peer-old")
    }

    func testEncodeOmitsNewKeysWhenNil() {
        let advert = ContinuityAdvertisement(
            sessionId: "s", token: "", game: nil,
            urlCandidates: [], sharesLibrary: false, peerId: "p"
        )
        let txt = ContinuityTXTRecord.encode(advert)
        XCTAssertNil(txt["cap"])
        XCTAssertNil(txt["dt"])
        XCTAssertNil(txt["ic"])
    }

    // MARK: - Beacon constructor invariants

    func testBeaconAdvertCarriesOnlyPresenceKeys() {
        let beacon = ContinuityAdvertisement.beacon(
            peerId: "peer-beacon",
            capabilities: "b",
            deviceType: "ip",
            icloudHash: "feedfacefeedface"
        )
        XCTAssertNil(beacon.game)
        XCTAssertTrue(beacon.token.isEmpty)
        XCTAssertFalse(beacon.sharesLibrary)
        XCTAssertTrue(beacon.urlCandidates.isEmpty)
        XCTAssertEqual(beacon.peerId, "peer-beacon")
        XCTAssertTrue(beacon.sessionId.hasPrefix("beacon-"))

        let txt = ContinuityTXTRecord.encode(beacon)
        // Presence keys present…
        XCTAssertEqual(txt["cap"], "b")
        XCTAssertEqual(txt["dt"], "ip")
        XCTAssertEqual(txt["ic"], "feedfacefeedface")
        XCTAssertEqual(txt["pid"], "peer-beacon")
        // …and NOTHING else: no game, no lib, no urls, no token.
        XCTAssertNil(txt["lib"])
        XCTAssertNil(txt["name"])
        XCTAssertNil(txt["plat"])
        XCTAssertNil(txt["gid"])
        XCTAssertNil(txt["md5"])
        XCTAssertNil(txt["ser"])
        XCTAssertNil(txt["tok"])
        XCTAssertNil(txt["u0"])
        XCTAssertNil(txt["stem"])
    }

    func testBeaconWithoutICloudHashOmitsIc() {
        let beacon = ContinuityAdvertisement.beacon(
            peerId: "p", capabilities: "b", deviceType: "tv", icloudHash: nil
        )
        XCTAssertNil(ContinuityTXTRecord.encode(beacon)["ic"])
    }

    // MARK: - Codable (Handoff userInfo path) round trip with new fields

    func testUserInfoRoundTripWithNewFields() {
        var advert = ContinuityAdvertisement(
            sessionId: "s2", token: "tok", game: nil,
            urlCandidates: [], sharesLibrary: false, peerId: "p2"
        )
        advert.capabilities = "c"
        advert.deviceType = "mc"
        advert.icloudHash = "aa11bb22cc33dd44"
        let decoded = ContinuityAdvertisement(userInfo: advert.userInfoRepresentation)
        XCTAssertEqual(decoded, advert)
    }
}
