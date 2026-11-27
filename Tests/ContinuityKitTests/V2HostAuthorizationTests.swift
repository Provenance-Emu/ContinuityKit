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
        let challenge = try await host.start(client: client, scopes: scopes)
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

    private func assertChallengeExpired(_ host: ContinuityV2HostAuthorization, id: String, signature: Data) async {
        do {
            _ = try await host.complete(authId: id, signature: signature)
            XCTFail("Expected the exchange to be invalidated")
        } catch {
            XCTAssertEqual(error as? ContinuityV2HostAuthorization.Failure, .challengeExpired)
        }
    }
}
