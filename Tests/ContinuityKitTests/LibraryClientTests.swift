import Foundation
import XCTest
@testable import ContinuityKit
import ContinuityKitTesting

final class LibraryClientTests: XCTestCase {
    private let base = URL(string: "http://host.local:8080")!

    func testAuthenticateSignsNonceAndReturnsToken() async throws {
        let transport = MockTransport()
        let identity = ContinuityPeerIdentity(name: "Browser")
        let start = ContinuityLibraryMessages.AuthStartResponse(
            authId: "a1", serverId: "srv", nonce: Data([1, 2, 3]))
        transport.setResponse(
            method: "POST", path: ContinuityRoutes.libraryAuthStart,
            response: ContinuityResponse(status: 200, body: try JSONEncoder().encode(start)))
        transport.setResponse(
            method: "POST", path: ContinuityRoutes.libraryAuthComplete,
            response: ContinuityResponse(status: 200, body: try JSONEncoder().encode(
                ContinuityLibraryMessages.LibraryTokenResponse(libraryToken: "tok-123"))))

        let client = ContinuityLibraryClient(transport: transport, approvalPollInterval: 0.01)
        let token = try await client.authenticate(baseURL: base, identity: identity)
        XCTAssertEqual(token, "tok-123")

        // The complete request carried a valid signature over the scripted nonce.
        let completeRequest = transport.recordedRequests.last {
            $0.url.path == ContinuityRoutes.libraryAuthComplete
        }
        let body = try JSONDecoder().decode(
            ContinuityLibraryMessages.AuthCompleteRequest.self,
            from: completeRequest?.body ?? Data())
        XCTAssertEqual(body.peerId, identity.id)
        XCTAssertTrue(ContinuityPairingMath.verifyAuth(
            signature: body.signature, nonce: start.nonce, peerId: identity.id,
            serverId: "srv", publicKey: identity.publicKeyData))
    }

    func testErrorMapping() async throws {
        let transport = MockTransport()
        transport.setResponse(
            method: "POST", path: ContinuityRoutes.libraryAuthStart,
            response: ContinuityResponse(status: 404))
        let client = ContinuityLibraryClient(transport: transport)
        do {
            _ = try await client.authenticate(
                baseURL: base, identity: ContinuityPeerIdentity(name: "B"))
            XCTFail("expected sharingUnavailable")
        } catch let error as ContinuityLibraryClient.LibraryBrowseError {
            XCTAssertEqual(error, .sharingUnavailable)
        }
    }

