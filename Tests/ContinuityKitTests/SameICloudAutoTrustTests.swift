import Foundation
import XCTest
@testable import ContinuityKit
import ContinuityKitTesting

/// Same-iCloud auto-trust: a peer whose AuthStartRequest carries the host's
/// own `ic` hash gets a token WITHOUT the consent prompt, and lands trusted
/// with an `.everything` grant. Deny still wins; a wrong hash still prompts;
/// a host with no iCloud hash of its own never shortcuts.
///
/// Fixtures (`MockBrowseApprover`, `MockLibraryProvider`, `libraryTestTempJSON`)
/// are shared with `LibraryServerAuthTests` — same directory, file scope.
final class SameICloudAutoTrustTests: XCTestCase {
    static let manifest = ContinuityLibraryManifest(
        peerId: "host-id", deviceName: "Host", games: [])

    private static let hostHash = "cafebabecafebabe"

    /// Returns the server ALONGSIDE the registrar: the route closures capture
    /// `[weak self]`, so a server the caller drops answers 404 on every route.
    /// Every call site must keep the returned server alive for the exchange.
    private func makeServer(
        approver: MockBrowseApprover,
        trustStore: FileTrustStore,
        grantStore: FileLibraryGrantStore,
        ownICloudHash: @escaping @Sendable () async -> String?
    ) async -> (ContinuityLibraryServer, MockRouteRegistrar) {
        let server = ContinuityLibraryServer(
            identity: ContinuityPeerIdentity(name: "Host"),
            trustStore: trustStore,
            grantStore: grantStore,
            approver: approver,
            provider: MockLibraryProvider(manifest: Self.manifest),
            sharingEnabled: { true },
            ownICloudHash: ownICloudHash
        )
        let registrar = MockRouteRegistrar()
        await server.activate(on: registrar)
        return (server, registrar)
    }

    /// auth-start → sign → auth-complete, invoked ONCE (no polling). The
    /// auto-trust path spawns no detached Task, so its 200 is immediate; the
    /// consent path answers 202 on this first call by construction.
    private func runAuth(
        server: ContinuityLibraryServer,
        registrar: MockRouteRegistrar,
        client: ContinuityPeerIdentity,
        icloudHash: String?
    ) async throws -> (status: Int, body: Data?) {
        // The registrar holds its handlers weakly on the server; pin it for
        // the whole exchange or every route answers 404.
        defer { withExtendedLifetime(server) {} }
        let startBody = try JSONEncoder().encode(ContinuityLibraryMessages.AuthStartRequest(
            peerId: client.id, name: client.name, publicKey: client.publicKeyData,
            icloudHash: icloudHash))
        let startResponse = await registrar.invoke(
            method: "POST", path: ContinuityRoutes.libraryAuthStart, body: startBody)
        guard startResponse?.status == 200 else {
            return (startResponse?.status ?? -1, nil)
        }
        guard case .data(let startData)? = startResponse?.body else {
            XCTFail("no auth-start body"); return (-1, nil)
        }
        let start = try JSONDecoder().decode(
            ContinuityLibraryMessages.AuthStartResponse.self, from: startData)
        let signature = try ContinuityPairingMath.signAuth(
            nonce: start.nonce, peerId: client.id, serverId: start.serverId,
            signingKey: client.signingKey)
        let completeBody = try JSONEncoder().encode(
            ContinuityLibraryMessages.AuthCompleteRequest(
                authId: start.authId, peerId: client.id, signature: signature))
        let response = await registrar.invoke(
            method: "POST", path: ContinuityRoutes.libraryAuthComplete, body: completeBody)
        var data: Data?
        if case .data(let d)? = response?.body { data = d }
        return (response?.status ?? -1, data)
    }

