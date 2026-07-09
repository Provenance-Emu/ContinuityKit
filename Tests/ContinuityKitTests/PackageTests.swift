import ContinuityKit
import ContinuityKitTesting
import Foundation
import XCTest

final class PackageTests: XCTestCase {
    private var sourceProvider: MockFileProvider!
    private var destinationProvider: MockFileProvider!
    private var sourceRoot: URL!
    private var destinationRoot: URL!
    private var packageURL: URL!

    private let game = GameIdentity(
        flycastGameId: "T-8111N",
        md5Hash: "aabbccdd",
        serial: "T-8111N",
        displayName: "Crazy Taxi",
        platform: "dreamcast"
    )
    private let device = SourceDevice(name: "A", platform: "iOS", appVersion: "1.0")

    override func setUp() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-package-tests-\(UUID().uuidString)")
        sourceRoot = base.appendingPathComponent("source")
        destinationRoot = base.appendingPathComponent("destination")
        packageURL = base.appendingPathComponent("game.\(ContinuityPackage.fileExtension)")
        sourceProvider = MockFileProvider(root: sourceRoot)
        destinationProvider = MockFileProvider(root: destinationRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: sourceRoot.deletingLastPathComponent()
        )
    }

    private func seedTypicalGame() throws -> (game: FileDescriptor, vmu: FileDescriptor, state: SaveStateDescriptor) {
        let gameData = Data((0..<60_000).map { UInt8($0 % 251) })
        let vmuData = Data(repeating: 0xAB, count: 4096)
        let stateData = Data("save-state-bytes".utf8)

        let gameFile = try sourceProvider.seedFile(kind: .gameFile, relativePath: "ROMs/ct.chd", contents: gameData)
        let vmu = try sourceProvider.seedFile(kind: .vmuGlobal, relativePath: "Flycast/vmu_save_A1.bin", contents: vmuData)
        let stateFile = try sourceProvider.seedFile(kind: .saveState, relativePath: "Flycast/ct_18.state", contents: stateData)
        sourceProvider.setEnumerated(kind: .gameFile, descriptors: [gameFile])
        sourceProvider.setEnumerated(kind: .vmuGlobal, descriptors: [vmu])

        let state = SaveStateDescriptor(
            slot: 18, stem: "ct", relativePath: stateFile.relativePath,
            sha256: stateFile.sha256, size: stateFile.size
        )
        return (gameFile, vmu, state)
    }

    private func buildManifest(saveState: SaveStateDescriptor?) async throws -> ContinuityManifest {
        try await ContinuityManifestBuilder(fileProvider: sourceProvider, sourceDevice: device)
            .build(game: game, sessionId: "pkg-1", saveState: saveState, includeSaveStateFiles: true)
    }

    func testWriteThenExtractRoundTrip() async throws {
        let seeded = try seedTypicalGame()
        let manifest = try await buildManifest(saveState: seeded.state)

        try await ContinuityPackageWriter(fileProvider: sourceProvider)
            .write(manifest: manifest, to: packageURL)

        // Manifest peek without extraction.
        let peeked = try ContinuityPackageReader.manifest(ofPackageAt: packageURL)
        XCTAssertEqual(peeked.game, game)
        XCTAssertEqual(peeked.saveState, seeded.state)

        let (extractedManifest, result) = try await ContinuityPackageReader(fileProvider: destinationProvider)
            .extract(packageAt: packageURL)
        XCTAssertEqual(extractedManifest, peeked)
        XCTAssertEqual(result.extracted.count, 3)
        XCTAssertTrue(result.missingFromArchive.isEmpty)

        for descriptor in extractedManifest.allDescriptors {
            let landed = destinationRoot.appendingPathComponent(descriptor.relativePath)
            let original = sourceRoot.appendingPathComponent(descriptor.relativePath)
            XCTAssertEqual(
                try Data(contentsOf: landed), try Data(contentsOf: original),
                "content mismatch for \(descriptor.relativePath)"
            )
        }
    }

    func testExtractSkipsFilesAlreadyPresent() async throws {
        let seeded = try seedTypicalGame()
        let manifest = try await buildManifest(saveState: seeded.state)
        try await ContinuityPackageWriter(fileProvider: sourceProvider)
            .write(manifest: manifest, to: packageURL)

        // Pre-seed the destination with an identical game file.
        let gameData = try Data(contentsOf: sourceRoot.appendingPathComponent(seeded.game.relativePath))
        _ = try destinationProvider.seedFile(kind: .gameFile, relativePath: seeded.game.relativePath, contents: gameData)

        let (_, result) = try await ContinuityPackageReader(fileProvider: destinationProvider)
            .extract(packageAt: packageURL)
        XCTAssertEqual(result.skippedExisting, [seeded.game])
        XCTAssertEqual(result.extracted.count, 2)
    }

    func testChecksumMismatchRejectsEntry() async throws {
        let seeded = try seedTypicalGame()
        var manifest = try await buildManifest(saveState: nil)
        // Corrupt the vmu descriptor AFTER writing files so the archived bytes
        // no longer match the manifest.
        try await ContinuityPackageWriter(fileProvider: sourceProvider)
            .write(manifest: manifest, to: packageURL)
        _ = seeded

        manifest.files = manifest.files.map { descriptor in
            var descriptor = descriptor
            if descriptor.kind == .vmuGlobal {
                descriptor.sha256 = String(repeating: "0", count: 64)
            }
            return descriptor
        }
        let tampered = packageURL.deletingLastPathComponent().appendingPathComponent("tampered.iflypkg")
        try await ContinuityPackageWriter(fileProvider: sourceProvider)
            .write(manifest: manifest, to: tampered)

        do {
            _ = try await ContinuityPackageReader(fileProvider: destinationProvider)
                .extract(packageAt: tampered)
            XCTFail("expected checksum failure")
        } catch let error as ContinuityError {
            guard case .checksumMismatch = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testWriterRefusesManifestEntryWithNoSourceFile() async throws {
        let seeded = try seedTypicalGame()
        var manifest = try await buildManifest(saveState: seeded.state)
        // Phantom descriptor: listed in the manifest, no file on disk.
        manifest.files.append(FileDescriptor(
            kind: .vmuGlobal, relativePath: "Flycast/vmu_save_B1.bin",
            sha256: String(repeating: "1", count: 64), size: 128
        ))
        do {
            try await ContinuityPackageWriter(fileProvider: sourceProvider)
                .write(manifest: manifest, to: packageURL)
            XCTFail("writer should fail on a manifest entry with no source file")
        } catch {
            // Expected: no silent partial packages.
        }
    }

    func testGameFilesStoredAccessoriesDeflated() {
        let gameFile = FileDescriptor(kind: .gameFile, relativePath: "ROMs/ct.chd", sha256: "a", size: 1)
        let state = FileDescriptor(kind: .saveState, relativePath: "Flycast/ct.state", sha256: "b", size: 1)
        XCTAssertEqual(ContinuityPackageWriter.compressionMethod(for: gameFile), .none)
        XCTAssertEqual(ContinuityPackageWriter.compressionMethod(for: state), .deflate)
    }
}
