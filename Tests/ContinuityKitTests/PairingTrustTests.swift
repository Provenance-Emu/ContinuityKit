import ContinuityKit
import ContinuityKitTesting
import CryptoKit
import Foundation
import XCTest

/// Cross-user trust: pairing math, trust-store persistence, and full
/// client ↔ server round trips over the registrar (no sockets).
final class PairingTrustTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-trust-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Pure math

    func testPairingProofRoundTripAndTamperResistance() {
        let client = ContinuityPeerIdentity(name: "iPhone")
        let server = ContinuityPeerIdentity(name: "Apple TV")
        let transcript = ContinuityPairingMath.pairingTranscript(
            pairingId: "p1", clientId: client.id, serverId: server.id,
            clientPublicKey: client.publicKeyData, serverPublicKey: server.publicKeyData
        )
        let proof = ContinuityPairingMath.pairingProof(code: "123456", transcript: transcript)
        XCTAssertTrue(ContinuityPairingMath.verifyPairingProof(proof, code: "123456", transcript: transcript))
        XCTAssertFalse(ContinuityPairingMath.verifyPairingProof(proof, code: "123457", transcript: transcript))

        // Rebinding the same proof to a different server must fail.
        let otherTranscript = ContinuityPairingMath.pairingTranscript(
            pairingId: "p1", clientId: client.id, serverId: "someone-else",
            clientPublicKey: client.publicKeyData, serverPublicKey: server.publicKeyData
        )
        XCTAssertFalse(ContinuityPairingMath.verifyPairingProof(proof, code: "123456", transcript: otherTranscript))
    }

    func testAuthSignatureRoundTrip() throws {
        let peer = ContinuityPeerIdentity(name: "iPad")
        let nonce = ContinuityPairingMath.makeNonce()
        let signature = try ContinuityPairingMath.signAuth(
            nonce: nonce, peerId: peer.id, serverId: "srv", signingKey: peer.signingKey
        )
        XCTAssertTrue(ContinuityPairingMath.verifyAuth(
            signature: signature, nonce: nonce, peerId: peer.id, serverId: "srv",
            publicKey: peer.publicKeyData
        ))
        // Different signer's key must fail.
        let other = ContinuityPeerIdentity(name: "Mallory")
        XCTAssertFalse(ContinuityPairingMath.verifyAuth(
            signature: signature, nonce: nonce, peerId: peer.id, serverId: "srv",
            publicKey: other.publicKeyData
        ))
    }

    func testPairingCodeShape() {
        for _ in 0..<20 {
            let code = ContinuityPairingMath.makePairingCode()
            XCTAssertEqual(code.count, 6)
            XCTAssertNotNil(Int(code))
        }
    }

    // MARK: - Trust store

    func testFileTrustStorePersistsAcrossInstances() async {
        let url = tempDir.appendingPathComponent("peers.json")
        let peer = TrustedPeer(id: "abc", name: "iPad", publicKey: Data([1, 2, 3]))

        let store = FileTrustStore(fileURL: url)
        await store.add(peer)

        let reloaded = FileTrustStore(fileURL: url)
        let found = await reloaded.peer(withId: "abc")
        XCTAssertEqual(found, peer)

        await reloaded.removePeer(withId: "abc")
        let gone = await FileTrustStore(fileURL: url).peer(withId: "abc")
        XCTAssertNil(gone)
    }

    func testIdentityRestoresFromPrivateKeyData() throws {
        let original = ContinuityPeerIdentity(name: "iPhone")
        let restored = try ContinuityPeerIdentity(
            id: original.id, name: original.name, privateKeyData: original.privateKeyData
        )
        XCTAssertEqual(restored.publicKeyData, original.publicKeyData)
    }

    // MARK: - End-to-end over the registrar

    private struct Harness {
        let registrar: MockRouteRegistrar
        let transport: RegistrarBackedTransport
        let server: ContinuityPairingServer
        let approver: ScriptedApprover
        let trustStore: FileTrustStore
        let serverIdentity: ContinuityPeerIdentity
        let client: ContinuityPairingClient
    }

    private func makeHarness(sessionToken: String? = "tok-123") async -> Harness {
        let registrar = MockRouteRegistrar()
        let approver = ScriptedApprover()
        let trustStore = FileTrustStore(fileURL: tempDir.appendingPathComponent("peers.json"))
        let serverIdentity = ContinuityPeerIdentity(name: "Apple TV")
        let server = ContinuityPairingServer(
            identity: serverIdentity,
            trustStore: trustStore,
            approver: approver,
            sessionTokenProvider: { sessionToken }
        )
        await server.activate(on: registrar)
        let transport = RegistrarBackedTransport(registrar: registrar)
        return Harness(
            registrar: registrar,
            transport: transport,
            server: server,
            approver: approver,
            trustStore: trustStore,
            serverIdentity: serverIdentity,
            client: ContinuityPairingClient(transport: transport, approvalPollInterval: 0.02)
        )
    }

    private let baseURL = URL(string: "http://server.local:8080")!

    func testPairingHappyPathGrantsTokenAndStoresPeer() async throws {
        let harness = await makeHarness()
        let identity = ContinuityPeerIdentity(name: "iPhone")

        let start = try await harness.client.startPairing(baseURL: baseURL, identity: identity)
        XCTAssertEqual(start.serverId, harness.serverIdentity.id)

        let code = try await harness.approver.waitForCode()
        let token = try await harness.client.completePairing(
            baseURL: baseURL, start: start, code: code, identity: identity
        )
        XCTAssertEqual(token, "tok-123")

        let stored = await harness.trustStore.peer(withId: identity.id)
        XCTAssertEqual(stored?.publicKey, identity.publicKeyData)
        XCTAssertEqual(stored?.name, "iPhone")
    }

    func testPairingPollsThroughSlowApproval() async throws {
        let harness = await makeHarness()
        harness.approver.decisionDelayNanos = 200_000_000 // records code, then thinks
        let identity = ContinuityPeerIdentity(name: "iPhone")

        let start = try await harness.client.startPairing(baseURL: baseURL, identity: identity)
        let code = try await harness.approver.waitForCode()
        // completePairing internally polls through the 202 window.
        let token = try await harness.client.completePairing(
            baseURL: baseURL, start: start, code: code, identity: identity
        )
        XCTAssertEqual(token, "tok-123")
    }

    func testWrongCodeIsRetryableThenSucceeds() async throws {
        let harness = await makeHarness()
        let identity = ContinuityPeerIdentity(name: "iPhone")

        let start = try await harness.client.startPairing(baseURL: baseURL, identity: identity)
        let code = try await harness.approver.waitForCode()

        let wrongCode = code == "000000" ? "000001" : "000000"
        do {
            _ = try await harness.client.completePairing(
                baseURL: baseURL, start: start, code: wrongCode, identity: identity
            )
            XCTFail("wrong code must throw")
        } catch let error as ContinuityPairingClient.PairingError {
            XCTAssertEqual(error, .wrongCode)
        }

        let token = try await harness.client.completePairing(
            baseURL: baseURL, start: start, code: code, identity: identity
        )
        XCTAssertEqual(token, "tok-123")
    }

    func testDeclinedPairingIsTerminal() async throws {
        let harness = await makeHarness()
        harness.approver.decision = false
        let identity = ContinuityPeerIdentity(name: "iPhone")

        let start = try await harness.client.startPairing(baseURL: baseURL, identity: identity)
        let code = try await harness.approver.waitForCode()
        do {
            _ = try await harness.client.completePairing(
                baseURL: baseURL, start: start, code: code, identity: identity
            )
            XCTFail("declined pairing must throw")
        } catch let error as ContinuityPairingClient.PairingError {
            XCTAssertEqual(error, .declined)
        }
    }

    func testTrustedPeerAuthenticatesSilently() async throws {
        let harness = await makeHarness()
        let identity = ContinuityPeerIdentity(name: "iPhone")
        await harness.trustStore.add(TrustedPeer(
            id: identity.id, name: identity.name, publicKey: identity.publicKeyData
        ))

        let token = try await harness.client.authenticate(baseURL: baseURL, identity: identity)
        XCTAssertEqual(token, "tok-123")
    }

    func testUnknownPeerAuthFailsAsNotPaired() async throws {
        let harness = await makeHarness()
        let identity = ContinuityPeerIdentity(name: "Stranger")
        do {
            _ = try await harness.client.authenticate(baseURL: baseURL, identity: identity)
            XCTFail("unknown peer must be rejected")
        } catch let error as ContinuityPairingClient.PairingError {
            XCTAssertEqual(error, .notPaired)
        }
    }

    func testAuthNonceIsSingleUse() async throws {
        let harness = await makeHarness()
        let identity = ContinuityPeerIdentity(name: "iPhone")
        await harness.trustStore.add(TrustedPeer(
            id: identity.id, name: identity.name, publicKey: identity.publicKeyData
        ))

        // Drive the two auth steps by hand so the completion can be replayed.
        let startBody = try JSONEncoder().encode(
            ContinuityPairingMessages.AuthStartRequest(peerId: identity.id)
        )
        let startResponse = await harness.registrar.invoke(
            method: "POST", path: ContinuityRoutes.authStart, body: startBody
        )
        guard case .data(let startData)? = startResponse?.body else {
            return XCTFail("auth/start must return a body")
        }
        let start = try JSONDecoder().decode(
            ContinuityPairingMessages.AuthStartResponse.self, from: startData
        )
        let signature = try ContinuityPairingMath.signAuth(
            nonce: start.nonce, peerId: identity.id, serverId: start.serverId,
            signingKey: identity.signingKey
        )
        let completeBody = try JSONEncoder().encode(ContinuityPairingMessages.AuthCompleteRequest(
            authId: start.authId, peerId: identity.id, signature: signature
        ))

        let first = await harness.registrar.invoke(
            method: "POST", path: ContinuityRoutes.authComplete, body: completeBody
        )
        XCTAssertEqual(first?.status, 200)

        let replay = await harness.registrar.invoke(
            method: "POST", path: ContinuityRoutes.authComplete, body: completeBody
        )
        XCTAssertEqual(replay?.status, 410, "a consumed nonce must not be replayable")
    }

    func testNoActiveSessionYields404AfterPairing() async throws {
        let harness = await makeHarness(sessionToken: nil)
        let identity = ContinuityPeerIdentity(name: "iPhone")
        let start = try await harness.client.startPairing(baseURL: baseURL, identity: identity)
        let code = try await harness.approver.waitForCode()
        do {
            _ = try await harness.client.completePairing(
                baseURL: baseURL, start: start, code: code, identity: identity
            )
            XCTFail("no active session must throw")
        } catch let error as ContinuityPairingClient.PairingError {
            XCTAssertEqual(error, .noActiveSession)
        }
    }
}