    /// INVARIANT: a matching hash + a valid signature mints a token with no
    /// prompt, TOFU-trusts the peer, and stores an `.everything` grant.
    func testMatchingICloudHashSkipsPromptTrustsAndGrantsEverything() async throws {
        let approver = MockBrowseApprover(decision: .dontShare)  // must NOT be consulted
        let trust = FileTrustStore(fileURL: libraryTestTempJSON("ic-trust"))
        let grants = FileLibraryGrantStore(fileURL: libraryTestTempJSON("ic-grants"))
        let (server, registrar) = await makeServer(
            approver: approver, trustStore: trust, grantStore: grants,
            ownICloudHash: { Self.hostHash })

        let client = ContinuityPeerIdentity(name: "Client")
        let result = try await runAuth(
            server: server, registrar: registrar, client: client, icloudHash: Self.hostHash)

        // Token immediately — no 202 consent round, approver untouched.
        XCTAssertEqual(result.status, 200)
        let token = try JSONDecoder().decode(
            ContinuityLibraryMessages.LibraryTokenResponse.self, from: result.body ?? Data())
        XCTAssertFalse(token.libraryToken.isEmpty)
        XCTAssertTrue(approver.promptedNames.isEmpty)
        let storedGrant = await grants.grant(forPeerId: client.id)
        XCTAssertEqual(storedGrant, .everything)
        let trusted = await trust.peer(withId: client.id)
        XCTAssertNotNil(trusted)
        XCTAssertEqual(trusted?.publicKey, client.publicKeyData)
    }

    /// INVARIANT 1: the shortcut runs strictly AFTER signature verification —
    /// a matching hash with a BAD signature is refused, never auto-trusted.
    func testMatchingICloudHashWithBadSignatureIsRejected() async throws {
        let approver = MockBrowseApprover(decision: .dontShare)
        let trust = FileTrustStore(fileURL: libraryTestTempJSON("ic-trust-sig"))
        let grants = FileLibraryGrantStore(fileURL: libraryTestTempJSON("ic-grants-sig"))
        let (server, registrar) = await makeServer(
            approver: approver, trustStore: trust, grantStore: grants,
            ownICloudHash: { Self.hostHash })

        defer { withExtendedLifetime(server) {} }

        let client = ContinuityPeerIdentity(name: "Client")
        let impostor = ContinuityPeerIdentity(name: "Impostor")
        let startBody = try JSONEncoder().encode(ContinuityLibraryMessages.AuthStartRequest(
            peerId: client.id, name: client.name, publicKey: client.publicKeyData,
            icloudHash: Self.hostHash))
        let startResponse = await registrar.invoke(
            method: "POST", path: ContinuityRoutes.libraryAuthStart, body: startBody)
        guard case .data(let startData)? = startResponse?.body else {
            XCTFail("no auth-start body"); return
        }
        let start = try JSONDecoder().decode(
            ContinuityLibraryMessages.AuthStartResponse.self, from: startData)
        // Signed with the WRONG key — the presented publicKey can't verify it.
        let signature = try ContinuityPairingMath.signAuth(
            nonce: start.nonce, peerId: client.id, serverId: start.serverId,
            signingKey: impostor.signingKey)
        let completeBody = try JSONEncoder().encode(
            ContinuityLibraryMessages.AuthCompleteRequest(
                authId: start.authId, peerId: client.id, signature: signature))
        let response = await registrar.invoke(
            method: "POST", path: ContinuityRoutes.libraryAuthComplete, body: completeBody)

        XCTAssertEqual(response?.status, 403)
        // No token, no trust, no grant: a matching hash alone mints nothing.
        let storedGrant = await grants.grant(forPeerId: client.id)
        XCTAssertNotEqual(storedGrant, .everything)
        let trusted = await trust.peer(withId: client.id)
        XCTAssertNil(trusted)
    }

    /// INVARIANT 3: a mismatched hash falls through to the normal consent
    /// round (202), never to silent approval.
    func testMismatchedICloudHashStillPrompts() async throws {
        let approver = MockBrowseApprover(decision: .dontShare)
        let grants = FileLibraryGrantStore(fileURL: libraryTestTempJSON("ic-grants2"))
        let (server, registrar) = await makeServer(
            approver: approver,
            trustStore: FileTrustStore(fileURL: libraryTestTempJSON("ic-trust2")),
            grantStore: grants,
            ownICloudHash: { Self.hostHash })

        let client = ContinuityPeerIdentity(name: "Client")
        let result = try await runAuth(
            server: server, registrar: registrar, client: client, icloudHash: "0000000000000000")

        // 202 is reachable ONLY through the consent round.
        XCTAssertEqual(result.status, 202)
        let storedGrant = await grants.grant(forPeerId: client.id)
        XCTAssertNotEqual(storedGrant, .everything)
    }

