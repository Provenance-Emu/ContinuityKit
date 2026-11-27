import CryptoKit
import Foundation
import XCTest
import ContinuityKit

final class V2HostAuthorizationTests: XCTestCase {
    private func peer(_ key: Curve25519.Signing.PrivateKey, app: String) -> ContinuityV2AuthPeer {
        let bytes = key.publicKey.rawRepresentation
        return ContinuityV2AuthPeer(pid: ContinuityV2AuthPeer.peerID(for: bytes), app: app, name: "Fixture device", publicKey: bytes)
    }

    private func signedChallenge(
        host: ContinuityV2HostAuthorization,
        client: ContinuityV2AuthPeer,
        key: Curve25519.Signing.PrivateKey
    ) async throws -> (ContinuityV2HostAuthorization.Challenge, Data) {
        let scopes = ["browse", "copy", "future"]
        let challenge = try await host.start(source: "192.0.2.1", client: client, scopes: scopes)
        let transcript = try ContinuityV2AuthTranscript(
            authID: challenge.authId, client: client, server: challenge.server, nonce: challenge.nonce, scopes: scopes
        )
        return (challenge, try key.signature(for: transcript.bytes))
    }

    func testApprovalRequiresSignatureAndIssuesTokenOnce() async throws {
        let clientKey = Curve25519.Signing.PrivateKey()
        let client = peer(clientKey, app: "ifly")
        let host = ContinuityV2HostAuthorization(server: peer(.init(), app: "provenance"), policy: { _ in .ask })
        let (challenge, signature) = try await signedChallenge(host: host, client: client, key: clientKey)
        let earlyApproval = await host.resolveApproval(authId: challenge.authId, allowing: ["browse"])
        XCTAssertFalse(earlyApproval)
        guard case .needsApproval(let prompt) = try await host.complete(authId: challenge.authId, signature: signature) else {
            return XCTFail("Expected a verified approval prompt")
        }
        XCTAssertEqual(prompt.scopes, ["browse", "copy"])
        guard case .pending = try await host.complete(authId: challenge.authId, signature: signature) else {
            return XCTFail("Expected pending approval")
        }
        let resolved = await host.resolveApproval(authId: challenge.authId, allowing: ["browse", "saves"])
        XCTAssertTrue(resolved)
        guard case .authorized(let token) = try await host.complete(authId: challenge.authId, signature: signature) else {
            return XCTFail("Expected a token")
        }
        XCTAssertEqual(token.scopes, ["browse"])
        let browse = await host.authorize(token: token.token, requiring: "browse")
        let copy = await host.authorize(token: token.token, requiring: "copy")
        XCTAssertEqual(browse?.client, client)
        XCTAssertNil(copy)
        await assertChallengeExpired(host, id: challenge.authId, signature: signature)
        await host.revoke(peerID: client.pid)
        let revoked = await host.authorize(token: token.token, requiring: "browse")
        XCTAssertNil(revoked)
    }

    func testRevocationInvalidatesPendingApproval() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let client = peer(key, app: "icube")
        let host = ContinuityV2HostAuthorization(server: peer(.init(), app: "provenance"), policy: { _ in .ask })
        let (challenge, signature) = try await signedChallenge(host: host, client: client, key: key)
        _ = try await host.complete(authId: challenge.authId, signature: signature)
        await host.revoke(peerID: client.pid)
        let resolved = await host.resolveApproval(authId: challenge.authId, allowing: ["browse"])
        XCTAssertFalse(resolved)
        await assertChallengeExpired(host, id: challenge.authId, signature: signature)
    }

    func testOneSourceCannotFillChallengeTableWithDifferentKeys() async throws {
        let host = ContinuityV2HostAuthorization(server: peer(.init(), app: "provenance"), policy: { _ in .ask })
        for _ in 0..<4 {
            _ = try await host.start(source: "192.0.2.1", client: peer(.init(), app: "ifly"), scopes: ["browse"])
        }
        do {
            _ = try await host.start(source: "192.0.2.1", client: peer(.init(), app: "ifly"), scopes: ["browse"])
            XCTFail("Expected the transport source to reach its challenge limit")
        } catch {
            XCTAssertEqual(error as? ContinuityV2HostAuthorization.Failure, .capacityReached)
        }
        _ = try await host.start(source: "192.0.2.2", client: peer(.init(), app: "icube"), scopes: ["browse"])
    }

    func testRevokesMultipleSigningIdentitiesTogether() async throws {
        let host = ContinuityV2HostAuthorization(server: peer(.init(), app: "provenance"), policy: { _ in .grant(["browse"]) })
        let firstKey = Curve25519.Signing.PrivateKey()
        let secondKey = Curve25519.Signing.PrivateKey()
        let first = peer(firstKey, app: "ifly")
        let second = peer(secondKey, app: "icube")
        let (firstChallenge, firstSignature) = try await signedChallenge(host: host, client: first, key: firstKey)
        let (secondChallenge, secondSignature) = try await signedChallenge(host: host, client: second, key: secondKey)
        guard case .authorized(let token) = try await host.complete(authId: firstChallenge.authId, signature: firstSignature) else {
            return XCTFail("Expected a token")
        }

        await host.revoke(peerIDs: [first.pid, second.pid])

        let revoked = await host.authorize(token: token.token, requiring: "browse")
        XCTAssertNil(revoked)
        await assertChallengeExpired(host, id: secondChallenge.authId, signature: secondSignature)
    }

    private func assertChallengeExpired(_ host: ContinuityV2HostAuthorization, id: String, signature: Data) async {
        do {
            _ = try await host.complete(authId: id, signature: signature)
            XCTFail("Expected the exchange to be invalidated")
        } catch {
            XCTAssertEqual(error as? ContinuityV2HostAuthorization.Failure, .challengeExpired)
        }
    }
}
