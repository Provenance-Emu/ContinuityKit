import ContinuityKit
import ContinuityKitTesting
import Foundation
import XCTest

/// Code-less continue requests (always-discoverable flow): client ↔ server
/// round trips over the registrar, trust-on-first-use, and the grantPolicy
/// metering seam.
final class ContinueRequestTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-continue-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private struct Harness {
        let server: ContinuityPairingServer
        let approver: ScriptedContinueApprover
        let trustStore: FileTrustStore
        let client: ContinuityPairingClient
        let grantCount: Counter
    }

    private func makeHarness(
        sessionToken: String? = "tok-123",
        continueEnabled: Bool = true,
        grantLimit: Int = Int.max
    ) async -> Harness {
        let registrar = MockRouteRegistrar()
        let approver = ScriptedContinueApprover()
        let trustStore = FileTrustStore(fileURL: tempDir.appendingPathComponent("peers.json"))
        let grantCount = Counter()
        let server = ContinuityPairingServer(
            identity: ContinuityPeerIdentity(name: "Apple TV"),
            trustStore: trustStore,
            approver: AlwaysDenyPairingApprover(),
            continueApprover: continueEnabled ? approver : nil,
            sessionTokenProvider: { sessionToken },
            grantPolicy: { grantCount.increment() <= grantLimit }
        )
        await server.activate(on: registrar)
        let transport = RegistrarBackedTransport(registrar: registrar)
        return Harness(
            server: server,
            approver: approver,
            trustStore: trustStore,
            client: ContinuityPairingClient(transport: transport, approvalPollInterval: 0.02),
            grantCount: grantCount
        )
    }

    private let baseURL = URL(string: "http://server.local:8080")!

    func testAllowOnceGrantsTokenWithoutTrust() async throws {
        let harness = await makeHarness()
        harness.approver.decision = .allowOnce
        let identity = ContinuityPeerIdentity(name: "iPhone")

        let token = try await harness.client.requestContinue(baseURL: baseURL, identity: identity)
        XCTAssertEqual(token, "tok-123")

        let stored = await harness.trustStore.peer(withId: identity.id)
        XCTAssertNil(stored, "allowOnce must not add the peer to the trust store")
    }

    func testAllowAlwaysGrantsTokenAndTrustsPeer() async throws {
        let harness = await makeHarness()
        harness.approver.decision = .allowAlways
        let identity = ContinuityPeerIdentity(name: "iPhone")

        let token = try await harness.client.requestContinue(baseURL: baseURL, identity: identity)
        XCTAssertEqual(token, "tok-123")

        let stored = await harness.trustStore.peer(withId: identity.id)
        XCTAssertEqual(stored?.publicKey, identity.publicKeyData)

        // The remembered key must work for silent auth afterwards.
        let silent = try await harness.client.authenticate(baseURL: baseURL, identity: identity)
        XCTAssertEqual(silent, "tok-123")
    }

    func testDenyIsTerminal() async throws {
        let harness = await makeHarness()
        harness.approver.decision = .deny
        let identity = ContinuityPeerIdentity(name: "Stranger")

        do {
            _ = try await harness.client.requestContinue(baseURL: baseURL, identity: identity)
            XCTFail("denied continue must throw")
        } catch let error as ContinuityPairingClient.PairingError {
            XCTAssertEqual(error, .declined)
        }
    }

    func testPollsThroughSlowApproval() async throws {
        let harness = await makeHarness()
        harness.approver.decision = .allowOnce
        harness.approver.decisionDelayNanos = 200_000_000
        let identity = ContinuityPeerIdentity(name: "iPhone")

        let token = try await harness.client.requestContinue(baseURL: baseURL, identity: identity)
        XCTAssertEqual(token, "tok-123")
    }

    func testHostWithoutContinueRoutesReadsAsUnsupported() async throws {
        let harness = await makeHarness(continueEnabled: false)
        let identity = ContinuityPeerIdentity(name: "iPhone")

        do {
            _ = try await harness.client.requestContinue(baseURL: baseURL, identity: identity)
            XCTFail("missing routes must throw")
        } catch let error as ContinuityPairingClient.PairingError {
            XCTAssertEqual(error, .continueUnsupported)
        }
    }

    func testNoActiveSessionSurfacesAfterApproval() async throws {
        let harness = await makeHarness(sessionToken: nil)
        harness.approver.decision = .allowOnce
        let identity = ContinuityPeerIdentity(name: "iPhone")

        do {
            _ = try await harness.client.requestContinue(baseURL: baseURL, identity: identity)
            XCTFail("no session must throw")
        } catch let error as ContinuityPairingClient.PairingError {
            XCTAssertEqual(error, .noActiveSession)
        }
    }

    func testGrantPolicyMetersEveryHandout() async throws {
        // One grant allowed: the first pull succeeds, the second 429s — for
        // BOTH the continue flow and silent trusted-peer auth.
        let harness = await makeHarness(grantLimit: 1)
        harness.approver.decision = .allowAlways
        let identity = ContinuityPeerIdentity(name: "iPhone")

        let token = try await harness.client.requestContinue(baseURL: baseURL, identity: identity)
        XCTAssertEqual(token, "tok-123")

        do {
            _ = try await harness.client.authenticate(baseURL: baseURL, identity: identity)
            XCTFail("exhausted grant policy must throw")
        } catch let error as ContinuityPairingClient.PairingError {
            XCTAssertEqual(error, .hostLimitReached)
        }
    }
}

// MARK: - Test doubles

/// Routes ContinuityTransport requests into a MockRouteRegistrar — same
/// harness as PairingTrustTests (private there, so duplicated).
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
        throw ContinuityError.invalidResponse(status: -1) // not used here
    }
}

private final class ScriptedContinueApprover: ContinuityContinueApproving, @unchecked Sendable {
    private let lock = NSLock()
    private var _decision: ContinuityContinueDecision = .deny
    private var _delayNanos: UInt64 = 0

    var decision: ContinuityContinueDecision {
        get { lock.lock(); defer { lock.unlock() }; return _decision }
        set { lock.lock(); defer { lock.unlock() }; _decision = newValue }
    }

    var decisionDelayNanos: UInt64 {
        get { lock.lock(); defer { lock.unlock() }; return _delayNanos }
        set { lock.lock(); defer { lock.unlock() }; _delayNanos = newValue }
    }

    func approveContinue(peerName: String) async -> ContinuityContinueDecision {
        let delay = decisionDelayNanos
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        return decision
    }
}

/// The classic pairing approver is irrelevant to these tests — always deny.
private struct AlwaysDenyPairingApprover: ContinuityPairingApproving {
    func approvePairing(peerName: String, code: String) async -> Bool { false }
}

/// Thread-safe increment-and-read counter for the grant policy.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Returns the value AFTER incrementing (1 on first call).
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
