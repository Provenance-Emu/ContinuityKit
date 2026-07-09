import ContinuityKit
import Foundation
import XCTest

final class AdvertisementCodecTests: XCTestCase {
    private func sampleAdvertisement() -> ContinuityAdvertisement {
        ContinuityAdvertisement(
            sessionId: "session-1",
            token: "tok_abc123",
            game: GameIdentity(
                flycastGameId: "T-8111N",
                md5Hash: "aabbccdd",
                serial: "T-8111N",
                displayName: "Crazy Taxi",
                platform: "dreamcast"
            ),
            saveStateStem: "crazytaxi",
            urlCandidates: [
                URL(string: "http://ifly.local:8080")!,
                URL(string: "http://192.168.1.20:8080")!
            ]
        )
    }

    func testUserInfoRoundTrip() {
        let original = sampleAdvertisement()
        let decoded = ContinuityAdvertisement(userInfo: original.userInfoRepresentation)
        XCTAssertEqual(original, decoded)
    }

    func testUserInfoRejectsGarbage() {
        XCTAssertNil(ContinuityAdvertisement(userInfo: nil))
        XCTAssertNil(ContinuityAdvertisement(userInfo: ["continuityAdvertisement": "not data"]))
        XCTAssertNil(ContinuityAdvertisement(userInfo: ["continuityAdvertisement": Data("junk".utf8)]))
    }

    func testTXTRoundTrip() {
        let original = sampleAdvertisement()
        let txt = ContinuityTXTRecord.encode(original)
        let decoded = ContinuityTXTRecord.decode(txt)
        XCTAssertEqual(original, decoded)
    }

    func testTXTRejectsMissingRequiredKeys() {
        var txt = ContinuityTXTRecord.encode(sampleAdvertisement())
        txt.removeValue(forKey: "tok")
        XCTAssertNil(ContinuityTXTRecord.decode(txt))
    }

    func testTXTDecodesWithoutOptionalFields() {
        let minimal = ContinuityAdvertisement(
            sessionId: "s",
            token: "t",
            game: GameIdentity(displayName: "Game", platform: "dreamcast"),
            urlCandidates: []
        )
        let decoded = ContinuityTXTRecord.decode(ContinuityTXTRecord.encode(minimal))
        XCTAssertEqual(minimal, decoded)
    }
}
