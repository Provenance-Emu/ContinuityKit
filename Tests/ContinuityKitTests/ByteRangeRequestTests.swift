import ContinuityKit
import XCTest

final class ByteRangeRequestTests: XCTestCase {
    func testParsesOpenEndedRange() {
        XCTAssertEqual(ByteRangeRequest.parse(header: "bytes=100-"), ByteRangeRequest(offset: 100))
    }

    func testParsesBoundedRange() {
        XCTAssertEqual(ByteRangeRequest.parse(header: "bytes=5-9"), ByteRangeRequest(offset: 5, end: 9))
    }

    func testRejectsInvalid() {
        XCTAssertNil(ByteRangeRequest.parse(header: nil))
        XCTAssertNil(ByteRangeRequest.parse(header: ""))
        XCTAssertNil(ByteRangeRequest.parse(header: "items=0-5"))
        XCTAssertNil(ByteRangeRequest.parse(header: "bytes=abc-"))
        XCTAssertNil(ByteRangeRequest.parse(header: "bytes=9-5"))
        XCTAssertNil(ByteRangeRequest.parse(header: "bytes=0-5,10-20"))
        XCTAssertNil(ByteRangeRequest.parse(header: "bytes=-500"))
    }

    func testLengthAndContentRange() {
        let open = ByteRangeRequest(offset: 100)
        XCTAssertEqual(open.length(totalSize: 150), 50)
        XCTAssertEqual(open.contentRange(totalSize: 150), "bytes 100-149/150")

        let bounded = ByteRangeRequest(offset: 5, end: 9)
        XCTAssertEqual(bounded.length(totalSize: 100), 5)
        XCTAssertEqual(bounded.contentRange(totalSize: 100), "bytes 5-9/100")

        // End beyond EOF clamps.
        let overshoot = ByteRangeRequest(offset: 90, end: 500)
        XCTAssertEqual(overshoot.length(totalSize: 100), 10)

        // Offset beyond EOF is unsatisfiable.
        XCTAssertNil(ByteRangeRequest(offset: 100).length(totalSize: 100))
    }
}
