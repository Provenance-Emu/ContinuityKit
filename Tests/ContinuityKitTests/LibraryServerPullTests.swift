import Foundation
import XCTest
@testable import ContinuityKit
import ContinuityKitTesting

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

final class LibraryServerPullTests: XCTestCase {
    /// Auth'd setup with a pull provider serving ONE 4-byte game file on
    /// disk. Mirrors LibraryServerRoutesTests.grantedSetup (silent
    /// trusted+granted path); `policyAllows` is the metering knob.
    private func pullSetup(
        policyAllows: Bool
    ) async throws -> (MockRouteRegistrar, String, ContinuityLibraryServer) {
        let host = ContinuityPeerIdentity(name: "Host")
        let browser = ContinuityPeerIdentity(name: "Browser")
        let trust = FileTrustStore(fileURL: libraryTestTempJSON("pull-trust"))
        await trust.add(browser.asTrustedPeer())
        let grants = FileLibraryGrantStore(fileURL: libraryTestTempJSON("pull-grants"))
        await grants.setGrant(.everything, forPeerId: browser.id)

        let gameURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pull-game-\(UUID().uuidString).cdi")
        try Data("SEGA".utf8).write(to: gameURL)
        let sha = try ContinuityHash.sha256Hex(ofFileAt: gameURL)
        let pullManifest = ContinuityManifest(
            sessionId: "library-pull-test",
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
        let server = ContinuityLibraryServer(
            identity: host, trustStore: trust, grantStore: grants,
            approver: MockBrowseApprover(decision: .dontShare),
            provider: MockLibraryProvider(manifest: browseManifest, artFiles: [:]),
            sharingEnabled: { true },
            pullProvider: MockPullProvider(
                manifest: pullManifest, files: ["ROMs/game.cdi": gameURL]),
            pullPolicy: { policyAllows })
        let registrar = MockRouteRegistrar()
        await server.activate(on: registrar)

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
        let completeResponse = await registrar.invoke(
            method: "POST", path: ContinuityRoutes.libraryAuthComplete, body: completeBody)
        guard case .data(let tokenData)? = completeResponse?.body else {
            throw XCTSkip("no token body — auth flow broken, see LibraryServerAuthTests")
        }
        let token = try JSONDecoder().decode(
            ContinuityLibraryMessages.LibraryTokenResponse.self, from: tokenData).libraryToken
        return (registrar, token, server)
    }

    func testPullMintsManifestWhenPolicyAllows() async throws {
        let (registrar, token, server) = try await pullSetup(policyAllows: true)
        defer { _ = server }  // keep the weakly-held route target alive
        let body = try JSONEncoder().encode(ContinuityLibraryMessages.PullRequest(gameId: "abc"))
        let response = await registrar.invoke(
            method: "POST", path: ContinuityRoutes.libraryPull, headers: ["Authorization": "Bearer \(token)"], body: body)
        XCTAssertEqual(response?.status, 200)
        guard case .data(let data)? = response?.body else { XCTFail("no body"); return }
        let manifest = try ContinuityManifest.decode(from: data)
        XCTAssertEqual(manifest.game.md5Hash, "abc")
    }

    func testPullDeniedByPolicyIs429AndUnknownGame404() async throws {
        let (registrar, token, server) = try await pullSetup(policyAllows: false)
        defer { _ = server }
        let body = try JSONEncoder().encode(ContinuityLibraryMessages.PullRequest(gameId: "abc"))
        let denied = await registrar.invoke(
            method: "POST", path: ContinuityRoutes.libraryPull, headers: ["Authorization": "Bearer \(token)"], body: body)
        XCTAssertEqual(denied?.status, 429)

        let (registrar2, token2, server2) = try await pullSetup(policyAllows: true)
        defer { _ = server2 }
        let unknown = try JSONEncoder().encode(ContinuityLibraryMessages.PullRequest(gameId: "nope"))
        let missing = await registrar2.invoke(
            method: "POST", path: ContinuityRoutes.libraryPull, headers: ["Authorization": "Bearer \(token2)"], body: unknown)
        XCTAssertEqual(missing?.status, 404)
    }

    func testFileServesOnlyGrantedManifestPaths() async throws {
        let (registrar, token, server) = try await pullSetup(policyAllows: true)
        defer { _ = server }
        let headers = ["Authorization": "Bearer \(token)"]

        // BEFORE a granted pull, nothing is servable.
        let early = await registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryFile,
            query: [ContinuityRoutes.filePathQueryKey: "ROMs/game.cdi"], headers: headers)
        XCTAssertEqual(early?.status, 404)

        let body = try JSONEncoder().encode(ContinuityLibraryMessages.PullRequest(gameId: "abc"))
        _ = await registrar.invoke(method: "POST", path: ContinuityRoutes.libraryPull,
                                   headers: headers, body: body)

        let ok = await registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryFile,
            query: [ContinuityRoutes.filePathQueryKey: "ROMs/game.cdi"], headers: headers)
        XCTAssertEqual(ok?.status, 200)
        if case .file = ok?.body {} else { XCTFail("expected streamed file body") }

        let outside = await registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryFile,
            query: [ContinuityRoutes.filePathQueryKey: "../secrets.json"], headers: headers)
        XCTAssertEqual(outside?.status, 404)

        let unauthorized = await registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryFile,
            query: [ContinuityRoutes.filePathQueryKey: "ROMs/game.cdi"])
        XCTAssertEqual(unauthorized?.status, 401)
    }

    func testFileHonorsRangeRequests() async throws {
        let (registrar, token, server) = try await pullSetup(policyAllows: true)
        defer { _ = server }
        let headers = ["Authorization": "Bearer \(token)"]
        let body = try JSONEncoder().encode(ContinuityLibraryMessages.PullRequest(gameId: "abc"))
        _ = await registrar.invoke(method: "POST", path: ContinuityRoutes.libraryPull,
                                   headers: headers, body: body)
        var rangeHeaders = headers
        rangeHeaders["Range"] = "bytes=2-"
        let partial = await registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryFile,
            query: [ContinuityRoutes.filePathQueryKey: "ROMs/game.cdi"], headers: rangeHeaders)
        XCTAssertEqual(partial?.status, 206)
        XCTAssertEqual(partial?.headers["Content-Range"], "bytes 2-3/4")
    }
}
