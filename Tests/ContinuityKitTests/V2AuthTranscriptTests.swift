import Foundation
import XCTest
import ContinuityKit

final class V2AuthTranscriptTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Start: Decodable {
            struct Request: Decodable {
                struct Body: Decodable {
                    let client: ContinuityV2AuthPeer
                    let scopes: [String]
                    let saveFormats: [String]
                }
                let body: Body
            }

            struct Response: Decodable {
                struct Body: Decodable {
                    let authId: String
                    let server: ContinuityV2AuthPeer
                    let nonce: Data
                }
                let body: Body
            }
            let request: Request
            let response: Response
        }

        struct Approved: Decodable {
            struct Request: Decodable {
                struct Body: Decodable {
                    let clientSignature: Data
                }
                let body: Body
            }
            let request: Request
        }

        struct Vector: Decodable {
            let transcriptBase64: Data
        }

        let start: Start
        let approved: Approved
        let vector: Vector

        func transcript(scopes: [String]? = nil, nonce: Data? = nil) throws -> ContinuityV2AuthTranscript {
            let request = start.request.body
            let response = start.response.body
            return try ContinuityV2AuthTranscript(
                authID: response.authId,
                client: request.client,
                server: response.server,
                nonce: nonce ?? response.nonce,
                scopes: scopes ?? request.scopes,
                saveFormats: request.saveFormats
            )
        }
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("docs/wire/v2/fixtures/auth.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
    }

    func testPublishedSignatureAndTranscript() throws {
        let fixture = try fixture()
        let transcript = try fixture.transcript()
        let signature = fixture.approved.request.body.clientSignature
        XCTAssertEqual(transcript.bytes, fixture.vector.transcriptBase64)
        XCTAssertTrue(transcript.verifies(clientSignature: signature))
        XCTAssertFalse(try fixture.transcript(scopes: ["copy"]).verifies(clientSignature: signature))
        XCTAssertFalse(try fixture.transcript(nonce: Data(repeating: 0, count: 32)).verifies(clientSignature: signature))
    }

    func testRejectsNoncanonicalLabelsAndShortNonce() throws {
        let fixture = try fixture()
        for scopes in [["copy", "browse"], ["copy", "copy"], ["browse,copy"]] {
            XCTAssertThrowsError(try fixture.transcript(scopes: scopes)) {
                XCTAssertEqual($0 as? ContinuityV2AuthTranscript.ValidationError, .invalidList)
            }
        }
        XCTAssertThrowsError(try fixture.transcript(nonce: Data())) {
            XCTAssertEqual($0 as? ContinuityV2AuthTranscript.ValidationError, .invalidChallenge)
        }
    }
}
