import Foundation
import XCTest
@testable import ContinuityKit

/// LIVE end-to-end against a RUNNING iFly host (typically a simulator
/// reachable over this Mac's loopback). Skipped unless configured via env:
///
///   IFLY_E2E_IDENTITY   path where the test persists/loads its Ed25519
///                       identity JSON (both phases need the same one)
///   IFLY_E2E_SEED_DIR   phase one: the host app container's
///                       `Application Support/Continuity` dir — the test
///                       writes trust+grant seeds for its identity there and
///                       stops. Relaunch the host app (its stores cache at
///                       first load), then run phase two without this var.
///   IFLY_E2E_BASE       phase two: host base URL, e.g. http://127.0.0.1:8000
///   IFLY_E2E_GAME_ID    phase two (optional): manifest Game.id to pull;
///                       defaults to the first game in the browse manifest.
final class LibraryPullLiveE2ETests: XCTestCase {
    private struct PersistedIdentity: Codable {
        var id: String
        var privateKey: Data
    }

    func testLivePullAgainstRunningHost() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let identityPath = env["IFLY_E2E_IDENTITY"] else {
            throw XCTSkip("live E2E not configured (IFLY_E2E_IDENTITY unset)")
        }
        let identityURL = URL(fileURLWithPath: identityPath)
        let identity: ContinuityPeerIdentity
        if let data = try? Data(contentsOf: identityURL),
           let stored = try? JSONDecoder().decode(PersistedIdentity.self, from: data) {
            identity = try ContinuityPeerIdentity(
                id: stored.id, name: "E2E Runner", privateKeyData: stored.privateKey)
        } else {
            let fresh = ContinuityPeerIdentity(name: "E2E Runner")
            let data = try JSONEncoder().encode(
                PersistedIdentity(id: fresh.id, privateKey: fresh.privateKeyData))
            try data.write(to: identityURL)
            identity = fresh
        }

        if let seedDir = env["IFLY_E2E_SEED_DIR"] {
            // Phase one: seed the host's stores for the silent-auth path.
            let dir = URL(fileURLWithPath: seedDir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let trust = FileTrustStore(fileURL: dir.appendingPathComponent("trusted-peers.json"))
            await trust.add(TrustedPeer(
                id: identity.id, name: "E2E Runner", publicKey: identity.publicKeyData))
            let grants = FileLibraryGrantStore(
                fileURL: dir.appendingPathComponent("library-grants.json"))
            await grants.setGrant(.everything, forPeerId: identity.id)
            print("E2E: seeded \(dir.path) for peer \(identity.id)")
            return
        }

        guard let base = env["IFLY_E2E_BASE"].flatMap(URL.init(string:)) else {
            throw XCTSkip("live E2E pull phase not configured (IFLY_E2E_BASE unset)")
        }

        let transport = URLSessionContinuityTransport()
        let client = ContinuityLibraryClient(transport: transport)
        let token = try await client.authenticate(baseURL: base, identity: identity)

        let gameId: String
        if let explicit = env["IFLY_E2E_GAME_ID"] {
            gameId = explicit
        } else {
            let browse = try await client.fetchManifest(baseURL: base, token: token)
            guard let first = browse.games.first else {
                XCTFail("host shares an empty library — nothing to pull")
                return
            }
            gameId = first.id
        }

        let manifest = try await client.requestPull(baseURL: base, gameId: gameId, token: token)
        XCTAssertFalse(manifest.files.isEmpty, "pull manifest carried no files")

        // Pull into a scratch root via a minimal file provider.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ifly-e2e-\(UUID().uuidString)")
        let provider = ScratchProvider(root: root)
        let puller = ContinuityPuller(transport: transport, fileProvider: provider)
        let plan = await puller.makePlan(for: manifest)
        try await puller.execute(plan: plan, baseURL: base, token: token, fileRoute: .library)

        // Every pulled file must exist and match its manifest hash.
        for descriptor in plan.needed {
            let url = root.appendingPathComponent(descriptor.relativePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), descriptor.relativePath)
            XCTAssertEqual(try ContinuityHash.sha256Hex(ofFileAt: url), descriptor.sha256,
                           descriptor.relativePath)
        }
        print("E2E: pulled \(plan.needed.count) files, \(plan.totalBytesNeeded) bytes → \(root.path)")
    }
}

private struct ScratchProvider: ContinuityFileProviding {
    let root: URL
    func enumerate(kind: FileKind, identity: GameIdentity) async throws -> [FileDescriptor] { [] }
    func fileURL(for descriptor: FileDescriptor) async throws -> URL {
        root.appendingPathComponent(descriptor.relativePath)
    }
    func localStatus(of descriptor: FileDescriptor) async -> LocalFileStatus { .missing }
    func destinationURL(for descriptor: FileDescriptor) async throws -> URL {
        root.appendingPathComponent(descriptor.relativePath)
    }
}
