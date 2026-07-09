import ContinuityKit
import ContinuityKitTesting
import Foundation
import XCTest

final class PullerTests: XCTestCase {
    private var transport: MockTransport!
    private var local: MockFileProvider!
    private var puller: ContinuityPuller!
    private var tempDir: URL!

    private let baseURL = URL(string: "http://ifly.local:8080")!
    private let token = "test-token"

    private let game = GameIdentity(
        flycastGameId: "T-8111N",
        displayName: "Crazy Taxi",
        platform: "dreamcast"
    )

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-puller-tests-\(UUID().uuidString)")
        transport = MockTransport()
        local = MockFileProvider(root: tempDir)
        puller = ContinuityPuller(transport: transport, fileProvider: local)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func descriptor(kind: FileKind, path: String, contents: Data, required: Bool = true) -> FileDescriptor {
        FileDescriptor(
            kind: kind,
            relativePath: path,
            sha256: ContinuityHash.sha256Hex(of: contents),
            size: Int64(contents.count),
            required: required
        )
    }

    private func manifest(saveState: SaveStateDescriptor? = nil, files: [FileDescriptor], bios: [FileDescriptor] = []) -> ContinuityManifest {
        ContinuityManifest(
            sessionId: "s1",
            mintedAt: Date(),
            sourceDevice: SourceDevice(name: "A", platform: "iOS", appVersion: "1.0"),
            game: game,
            saveState: saveState,
            files: files,
            bios: bios
        )
    }

    // MARK: - Manifest fetch

    func testMintAndFetchManifest() async throws {
        let manifest = manifest(files: [])
        transport.setResponse(
            method: "POST",
            path: ContinuityRoutes.mint,
            response: ContinuityResponse(status: 200, body: try manifest.encoded())
        )
        let fetched = try await puller.mintAndFetchManifest(baseURL: baseURL, token: token)
        XCTAssertEqual(fetched.sessionId, "s1")
        let auth = transport.recordedRequests.first?.headers["Authorization"]
        XCTAssertEqual(auth, "Bearer \(token)")
    }

    func testManifestAuthFailureMapsToTokenRejected() async {
        transport.setResponse(
            method: "GET",
            path: ContinuityRoutes.manifest,
            response: ContinuityResponse(status: 401)
        )
        do {
            _ = try await puller.fetchManifest(baseURL: baseURL, token: token)
            XCTFail("expected throw")
        } catch let error as ContinuityError {
            XCTAssertEqual(error, .tokenRejected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Planning

    func testPlanSkipsMatchingLocalFilesAndOrdersByPriority() async throws {
        let stateData = Data("state".utf8)
        let gameData = Data(repeating: 7, count: 4096)
        let vmuData = Data("vmu".utf8)
        let presentData = Data("already-here".utf8)

        // Seed one file locally so it's skipped.
        let present = try local.seedFile(kind: .bios, relativePath: "BIOS/dc_boot.bin", contents: presentData)

        let state = SaveStateDescriptor(
            slot: 18,
            stem: "ct",
            relativePath: "Flycast/ct_18.state",
            sha256: ContinuityHash.sha256Hex(of: stateData),
            size: Int64(stateData.count)
        )
        let gameFile = descriptor(kind: .gameFile, path: "Dreamcast/ct.chd", contents: gameData)
        let vmu = descriptor(kind: .vmuGlobal, path: "Flycast/vmu_save_A1.bin", contents: vmuData)

        let plan = await puller.makePlan(for: manifest(saveState: state, files: [gameFile, vmu], bios: [present]))

        XCTAssertEqual(plan.alreadyPresent, [present])
        // Save state first, then VMU, then the big game file.
        XCTAssertEqual(plan.needed.map(\.kind), [.saveState, .vmuGlobal, .gameFile])
        XCTAssertEqual(plan.totalBytesNeeded, Int64(stateData.count + vmuData.count + gameData.count))
        XCTAssertFalse(plan.isNoOp)
    }

    // MARK: - Execution

    func testHappyPathPullsVerifiesAndPlacesFiles() async throws {
        let stateData = Data("the-save-state".utf8)
        let gameData = Data(repeating: 3, count: 100_000)

        let state = SaveStateDescriptor(
            slot: 18,
            stem: "ct",
            relativePath: "Flycast/ct_18.state",
            sha256: ContinuityHash.sha256Hex(of: stateData),
            size: Int64(stateData.count)
        )
        let gameFile = descriptor(kind: .gameFile, path: "Dreamcast/ct.chd", contents: gameData)

        transport.setDownload(relativePath: state.relativePath, script: .success(stateData))
        transport.setDownload(relativePath: gameFile.relativePath, script: .success(gameData))

        let plan = await puller.makePlan(for: manifest(saveState: state, files: [gameFile]))
        try await puller.execute(plan: plan, baseURL: baseURL, token: token)

        let landedState = try Data(contentsOf: tempDir.appendingPathComponent(state.relativePath))
        let landedGame = try Data(contentsOf: tempDir.appendingPathComponent(gameFile.relativePath))
        XCTAssertEqual(landedState, stateData)
        XCTAssertEqual(landedGame, gameData)
        // No .part leftovers.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent(gameFile.relativePath + ".part").path
        ))
    }

    func testMidDownloadFailureThrowsPullFailureThenResumes() async throws {
        let stateData = Data("the-save-state".utf8)
        let gameData = Data((0..<50_000).map { UInt8($0 % 251) })

        let state = SaveStateDescriptor(
            slot: 18,
            stem: "ct",
            relativePath: "Flycast/ct_18.state",
            sha256: ContinuityHash.sha256Hex(of: stateData),
            size: Int64(stateData.count)
        )
        let gameFile = descriptor(kind: .gameFile, path: "Dreamcast/ct.chd", contents: gameData)

        transport.setDownload(relativePath: state.relativePath, script: .success(stateData))
        transport.setDownload(relativePath: gameFile.relativePath, script: .failAfter(bytes: 20_000, data: gameData))

        let plan = await puller.makePlan(for: manifest(saveState: state, files: [gameFile]))

        // First attempt: state lands, game dies mid-flight.
        do {
            try await puller.execute(plan: plan, baseURL: baseURL, token: token)
            XCTFail("expected PullFailure")
        } catch let failure as PullFailure {
            XCTAssertEqual(failure.underlying, .serverUnreachable(detail: "scripted mid-download failure"))
            XCTAssertEqual(failure.completed.map(\.kind), [.saveState])
            XCTAssertEqual(failure.missing.map(\.kind), [.gameFile])
            let artifacts = failure.pulledArtifacts
            XCTAssertTrue(artifacts.saveStateUsable)
            XCTAssertFalse(artifacts.requiredGameFilesComplete)
        }

        // Partial bytes must be on disk for resume.
        let partial = tempDir.appendingPathComponent(gameFile.relativePath + ".part")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))

