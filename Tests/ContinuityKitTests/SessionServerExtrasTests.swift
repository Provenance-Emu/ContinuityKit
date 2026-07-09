import ContinuityKit
import ContinuityKitTesting
import Foundation
import XCTest

/// Opt-in extras (texture packs) over the network session: summarized by
/// default, inlined when the client asks, and always servable via the file
/// route's superset allowlist.
final class SessionServerExtrasTests: XCTestCase {
    private var registrar: MockRouteRegistrar!
    private var provider: MockFileProvider!
    private var server: ContinuitySessionServer!
    private var tempDir: URL!
    private var token = ""

    private let game = GameIdentity(flycastGameId: "T-8111N", displayName: "Crazy Taxi", platform: "dreamcast")

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-extras-tests-\(UUID().uuidString)")
        registrar = MockRouteRegistrar()
        provider = MockFileProvider(root: tempDir)
        server = ContinuitySessionServer(
            fileProvider: provider,
            minter: MockSaveStateMinter(),
            sourceDevice: SourceDevice(name: "Test", platform: "iOS", appVersion: "1.0")
        )
        await server.activate(on: registrar)

        let texture = try provider.seedFile(
            kind: .texturePack,
            relativePath: "Flycast/textures/T-8111N/abc123.png",
            contents: Data("png-bytes".utf8),
            required: false
        )
        provider.setEnumerated(kind: .texturePack, descriptors: [texture])
        token = await server.beginSession(game: game).token
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func fetchManifest(query: [String: String]) async throws -> ContinuityManifest {
        let response = await registrar.invoke(
            method: "GET",
            path: ContinuityRoutes.manifest,
            query: query,
            headers: ["Authorization": "Bearer \(token)"]
        )
        XCTAssertEqual(response?.status, 200)
        guard case .data(let body)? = response?.body else {
            throw ContinuityError.invalidResponse(status: response?.status ?? -1)
        }
        return try ContinuityManifest.decode(from: body)
    }

    func testDefaultManifestSummarizesTextures() async throws {
        let manifest = try await fetchManifest(query: [:])
        XCTAssertFalse(manifest.files.contains { $0.kind == .texturePack })
        XCTAssertEqual(manifest.optionalExtras.map(\.kind), [.texturePack])
        XCTAssertEqual(manifest.optionalExtras.first?.fileCount, 1)
    }

    func testExtrasQueryInlinesTextureFiles() async throws {
        let manifest = try await fetchManifest(query: ["extras": "texturePack"])
        XCTAssertTrue(manifest.files.contains { $0.kind == .texturePack })
        XCTAssertTrue(manifest.optionalExtras.isEmpty)
    }

    func testTextureFileServableEvenAfterDefaultManifestFetch() async throws {
        // Client fetched the summary manifest first — the allowlist must still
        // cover texture entries (superset), or an opt-in pull would 404.
        _ = try await fetchManifest(query: [:])
        let response = await registrar.invoke(
            method: "GET",
            path: ContinuityRoutes.file,
            query: ["path": "Flycast/textures/T-8111N/abc123.png"],
            headers: ["Authorization": "Bearer \(token)"]
        )
        XCTAssertEqual(response?.status, 200)
    }

    func testExtrasQueryParsing() {
        XCTAssertEqual(ContinuityRoutes.extras(fromQueryValue: "texturePack"), [.texturePack])
        XCTAssertEqual(ContinuityRoutes.extras(fromQueryValue: "texturePack,unknown"), [.texturePack])
        XCTAssertEqual(ContinuityRoutes.extras(fromQueryValue: "vmuAll,texturePack"), [.vmuAll, .texturePack])
        XCTAssertEqual(ContinuityRoutes.extras(fromQueryValue: nil), [])
        XCTAssertEqual(ContinuityRoutes.extras(fromQueryValue: ""), [])

        let url = ContinuityRoutes.manifestURL(base: URL(string: "http://a.local:8080")!, extras: [.texturePack])
        XCTAssertTrue(url.absoluteString.contains("extras=texturePack"))
    }

    // MARK: - All-VMU set

    /// Seeds the session game's own card (required, also visible to `.vmuAll`)
    /// plus another game's card (the opt-in delta).
    private func seedVMUCards() throws {
        let sessionCard = try provider.seedFile(
            kind: .vmuPerGame,
            relativePath: "Flycast/T-8111N_vmu_save_A1.bin",
            contents: Data("session-card".utf8)
        )
        let foreignCard = try provider.seedFile(
            kind: .vmuAll,
            relativePath: "Flycast/T-9502N_vmu_save_A1.bin",
            contents: Data("foreign-card-bytes".utf8),
            required: false
        )
        provider.setEnumerated(kind: .vmuPerGame, descriptors: [sessionCard])
        var sessionCardAsAll = sessionCard
        sessionCardAsAll.kind = .vmuAll
        provider.setEnumerated(kind: .vmuAll, descriptors: [sessionCardAsAll, foreignCard])
    }

    func testDefaultManifestSummarizesAllVMUDelta() async throws {
        try seedVMUCards()
        let manifest = try await fetchManifest(query: [:])
        // The session game's card rides as a required entry, not as vmuAll.
        XCTAssertTrue(manifest.files.contains { $0.kind == .vmuPerGame })
        XCTAssertFalse(manifest.files.contains { $0.kind == .vmuAll })
        // Only the OTHER game's card counts toward the opt-in delta.
        let extra = manifest.optionalExtras.first { $0.kind == .vmuAll }
        XCTAssertEqual(extra?.fileCount, 1)
        XCTAssertEqual(extra?.totalSize, Int64("foreign-card-bytes".utf8.count))
    }

    func testExtrasQueryInlinesAllVMUDelta() async throws {
        try seedVMUCards()
        let manifest = try await fetchManifest(query: ["extras": "vmuAll"])
        let inlined = manifest.files.filter { $0.kind == .vmuAll }
        XCTAssertEqual(inlined.map(\.relativePath), ["Flycast/T-9502N_vmu_save_A1.bin"])
        // Textures weren't requested — still summarized.
        XCTAssertEqual(manifest.optionalExtras.map(\.kind), [.texturePack])
    }

    func testVMUFileServableEvenAfterDefaultManifestFetch() async throws {
        try seedVMUCards()
        _ = try await fetchManifest(query: [:])
        let response = await registrar.invoke(
            method: "GET",
            path: ContinuityRoutes.file,
            query: ["path": "Flycast/T-9502N_vmu_save_A1.bin"],
            headers: ["Authorization": "Bearer \(token)"]
        )
        XCTAssertEqual(response?.status, 200)
    }
}
