import Foundation
import XCTest
@testable import ContinuityKit
import ContinuityKitTesting

/// Scripted pull approver: records prompts, answers with a preset decision.
private final class MockPullApprover: ContinuityLibraryPullApproving, @unchecked Sendable {
    let decision: ContinuityLibraryPullDecision
    private let lock = NSLock()
    private var _prompts: [(peerName: String, gameTitle: String)] = []
    var prompts: [(peerName: String, gameTitle: String)] {
        lock.lock(); defer { lock.unlock() }
        return _prompts
    }

    init(decision: ContinuityLibraryPullDecision) { self.decision = decision }

    func approveLibraryPull(peerName: String, gameTitle: String) async -> ContinuityLibraryPullDecision {
        record(peerName: peerName, gameTitle: gameTitle)
        return decision
    }

    private func record(peerName: String, gameTitle: String) {
        lock.lock(); defer { lock.unlock() }
        _prompts.append((peerName, gameTitle))
    }
}

private struct MockPullProvider: ContinuityLibraryPullProviding {
    let manifest: ContinuityManifest
    let files: [String: URL]

    func pullManifest(forGameId gameId: String) async throws -> ContinuityManifest? {
        gameId == manifest.game.md5Hash ? manifest : nil
    }

    func fileURL(forRelativePath relativePath: String) async throws -> URL? {
        files[relativePath]
    }
}

/// P3: Ask-Per-Game grants. Browse stays silent for a trusted askPerGame
/// peer; every pull rides a 202 consent window answered Allow /
/// Always-for-this-device / Deny on the host.
final class LibraryServerAskPerGameTests: XCTestCase {
    private struct Setup {
        let registrar: MockRouteRegistrar
        let token: String
        let server: ContinuityLibraryServer
        let grants: FileLibraryGrantStore
        let browser: ContinuityPeerIdentity
        let browseApprover: MockBrowseApprover
    }

    /// Trusted peer with a preset grant; same auth dance as
    /// LibraryServerPullTests.pullSetup (private there, so duplicated).
    private func setup(
        grant: ContinuityLibraryGrant,
        browseDecision: ContinuityLibraryBrowseDecision = .dontShare,
        pullApprover: (any ContinuityLibraryPullApproving)?,
        preTrusted: Bool = true
    ) async throws -> Setup {
        let host = ContinuityPeerIdentity(name: "Host")
        let browser = ContinuityPeerIdentity(name: "Browser")
        let trust = FileTrustStore(fileURL: libraryTestTempJSON("apg-trust"))
        if preTrusted { await trust.add(browser.asTrustedPeer()) }
        let grants = FileLibraryGrantStore(fileURL: libraryTestTempJSON("apg-grants"))
        if preTrusted { await grants.setGrant(grant, forPeerId: browser.id) }

        let gameURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apg-game-\(UUID().uuidString).cdi")
        try Data("SEGA".utf8).write(to: gameURL)
        let sha = try ContinuityHash.sha256Hex(ofFileAt: gameURL)
        let pullManifest = ContinuityManifest(
            sessionId: "library-pull-apg",
            mintedAt: Date(),
            sourceDevice: SourceDevice(name: "Host", platform: "tvOS", appVersion: "1.0"),
            game: GameIdentity(md5Hash: "abc", displayName: "Ikaruga", platform: "dreamcast"),
            files: [FileDescriptor(kind: .gameFile, relativePath: "ROMs/game.cdi",
                                   sha256: sha, size: 4, required: true)]
        )
        let browseManifest = ContinuityLibraryManifest(
            peerId: host.id, deviceName: "Host",
            games: [.init(title: "Ikaruga", platform: "Dreamcast", md5: "abc",
                          sizeBytes: 4, artKey: nil, saveStateCount: 0, vmuFileCount: nil)])
        let browseApprover = MockBrowseApprover(decision: browseDecision)
        let server = ContinuityLibraryServer(
            identity: host, trustStore: trust, grantStore: grants,
            approver: browseApprover,
            provider: MockLibraryProvider(manifest: browseManifest, artFiles: [:]),
            sharingEnabled: { true },
            pullProvider: MockPullProvider(
                manifest: pullManifest, files: ["ROMs/game.cdi": gameURL]),
            pullPolicy: { true },
            pullApprover: pullApprover)
        let registrar = MockRouteRegistrar()
        await server.activate(on: registrar)

        let token = try await authenticate(browser: browser, registrar: registrar)
        return Setup(registrar: registrar, token: token, server: server,
                     grants: grants, browser: browser, browseApprover: browseApprover)
    }