        // Second attempt resumes from the partial offset (state now local).
        let retryPlan = await puller.makePlan(for: manifest(saveState: state, files: [gameFile]))
        XCTAssertEqual(retryPlan.needed.map(\.kind), [.gameFile])
        try await puller.execute(plan: retryPlan, baseURL: baseURL, token: token)

        XCTAssertEqual(transport.recordedResumeOffsets.last, 20_000)
        let landed = try Data(contentsOf: tempDir.appendingPathComponent(gameFile.relativePath))
        XCTAssertEqual(landed, gameData)
    }

    func testChecksumMismatchRejectsFile() async throws {
        let realData = Data("real".utf8)
        var corrupt = descriptor(kind: .gameFile, path: "Dreamcast/ct.chd", contents: realData)
        corrupt.sha256 = String(repeating: "0", count: 64)

        transport.setDownload(relativePath: corrupt.relativePath, script: .success(realData))

        let plan = await puller.makePlan(for: manifest(files: [corrupt]))
        do {
            try await puller.execute(plan: plan, baseURL: baseURL, token: token)
            XCTFail("expected PullFailure")
        } catch let failure as PullFailure {
            XCTAssertEqual(failure.underlying, .checksumMismatch(relativePath: corrupt.relativePath))
            XCTAssertTrue(failure.completed.isEmpty)
        }
        // Rejected bytes must not remain on disk in any form.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent(corrupt.relativePath).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent(corrupt.relativePath + ".part").path
        ))
    }

    func testProgressReportsMonotonicallyAndCompletes() async throws {
        let gameData = Data(repeating: 9, count: 200_000)
        let gameFile = descriptor(kind: .gameFile, path: "Dreamcast/ct.chd", contents: gameData)
        transport.setDownload(relativePath: gameFile.relativePath, script: .success(gameData))

        let plan = await puller.makePlan(for: manifest(files: [gameFile]))

        final class ProgressBox: @unchecked Sendable {
            let lock = NSLock()
            var values: [Int64] = []
            func record(_ value: Int64) {
                lock.lock(); defer { lock.unlock() }
                values.append(value)
            }
        }
        let box = ProgressBox()
        try await puller.execute(plan: plan, baseURL: baseURL, token: token) { progress in
            box.record(progress.bytesTransferred)
        }
        XCTAssertFalse(box.values.isEmpty)
        XCTAssertEqual(box.values, box.values.sorted())
    }
}
