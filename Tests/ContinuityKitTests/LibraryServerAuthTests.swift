import Foundation
import XCTest
@testable import ContinuityKit
import ContinuityKitTesting

/// Scripted approver: records prompts, answers with a preset decision.
final class MockBrowseApprover: ContinuityLibraryBrowseApproving, @unchecked Sendable {
    let decision: ContinuityLibraryBrowseDecision
    private let lock = NSLock()
    private var _promptedNames: [String] = []
    var promptedNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return _promptedNames
    }

    init(decision: ContinuityLibraryBrowseDecision) { self.decision = decision }

    func approveLibraryBrowse(peerName: String) async -> ContinuityLibraryBrowseDecision {
        recordPrompt(peerName)
        return decision
    }

    /// NSLock.lock is `noasync`; funneling through a synchronous helper keeps
    /// the async protocol method legal (same pattern as MockTransport).
    private func recordPrompt(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        _promptedNames.append(name)
    }
}

/// Static manifest/art provider for tests.
struct MockLibraryProvider: ContinuityLibraryProviding {
    var manifest: ContinuityLibraryManifest
    var artFiles: [String: URL] = [:]
    func libraryManifest() async throws -> ContinuityLibraryManifest { manifest }
    func artworkFileURL(forKey key: String) async -> URL? { artFiles[key] }
}

func libraryTestTempJSON(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("libsrv-\(label)-\(UUID().uuidString).json")
}

final class LibraryServerAuthTests: XCTestCase {
    static let manifest = ContinuityLibraryManifest(
        peerId: "host-id", deviceName: "Host", games: [])

