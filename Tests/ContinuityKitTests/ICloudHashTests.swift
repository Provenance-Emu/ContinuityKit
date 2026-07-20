import ContinuityKit
import XCTest

final class ICloudHashTests: XCTestCase {
    func testHashIsDeterministicAnd16LowercaseHex() {
        let a = ContinuityICloudHash.hash(userRecordName: "_abc123recordname")
        let b = ContinuityICloudHash.hash(userRecordName: "_abc123recordname")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 16)
        XCTAssertTrue(a.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testDifferentRecordNamesProduceDifferentHashes() {
        XCTAssertNotEqual(
            ContinuityICloudHash.hash(userRecordName: "_userA"),
            ContinuityICloudHash.hash(userRecordName: "_userB")
        )
    }

    func testHashIsSaltedNotPlainSHA256() {
        // Plain (unsalted) SHA-256 prefix of the record name must NOT match —
        // proves the salt participates.
        let plain = String(ContinuityHash.sha256Hex(of: Data("_userA".utf8)).prefix(16))
        XCTAssertNotEqual(ContinuityICloudHash.hash(userRecordName: "_userA"), plain)
    }
}