    func testRequestPullReturnsManifest() async throws {
        let transport = MockTransport()
        let manifest = ContinuityManifest(
            sessionId: "pull-1", mintedAt: Date(),
            sourceDevice: SourceDevice(name: "Host", platform: "tvOS", appVersion: "1.0"),
            game: GameIdentity(md5Hash: "abc", displayName: "Ikaruga", platform: "dreamcast"))
        transport.setResponse(
            method: "POST", path: ContinuityRoutes.libraryPull,
            response: ContinuityResponse(status: 200, body: try manifest.encoded()))

        let client = ContinuityLibraryClient(transport: transport)
        let fetched = try await client.requestPull(baseURL: base, gameId: "abc", token: "tok")
        XCTAssertEqual(fetched.sessionId, "pull-1")

        let request = transport.recordedRequests.last { $0.url.path == ContinuityRoutes.libraryPull }
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.headers["Authorization"], "Bearer tok")
        let body = try JSONDecoder().decode(
            ContinuityLibraryMessages.PullRequest.self, from: request?.body ?? Data())
        XCTAssertEqual(body.gameId, "abc")
    }

    /// P3: an Ask-Per-Game host answers 202 while its owner decides — the
    /// client polls through to the eventual manifest.
    func testRequestPullPollsThroughConsentWindow() async throws {
        let transport = MockTransport()
        let manifest = ContinuityManifest(
            sessionId: "pull-2", mintedAt: Date(),
            sourceDevice: SourceDevice(name: "Host", platform: "tvOS", appVersion: "1.0"),
            game: GameIdentity(md5Hash: "abc", displayName: "Ikaruga", platform: "dreamcast"))
        transport.setResponse(
            method: "POST", path: ContinuityRoutes.libraryPull,
            response: ContinuityResponse(status: 202))
        let approvedBody = try manifest.encoded()
        // Approve after a few polls, like the host owner tapping Allow.
        Task {
            try await Task.sleep(nanoseconds: 50_000_000)
            transport.setResponse(
                method: "POST", path: ContinuityRoutes.libraryPull,
                response: ContinuityResponse(status: 200, body: approvedBody))
        }

        let client = ContinuityLibraryClient(transport: transport, approvalPollInterval: 0.01)
        let fetched = try await client.requestPull(baseURL: base, gameId: "abc", token: "tok")
        XCTAssertEqual(fetched.sessionId, "pull-2")
        // It actually polled: more than one pull POST was recorded.
        let polls = transport.recordedRequests.filter { $0.url.path == ContinuityRoutes.libraryPull }
        XCTAssertGreaterThan(polls.count, 1)
    }

    /// P3: a per-pull decline is `.pullDeclined`, distinct from the browse
    /// revocation `.declined`.
    func testRequestPullMaps403ToPullDeclined() async throws {
        let transport = MockTransport()
        transport.setResponse(
            method: "POST", path: ContinuityRoutes.libraryPull,
            response: ContinuityResponse(status: 403))
        let client = ContinuityLibraryClient(transport: transport)
        do {
            _ = try await client.requestPull(baseURL: base, gameId: "abc", token: "tok")
            XCTFail("expected pullDeclined")
        } catch let error as ContinuityLibraryClient.LibraryBrowseError {
            XCTAssertEqual(error, .pullDeclined)
        }
    }

    func testRequestPullMaps429ToHostLimit() async throws {
        let transport = MockTransport()
        transport.setResponse(
            method: "POST", path: ContinuityRoutes.libraryPull,
            response: ContinuityResponse(status: 429))
        let client = ContinuityLibraryClient(transport: transport)
        do {
            _ = try await client.requestPull(baseURL: base, gameId: "abc", token: "tok")
            XCTFail("expected hostLimitReached")
        } catch let error as ContinuityLibraryClient.LibraryBrowseError {
            XCTAssertEqual(error, .hostLimitReached)
        }
    }

    func testLibraryFileURLCarriesPathQuery() {
        let url = ContinuityRoutes.libraryFileURL(base: base, relativePath: "ROMs/a b.cdi")
        XCTAssertEqual(url.path, ContinuityRoutes.libraryFile)
        XCTAssertTrue(url.query?.contains("path=") == true)
    }

    func testFetchManifestAndArtCarryBearerToken() async throws {
        let transport = MockTransport()
        let manifest = ContinuityLibraryManifest(peerId: "h", deviceName: "Host", games: [])
        transport.setResponse(
            method: "GET", path: ContinuityRoutes.libraryManifest,
            response: ContinuityResponse(status: 200, body: try manifest.encoded()))
        transport.setResponse(
            method: "GET", path: ContinuityRoutes.libraryArt,
            response: ContinuityResponse(status: 200, body: Data([9, 9])))

        let client = ContinuityLibraryClient(transport: transport)
        let fetched = try await client.fetchManifest(baseURL: base, token: "tok")
        XCTAssertEqual(fetched, manifest)
        let art = try await client.fetchArt(baseURL: base, key: "cover.jpg", token: "tok")
        XCTAssertEqual(art, Data([9, 9]))
        XCTAssertTrue(transport.recordedRequests.allSatisfy {
            $0.method == "POST" || $0.headers["Authorization"] == "Bearer tok"
        })
    }
}