    /// Full happy path for a brand-new peer whose host answers Share Everything.
    func testNewPeerPromptedThenGranted() async throws {
        let host = ContinuityPeerIdentity(name: "Host")
        let browser = ContinuityPeerIdentity(name: "Browser")
        let trust = FileTrustStore(fileURL: libraryTestTempJSON("trust"))
        let grants = FileLibraryGrantStore(fileURL: libraryTestTempJSON("grants"))
        let approver = MockBrowseApprover(decision: .shareEverything)
        let server = ContinuityLibraryServer(
            identity: host, trustStore: trust, grantStore: grants,
            approver: approver, provider: MockLibraryProvider(manifest: Self.manifest),
            sharingEnabled: { true })
        let registrar = MockRouteRegistrar()
        await server.activate(on: registrar)

        let startBody = try JSONEncoder().encode(ContinuityLibraryMessages.AuthStartRequest(
            peerId: browser.id, name: browser.name, publicKey: browser.publicKeyData))
        let startResponse = await registrar.invoke(
            method: "POST", path: ContinuityRoutes.libraryAuthStart, body: startBody)
        XCTAssertEqual(startResponse?.status, 200)
        guard case .data(let startData)? = startResponse?.body else {
            XCTFail("no start body"); return
        }
        let start = try JSONDecoder().decode(
            ContinuityLibraryMessages.AuthStartResponse.self, from: startData)

        let signature = try ContinuityPairingMath.signAuth(
            nonce: start.nonce, peerId: browser.id, serverId: start.serverId,
            signingKey: browser.signingKey)
        let completeBody = try JSONEncoder().encode(ContinuityLibraryMessages.AuthCompleteRequest(
            authId: start.authId, peerId: browser.id, signature: signature))

        // Poll until the detached approval task lands (bounded).
        var status = 0
        var tokenData: Data?
        for _ in 0..<50 {
            let response = await registrar.invoke(
                method: "POST", path: ContinuityRoutes.libraryAuthComplete, body: completeBody)
            status = response?.status ?? 0
            if status != 202 {
                if case .data(let data)? = response?.body { tokenData = data }
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(status, 200)
        let token = try JSONDecoder().decode(
            ContinuityLibraryMessages.LibraryTokenResponse.self, from: tokenData ?? Data())
        XCTAssertFalse(token.libraryToken.isEmpty)
        // Share Everything TOFU-trusts the peer and stores the grant.
        let trusted = await trust.peer(withId: browser.id)
        XCTAssertNotNil(trusted)
        let grant = await grants.grant(forPeerId: browser.id)
        XCTAssertEqual(grant, .everything)
    }

    /// Denied grant answers 403 at START — no nonce, no prompt.
    func testDeniedPeerRefusedAtStart() async throws {
        let host = ContinuityPeerIdentity(name: "Host")
        let browser = ContinuityPeerIdentity(name: "Browser")
        let grants = FileLibraryGrantStore(fileURL: libraryTestTempJSON("grants2"))
        await grants.setGrant(.denied, forPeerId: browser.id)
        let approver = MockBrowseApprover(decision: .shareEverything)
        let server = ContinuityLibraryServer(
            identity: host, trustStore: FileTrustStore(fileURL: libraryTestTempJSON("trust2")),
            grantStore: grants, approver: approver,
            provider: MockLibraryProvider(manifest: Self.manifest), sharingEnabled: { true })
        let registrar = MockRouteRegistrar()
        await server.activate(on: registrar)

        let body = try JSONEncoder().encode(ContinuityLibraryMessages.AuthStartRequest(
            peerId: browser.id, name: browser.name, publicKey: browser.publicKeyData))
        let response = await registrar.invoke(
            method: "POST", path: ContinuityRoutes.libraryAuthStart, body: body)
        XCTAssertEqual(response?.status, 403)
        XCTAssertTrue(approver.promptedNames.isEmpty)
    }

    /// Sharing switched off answers 404 everywhere.
    func testSharingOffAnswers404() async throws {
        let host = ContinuityPeerIdentity(name: "Host")
        let server = ContinuityLibraryServer(
            identity: host, trustStore: FileTrustStore(fileURL: libraryTestTempJSON("trust3")),
            grantStore: FileLibraryGrantStore(fileURL: libraryTestTempJSON("grants3")),
            approver: MockBrowseApprover(decision: .shareEverything),
            provider: MockLibraryProvider(manifest: Self.manifest), sharingEnabled: { false })
        let registrar = MockRouteRegistrar()
        await server.activate(on: registrar)
        let body = try JSONEncoder().encode(ContinuityLibraryMessages.AuthStartRequest(
            peerId: "x", name: "X", publicKey: Data()))
        let response = await registrar.invoke(
            method: "POST", path: ContinuityRoutes.libraryAuthStart, body: body)
        XCTAssertEqual(response?.status, 404)
    }

    /// An already-trusted, already-granted peer authenticates silently —
    /// and a FORGED signature for its peerId is rejected even though the
    /// request presents a matching (attacker) public key at start.
    func testTrustedPeerSilentAndKeySwapRejected() async throws {
        let host = ContinuityPeerIdentity(name: "Host")
        let browser = ContinuityPeerIdentity(name: "Browser")
        let attacker = ContinuityPeerIdentity(id: browser.id, name: "Evil")
        let trust = FileTrustStore(fileURL: libraryTestTempJSON("trust4"))
        await trust.add(browser.asTrustedPeer())
        let grants = FileLibraryGrantStore(fileURL: libraryTestTempJSON("grants4"))
        await grants.setGrant(.everything, forPeerId: browser.id)
        let approver = MockBrowseApprover(decision: .dontShare)
        let server = ContinuityLibraryServer(
            identity: host, trustStore: trust, grantStore: grants, approver: approver,
            provider: MockLibraryProvider(manifest: Self.manifest), sharingEnabled: { true })
        let registrar = MockRouteRegistrar()
        await server.activate(on: registrar)

        func complete(as identity: ContinuityPeerIdentity) async throws -> Int {
            let startBody = try JSONEncoder().encode(ContinuityLibraryMessages.AuthStartRequest(
                peerId: identity.id, name: identity.name, publicKey: identity.publicKeyData))
            let startResponse = await registrar.invoke(
                method: "POST", path: ContinuityRoutes.libraryAuthStart, body: startBody)
            guard case .data(let data)? = startResponse?.body else { return -1 }
            let start = try JSONDecoder().decode(
                ContinuityLibraryMessages.AuthStartResponse.self, from: data)
            let signature = try ContinuityPairingMath.signAuth(
                nonce: start.nonce, peerId: identity.id, serverId: start.serverId,
                signingKey: identity.signingKey)
            let completeBody = try JSONEncoder().encode(
                ContinuityLibraryMessages.AuthCompleteRequest(
                    authId: start.authId, peerId: identity.id, signature: signature))
            let response = await registrar.invoke(
                method: "POST", path: ContinuityRoutes.libraryAuthComplete, body: completeBody)
            return response?.status ?? -1
        }

        let silentStatus = try await complete(as: browser)
        XCTAssertEqual(silentStatus, 200)               // silent, no prompt
        XCTAssertTrue(approver.promptedNames.isEmpty)
        let attackerStatus = try await complete(as: attacker)
        XCTAssertEqual(attackerStatus, 403)             // stored key wins
    }
}