    /// Runs browse auth, polling through any 202 consent window.
    private func authenticate(
        browser: ContinuityPeerIdentity, registrar: MockRouteRegistrar
    ) async throws -> String {
        let startBody = try JSONEncoder().encode(ContinuityLibraryMessages.AuthStartRequest(
            peerId: browser.id, name: browser.name, publicKey: browser.publicKeyData))
        let startResponse = await registrar.invoke(
            method: "POST", path: ContinuityRoutes.libraryAuthStart, body: startBody)
        guard case .data(let startData)? = startResponse?.body else {
            throw XCTSkip("no start body — auth flow broken, see LibraryServerAuthTests")
        }
        let start = try JSONDecoder().decode(
            ContinuityLibraryMessages.AuthStartResponse.self, from: startData)
        let signature = try ContinuityPairingMath.signAuth(
            nonce: start.nonce, peerId: browser.id, serverId: start.serverId,
            signingKey: browser.signingKey)
        let completeBody = try JSONEncoder().encode(ContinuityLibraryMessages.AuthCompleteRequest(
            authId: start.authId, peerId: browser.id, signature: signature))
        for _ in 0..<50 {
            let response = await registrar.invoke(
                method: "POST", path: ContinuityRoutes.libraryAuthComplete, body: completeBody)
            if response?.status == 202 {
                try await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            guard response?.status == 200, case .data(let tokenData)? = response?.body else {
                throw XCTSkip("auth answered \(response?.status ?? 0) — see LibraryServerAuthTests")
            }
            return try JSONDecoder().decode(
                ContinuityLibraryMessages.LibraryTokenResponse.self, from: tokenData).libraryToken
        }
        throw XCTSkip("auth never resolved — see LibraryServerAuthTests")
    }

    /// POSTs the pull route, polling through the 202 consent window (bounded).
    private func pollPull(
        registrar: MockRouteRegistrar, token: String, gameId: String = "abc"
    ) async throws -> ContinuityHTTPResponse? {
        let body = try JSONEncoder().encode(ContinuityLibraryMessages.PullRequest(gameId: gameId))
        var last: ContinuityHTTPResponse?
        for _ in 0..<50 {
            last = await registrar.invoke(
                method: "POST", path: ContinuityRoutes.libraryPull,
                headers: ["Authorization": "Bearer \(token)"], body: body)
            if last?.status != 202 { return last }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return last
    }

    // MARK: - Browse decision

    /// A brand-new peer whose host answers Ask Per Game gets a token, a
    /// persistent askPerGame grant, AND trust (the pull prompt must
    /// recognize the peer); the next browse is silent.
    func testAskPerGameBrowseDecisionMintsTokenAndTrusts() async throws {
        let s = try await setup(grant: .askPerGame, browseDecision: .askPerGame,
                                pullApprover: nil, preTrusted: false)
        defer { _ = s.server }
        XCTAssertFalse(s.token.isEmpty)
        let grant = await s.grants.grant(forPeerId: s.browser.id)
        XCTAssertEqual(grant, .askPerGame)
        XCTAssertEqual(s.browseApprover.promptedNames, ["Browser"])

        // Re-auth is the silent path now: no second prompt.
        _ = try await authenticate(browser: s.browser, registrar: s.registrar)
        XCTAssertEqual(s.browseApprover.promptedNames, ["Browser"])
    }

    // MARK: - Pull consent

    /// Allow: 202 window resolves to the manifest; the grant stays
    /// askPerGame and the NEXT pull prompts again (approval is one-shot).
    func testAllowResolvesPullAndNextPullPromptsAgain() async throws {
        let approver = MockPullApprover(decision: .allow)
        let s = try await setup(grant: .askPerGame, pullApprover: approver)
        defer { _ = s.server }

        let response = try await pollPull(registrar: s.registrar, token: s.token)
        XCTAssertEqual(response?.status, 200)
        guard case .data(let data)? = response?.body else { XCTFail("no body"); return }
        let manifest = try ContinuityManifest.decode(from: data)
        XCTAssertEqual(manifest.game.md5Hash, "abc")
        // Prompt named the trusted peer and the browsed game title.
        XCTAssertEqual(approver.prompts.first?.peerName, "Browser")
        XCTAssertEqual(approver.prompts.first?.gameTitle, "Ikaruga")
        let grant = await s.grants.grant(forPeerId: s.browser.id)
        XCTAssertEqual(grant, .askPerGame)

        let second = try await pollPull(registrar: s.registrar, token: s.token)
        XCTAssertEqual(second?.status, 200)
        XCTAssertEqual(approver.prompts.count, 2)
    }

    /// Deny: 403 for this pull only — grant unchanged, nothing allowlisted,
    /// and browsing (manifest route) still works.
    func testDenyAnswers403KeepsGrantAndBrowse() async throws {
        let approver = MockPullApprover(decision: .deny)
        let s = try await setup(grant: .askPerGame, pullApprover: approver)
        defer { _ = s.server }

        let response = try await pollPull(registrar: s.registrar, token: s.token)
        XCTAssertEqual(response?.status, 403)
        let grant = await s.grants.grant(forPeerId: s.browser.id)
        XCTAssertEqual(grant, .askPerGame)

        // The denied pull allowlisted nothing.
        let file = await s.registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryFile,
            query: [ContinuityRoutes.filePathQueryKey: "ROMs/game.cdi"],
            headers: ["Authorization": "Bearer \(s.token)"])
        XCTAssertEqual(file?.status, 404)

        // Browse survives a declined pull.
        let manifest = await s.registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryManifest,
            headers: ["Authorization": "Bearer \(s.token)"])
        XCTAssertEqual(manifest?.status, 200)
    }