    /// INVARIANT 3: an ABSENT hash (old client, or iCloud off on the peer)
    /// prompts too — a nil claim must not be treated as a match.
    func testAbsentICloudHashStillPrompts() async throws {
        let approver = MockBrowseApprover(decision: .dontShare)
        let (server, registrar) = await makeServer(
            approver: approver,
            trustStore: FileTrustStore(fileURL: libraryTestTempJSON("ic-trust3")),
            grantStore: FileLibraryGrantStore(fileURL: libraryTestTempJSON("ic-grants3")),
            ownICloudHash: { Self.hostHash })

        let client = ContinuityPeerIdentity(name: "Client")
        let result = try await runAuth(
            server: server, registrar: registrar, client: client, icloudHash: nil)
        XCTAssertEqual(result.status, 202)
    }

    /// INVARIANT 3: an EMPTY-string hash is not a match either.
    func testEmptyICloudHashStillPrompts() async throws {
        let approver = MockBrowseApprover(decision: .dontShare)
        let (server, registrar) = await makeServer(
            approver: approver,
            trustStore: FileTrustStore(fileURL: libraryTestTempJSON("ic-trust4")),
            grantStore: FileLibraryGrantStore(fileURL: libraryTestTempJSON("ic-grants4")),
            ownICloudHash: { "" })

        let client = ContinuityPeerIdentity(name: "Client")
        let result = try await runAuth(server: server, registrar: registrar, client: client, icloudHash: "")
        XCTAssertEqual(result.status, 202)
    }

    /// INVARIANT 4: the compare is EXACT — no case-folding, no prefix match.
    func testICloudHashCompareIsCaseSensitiveAndNotAPrefixMatch() async throws {
        for peerHash in [Self.hostHash.uppercased(), String(Self.hostHash.prefix(8))] {
            let approver = MockBrowseApprover(decision: .dontShare)
            let (server, registrar) = await makeServer(
                approver: approver,
                trustStore: FileTrustStore(fileURL: libraryTestTempJSON("ic-trust5")),
                grantStore: FileLibraryGrantStore(fileURL: libraryTestTempJSON("ic-grants5")),
                ownICloudHash: { Self.hostHash })
            let client = ContinuityPeerIdentity(name: "Client")
            let result = try await runAuth(
                server: server, registrar: registrar, client: client, icloudHash: peerHash)
            XCTAssertEqual(result.status, 202, "hash \(peerHash) must not auto-trust")
        }
    }

    /// INVARIANT 2: a `.denied` grant beats an iCloud match — refused at
    /// auth-start, before a nonce is ever issued.
    func testDeniedGrantBeatsICloudMatch() async throws {
        let grants = FileLibraryGrantStore(fileURL: libraryTestTempJSON("ic-grants6"))
        let client = ContinuityPeerIdentity(name: "Client")
        await grants.setGrant(.denied, forPeerId: client.id)
        let approver = MockBrowseApprover(decision: .shareEverything)
        let (server, registrar) = await makeServer(
            approver: approver,
            trustStore: FileTrustStore(fileURL: libraryTestTempJSON("ic-trust6")),
            grantStore: grants,
            ownICloudHash: { Self.hostHash })

        let result = try await runAuth(
            server: server, registrar: registrar, client: client, icloudHash: Self.hostHash)
        XCTAssertEqual(result.status, 403)
        XCTAssertTrue(approver.promptedNames.isEmpty)
        let storedGrant = await grants.grant(forPeerId: client.id)
        XCTAssertEqual(storedGrant, .denied)
    }

    /// INVARIANT 5: the host having NO hash of its own must never match a
    /// peer's absent hash — `nil == nil` is not "same account". Both the
    /// nil-peer and the some-peer cases fall through to the consent round.
    func testNilOwnHashNeverShortcuts() async throws {
        for peerHash: String? in [nil, Self.hostHash, "0000000000000000"] {
            let approver = MockBrowseApprover(decision: .dontShare)
            let grants = FileLibraryGrantStore(fileURL: libraryTestTempJSON("ic-grants7"))
            let (server, registrar) = await makeServer(
                approver: approver,
                trustStore: FileTrustStore(fileURL: libraryTestTempJSON("ic-trust7")),
                grantStore: grants,
                ownICloudHash: { nil })

            let client = ContinuityPeerIdentity(name: "Client")
            let result = try await runAuth(
                server: server, registrar: registrar, client: client, icloudHash: peerHash)
            XCTAssertEqual(
                result.status, 202,
                "host with no iCloud hash must prompt (peer hash: \(peerHash ?? "nil"))")
            let storedGrant = await grants.grant(forPeerId: client.id)
            XCTAssertNotEqual(storedGrant, .everything)
        }
    }
}
