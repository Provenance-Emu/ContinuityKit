import ContinuityKit
import Foundation
import XCTest

final class ManifestCodecTests: XCTestCase {
    private func sampleManifest() -> ContinuityManifest {
        ContinuityManifest(
            sessionId: "session-1",
            mintedAt: Date(timeIntervalSince1970: 1_750_000_000),
            sourceDevice: SourceDevice(name: "Joe's iPhone", platform: "iOS", appVersion: "1.2.0"),
            game: GameIdentity(
                flycastGameId: "T-8111N",
                md5Hash: "aabbccdd",
                serial: "T-8111N",
                displayName: "Crazy Taxi",
                platform: "dreamcast"
            ),
            saveState: SaveStateDescriptor(
                slot: 18,
                stem: "crazytaxi",
                relativePath: "Flycast/crazytaxi_18.state",
                sha256: "1234",
                size: 42,
                screenshotAvailable: true
            ),
            files: [
                FileDescriptor(kind: .gameFile, relativePath: "Dreamcast/crazytaxi.chd", sha256: "cafe", size: 1000),
                FileDescriptor(kind: .vmuGlobal, relativePath: "Flycast/vmu_save_A1.bin", sha256: "beef", size: 128)
            ],
            bios: [
                FileDescriptor(kind: .bios, relativePath: "BIOS/dc_boot.bin", sha256: "f00d", size: 2048)
            ],
            optionalExtras: [
                OptionalExtra(kind: .texturePack, label: "Texture pack", totalSize: 500, fileCount: 3)
            ]
        )
    }

    func testRoundTrip() throws {
        let original = sampleManifest()
        let decoded = try ContinuityManifest.decode(from: original.encoded())
        XCTAssertEqual(original, decoded)
    }

    func testUnsupportedVersionRejected() throws {
        var manifest = sampleManifest()
        manifest.version = 99
        let data = try manifest.encoded()
        XCTAssertThrowsError(try ContinuityManifest.decode(from: data)) { error in
            XCTAssertEqual(error as? ContinuityError, .manifestVersionUnsupported(found: 99))
        }
    }

    func testAllDescriptorsIncludesSaveStateAndBios() {
        let manifest = sampleManifest()
        let all = manifest.allDescriptors
        XCTAssertEqual(all.count, 4)
        XCTAssertTrue(all.contains { $0.kind == .saveState })
        XCTAssertTrue(all.contains { $0.kind == .bios })
        XCTAssertNotNil(manifest.descriptor(forRelativePath: "Flycast/crazytaxi_18.state"))
        XCTAssertNil(manifest.descriptor(forRelativePath: "nope"))
    }
}