    /// Always for this device: the pull succeeds AND the grant upgrades to
    /// everything — the second pull is silent.
    func testAlwaysForDeviceUpgradesGrantToEverything() async throws {
        let approver = MockPullApprover(decision: .alwaysForDevice)
        let s = try await setup(grant: .askPerGame, pullApprover: approver)
        defer { _ = s.server }

        let response = try await pollPull(registrar: s.registrar, token: s.token)
        XCTAssertEqual(response?.status, 200)
        let grant = await s.grants.grant(forPeerId: s.browser.id)
        XCTAssertEqual(grant, .everything)

        let second = try await pollPull(registrar: s.registrar, token: s.token)
        XCTAssertEqual(second?.status, 200)
        XCTAssertEqual(approver.prompts.count, 1)
    }

    /// No approval UI wired (pullApprover nil) → Ask-Per-Game pulls are
    /// refused outright, never silently allowed.
    func testAskPerGameWithoutApproverRefuses() async throws {
        let s = try await setup(grant: .askPerGame, pullApprover: nil)
        defer { _ = s.server }
        let response = try await pollPull(registrar: s.registrar, token: s.token)
        XCTAssertEqual(response?.status, 403)
    }

    /// Everything-grant peers never see the approver (P2 behavior intact).
    func testEverythingGrantSkipsApprover() async throws {
        let approver = MockPullApprover(decision: .deny)
        let s = try await setup(grant: .everything, pullApprover: approver)
        defer { _ = s.server }
        let response = try await pollPull(registrar: s.registrar, token: s.token)
        XCTAssertEqual(response?.status, 200)
        XCTAssertTrue(approver.prompts.isEmpty)
    }
}
