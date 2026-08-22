import Foundation
import XCTest
@testable import ContinuityKit
import ContinuityKitTesting

final class LibraryServerRoutesTests: XCTestCase {
    /// Grants a token via the real auth flow (trusted+granted silent path)
    /// and returns (registrar, token, artFileURL, server). The server rides
    /// along because the route handlers hold it weakly — dropping it would
    /// turn every route into the 404 "unavailable" fallback (production keeps
    /// it alive on the owning service).
    private func grantedSetup() async throws -> (MockRouteRegistrar, String, URL, ContinuityLibraryServer) {
        let host = ContinuityPeerIdentity(name: "Host")
        let browser = ContinuityPeerIdentity(name: "Browser")
        let trust = FileTrustStore(fileURL: libraryTestTempJSON("routes-trust"))
        await trust.add(browser.asTrustedPeer())
        let grants = FileLibraryGrantStore(fileURL: libraryTestTempJSON("routes-grants"))
        await grants.setGrant(.everything, forPeerId: browser.id)

        let artURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: artURL)
        let manifest = ContinuityLibraryManifest(
            peerId: host.id, deviceName: "Host",
            games: [.init(title: "Ikaruga", platform: "Dreamcast", md5: "abc",
                          sizeBytes: 3, artKey: "cover.jpg", saveStateCount: 0, vmuFileCount: nil)])
        let server = ContinuityLibraryServer(
            identity: host, trustStore: trust, grantStore: grants,
            approver: MockBrowseApprover(decision: .dontShare),
            provider: MockLibraryProvider(manifest: manifest, artFiles: ["cover.jpg": artURL]),
            sharingEnabled: { true })
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
        return (registrar, token, artURL, server)
    }

    func testManifestRequiresTokenAndServesJSON() async throws {
        let (registrar, token, _, server) = try await grantedSetup()
        defer { _ = server }  // keep the weakly-held route target alive

        let unauthorized = await registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryManifest)
        XCTAssertEqual(unauthorized?.status, 401)

        let ok = await registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryManifest,
            headers: ["Authorization": "Bearer \(token)"])
        XCTAssertEqual(ok?.status, 200)
        guard case .data(let data)? = ok?.body else { XCTFail("no body"); return }
        let manifest = try ContinuityLibraryManifest.decoded(from: data)
        XCTAssertEqual(manifest.games.first?.title, "Ikaruga")
    }

    /// Conditional GET: a matching If-None-Match gets 304 with no body; a
    /// mismatched or absent one gets 200 with the manifest AND an ETag
    /// header carrying the same version — so an older peer that never sends
    /// the header just always sees 200 (wire-compatible).
    func testManifestConditionalGetReturns304OnMatchAnd200WithETagOtherwise() async throws {
        let (registrar, token, _, server) = try await grantedSetup()
        defer { _ = server }  // keep the weakly-held route target alive
        let authHeader = ["Authorization": "Bearer \(token)"]

        let first = await registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryManifest, headers: authHeader)
        XCTAssertEqual(first?.status, 200)
        let etag = try XCTUnwrap(first?.headers["ETag"])
        guard case .data(let data)? = first?.body else { XCTFail("no body"); return }
        let manifest = try ContinuityLibraryManifest.decoded(from: data)
        XCTAssertEqual(manifest.catalogVersion, etag)

        let matching = await registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryManifest,
            headers: authHeader.merging(["If-None-Match": etag]) { _, new in new })
        XCTAssertEqual(matching?.status, 304)
        if case .empty = matching?.body {} else { XCTFail("expected empty 304 body") }

        let mismatched = await registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryManifest,
            headers: authHeader.merging(["If-None-Match": "stale-tag"]) { _, new in new })
        XCTAssertEqual(mismatched?.status, 200)
        XCTAssertEqual(mismatched?.headers["ETag"], etag)
    }

    func testArtServesFileAndBlocksTraversal() async throws {
        let (registrar, token, _, server) = try await grantedSetup()
        defer { _ = server }  // keep the weakly-held route target alive
        let headers = ["Authorization": "Bearer \(token)"]

        let ok = await registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryArt,
            query: [ContinuityRoutes.artKeyQueryKey: "cover.jpg"], headers: headers)
        XCTAssertEqual(ok?.status, 200)
        if case .file = ok?.body {} else { XCTFail("expected streamed file body") }

        let missing = await registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryArt,
            query: [ContinuityRoutes.artKeyQueryKey: "nope.jpg"], headers: headers)
        XCTAssertEqual(missing?.status, 404)

        let traversal = await registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryArt,
            query: [ContinuityRoutes.artKeyQueryKey: "../secrets.json"], headers: headers)
        XCTAssertEqual(traversal?.status, 400)

        let badToken = await registrar.invoke(
            method: "GET", path: ContinuityRoutes.libraryArt,
            query: [ContinuityRoutes.artKeyQueryKey: "cover.jpg"],
            headers: ["Authorization": "Bearer wrong-token"])
        XCTAssertEqual(badToken?.status, 401)
    }
}
