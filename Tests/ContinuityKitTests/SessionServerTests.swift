import ContinuityKit
import ContinuityKitTesting
import Foundation
import XCTest

final class SessionServerTests: XCTestCase {
    private var registrar: MockRouteRegistrar!
    private var provider: MockFileProvider!
    private var minter: MockSaveStateMinter!
    private var server: ContinuitySessionServer!
    private var tempDir: URL!

    private let game = GameIdentity(
        flycastGameId: "T-8111N",
        md5Hash: "aabbccdd",
        serial: "T-8111N",
        displayName: "Crazy Taxi",
        platform: "dreamcast"
    )

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-server-tests-\(UUID().uuidString)")
        registrar = MockRouteRegistrar()
        provider = MockFileProvider(root: tempDir)
        minter = MockSaveStateMinter()
        server = ContinuitySessionServer(
            fileProvider: provider,
            minter: minter,
            sourceDevice: SourceDevice(name: "Test", platform: "iOS", appVersion: "1.0")
        )
        await server.activate(on: registrar)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRegistersAllRoutes() {
        XCTAssertEqual(registrar.registeredRoutes, [
            "GET \(ContinuityRoutes.file)",
            "GET \(ContinuityRoutes.manifest)",
            "POST \(ContinuityRoutes.mint)"
        ])
    }

    func testNoSessionReturns404() async {
        let response = await registrar.invoke(method: "GET", path: ContinuityRoutes.manifest)
        XCTAssertEqual(response?.status, 404)
    }

    func testMissingTokenReturns401() async {
        _ = await server.beginSession(game: game)
        let noAuth = await registrar.invoke(method: "GET", path: ContinuityRoutes.manifest)
        XCTAssertEqual(noAuth?.status, 401)
        let badAuth = await registrar.invoke(
            method: "GET",
            path: ContinuityRoutes.manifest,
            headers: ["Authorization": "Bearer wrong"]
        )
        XCTAssertEqual(badAuth?.status, 401)
    }

    func testManifestWithTokenReturnsPayload() async throws {
        let gameFile = try provider.seedFile(kind: .gameFile, relativePath: "Dreamcast/ct.chd", contents: Data("game".utf8))
        provider.setEnumerated(kind: .gameFile, descriptors: [gameFile])
        let info = await server.beginSession(game: game)

        let response = await registrar.invoke(
            method: "GET",
            path: ContinuityRoutes.manifest,
            headers: ["Authorization": "Bearer \(info.token)"]
        )
        XCTAssertEqual(response?.status, 200)
        guard case .data(let body)? = response?.body else {
            return XCTFail("expected data body")
        }
        let manifest = try ContinuityManifest.decode(from: body)
        XCTAssertEqual(manifest.game, game)
        XCTAssertEqual(manifest.files, [gameFile])
        XCTAssertNil(manifest.saveState)
    }

    func testMintProducesStateAndUpdatedManifest() async throws {
        let state = SaveStateDescriptor(
            slot: 18, stem: "ct", relativePath: "Flycast/ct_18.state", sha256: "1234", size: 10
        )
        minter.descriptor = state
        let info = await server.beginSession(game: game)

        let response = await registrar.invoke(
            method: "POST",
            path: ContinuityRoutes.mint,
            headers: ["Authorization": "Bearer \(info.token)"]
        )
        XCTAssertEqual(response?.status, 200)
        XCTAssertEqual(minter.mintCount, 1)
        guard case .data(let body)? = response?.body else {
            return XCTFail("expected data body")
        }
        let manifest = try ContinuityManifest.decode(from: body)
        XCTAssertEqual(manifest.saveState, state)
    }

    func testFileRouteServesManifestListedFilesOnly() async throws {
        let contents = Data("0123456789".utf8)
        let gameFile = try provider.seedFile(kind: .gameFile, relativePath: "Dreamcast/ct.chd", contents: contents)
        provider.setEnumerated(kind: .gameFile, descriptors: [gameFile])
        let info = await server.beginSession(game: game)
        let auth = ["Authorization": "Bearer \(info.token)"]

        let ok = await registrar.invoke(
            method: "GET",
            path: ContinuityRoutes.file,
            query: ["path": gameFile.relativePath],
            headers: auth
        )
        XCTAssertEqual(ok?.status, 200)
        guard case .file(let url, let offset, let length)? = ok?.body else {
            return XCTFail("expected file body")
        }
        XCTAssertEqual(url.lastPathComponent, "ct.chd")
        XCTAssertEqual(offset, 0)
        XCTAssertNil(length)

        // Not in the manifest → not servable (the manifest is the allowlist).
        let escape = await registrar.invoke(
            method: "GET",
            path: ContinuityRoutes.file,
            query: ["path": "../../etc/passwd"],
            headers: auth
        )
        XCTAssertEqual(escape?.status, 404)

        let missingQuery = await registrar.invoke(method: "GET", path: ContinuityRoutes.file, headers: auth)
        XCTAssertEqual(missingQuery?.status, 400)
    }

    func testFileRouteHonorsRange() async throws {
        let contents = Data("0123456789".utf8)
        let gameFile = try provider.seedFile(kind: .gameFile, relativePath: "Dreamcast/ct.chd", contents: contents)
        provider.setEnumerated(kind: .gameFile, descriptors: [gameFile])
        let info = await server.beginSession(game: game)

        let response = await registrar.invoke(
            method: "GET",
            path: ContinuityRoutes.file,
            query: ["path": gameFile.relativePath],
            headers: ["Authorization": "Bearer \(info.token)", "Range": "bytes=4-"]
        )
        XCTAssertEqual(response?.status, 206)
        XCTAssertEqual(response?.headers["Content-Range"], "bytes 4-9/10")
        guard case .file(_, let offset, let length)? = response?.body else {
            return XCTFail("expected file body")
        }
        XCTAssertEqual(offset, 4)
        XCTAssertEqual(length, 6)

        let unsatisfiable = await registrar.invoke(
            method: "GET",
            path: ContinuityRoutes.file,
            query: ["path": gameFile.relativePath],
            headers: ["Authorization": "Bearer \(info.token)", "Range": "bytes=100-"]
        )
        XCTAssertEqual(unsatisfiable?.status, 416)
    }

    func testEndSessionInvalidatesToken() async {
        let info = await server.beginSession(game: game)
        await server.endSession()
        let response = await registrar.invoke(
            method: "GET",
            path: ContinuityRoutes.manifest,
            headers: ["Authorization": "Bearer \(info.token)"]
        )
        XCTAssertEqual(response?.status, 404)
    }

    func testNewSessionInvalidatesOldToken() async {
        let old = await server.beginSession(game: game)
        _ = await server.beginSession(game: game)
        let response = await registrar.invoke(
            method: "GET",
            path: ContinuityRoutes.manifest,
            headers: ["Authorization": "Bearer \(old.token)"]
        )
        XCTAssertEqual(response?.status, 401)
    }
}