// MARK: - Test doubles

/// Routes ContinuityTransport requests into a MockRouteRegistrar — full
/// client ↔ server round trips with no sockets.
private struct RegistrarBackedTransport: ContinuityTransport {
    let registrar: MockRouteRegistrar

    func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
        guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else {
            throw ContinuityError.invalidResponse(status: -1)
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        guard let response = await registrar.invoke(
            method: request.method,
            path: components.path,
            query: query,
            headers: request.headers,
            body: request.body
        ) else {
            return ContinuityResponse(status: 404)
        }
        var data = Data()
        if case .data(let body) = response.body { data = body }
        return ContinuityResponse(status: response.status, headers: response.headers, body: data)
    }

    func download(
        _ request: ContinuityRequest, to destination: URL, resumeOffset: Int64,
        progress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws -> Int64 {
        throw ContinuityError.invalidResponse(status: -1) // not used by pairing
    }
}

/// Pairing approver that records the displayed code (before any deliberation
/// delay, like a human reading the screen) and answers with `decision`.
private final class ScriptedApprover: ContinuityPairingApproving, @unchecked Sendable {
    private let lock = NSLock()
    private var _code: String?
    var decision = true
    var decisionDelayNanos: UInt64 = 0

    func approvePairing(peerName: String, code: String) async -> Bool {
        synchronized { _code = code }
        if decisionDelayNanos > 0 {
            try? await Task.sleep(nanoseconds: decisionDelayNanos)
        }
        return decision
    }

    /// The code shown on the "server screen", waiting briefly for the prompt
    /// task to fire.
    func waitForCode(timeout: TimeInterval = 2) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let code = synchronized({ _code }) { return code }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ContinuityError.invalidResponse(status: -2)
    }

    /// NSLock.lock is `noasync`; scoped sync helper keeps async methods legal.
    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
