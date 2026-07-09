import ContinuityKit
import XCTest

final class FallbackMachineTests: XCTestCase {
    private typealias Machine = ContinuityFallbackMachine

    private let missingGameFile = FileDescriptor(
        kind: .gameFile, relativePath: "Dreamcast/game.chd", sha256: "cafe", size: 100
    )
    private let missingVMU = FileDescriptor(
        kind: .vmuGlobal, relativePath: "Flycast/vmu_save_A1.bin", sha256: "beef", size: 128
    )

    // MARK: - Game locally available

    func testStatePulledAndGameLocalProceeds() {
        for stage in Machine.Stage.allCases {
            let outcome = Machine.outcome(
                failedAt: stage,
                error: .serverUnreachable(detail: nil),
                local: .gameAvailable(hasLocalSaveState: false),
                pulled: .init(saveStateUsable: true)
            )
            XCTAssertEqual(outcome, .proceedWithPulledState, "stage \(stage)")
        }
    }

    func testStatePulledWithMissingExtrasProceedsPartial() {
        let outcome = Machine.outcome(
            failedAt: .pulling,
            error: .serverUnreachable(detail: nil),
            local: .gameAvailable(hasLocalSaveState: true),
            pulled: .init(saveStateUsable: true, missing: [missingVMU])
        )
        XCTAssertEqual(outcome, .proceedWithPulledStatePartial(missing: [missingVMU]))
    }

    func testNoStateButLocalStateBootsLatestLocal() {
        let outcome = Machine.outcome(
            failedAt: .minting,
            error: .serverUnreachable(detail: nil),
            local: .gameAvailable(hasLocalSaveState: true),
            pulled: .nothing
        )
        XCTAssertEqual(outcome, .bootWithLatestLocalState)
    }

    func testNoStateNoLocalStateBootsFresh() {
        let outcome = Machine.outcome(
            failedAt: .fetchingManifest,
            error: .serverUnreachable(detail: nil),
            local: .gameAvailable(hasLocalSaveState: false),
            pulled: .nothing
        )
        XCTAssertEqual(outcome, .bootFresh)
    }

    func testAuthAndVersionErrorsStillDegradeToLocalBoot() {
        for error: ContinuityError in [.tokenRejected, .manifestVersionUnsupported(found: 99)] {
            let outcome = Machine.outcome(
                failedAt: .fetchingManifest,
                error: error,
                local: .gameAvailable(hasLocalSaveState: true),
                pulled: .nothing
            )
            XCTAssertEqual(outcome, .bootWithLatestLocalState, "error \(error)")
        }
    }

    func testCorruptStateWithLocalGameFallsBackToLocalState() {
        // Checksum-failed state counts as not pulled (saveStateUsable: false).
        let outcome = Machine.outcome(
            failedAt: .verifying,
            error: .checksumMismatch(relativePath: "Flycast/game_18.state"),
            local: .gameAvailable(hasLocalSaveState: true),
            pulled: .init(saveStateUsable: false)
        )
        XCTAssertEqual(outcome, .bootWithLatestLocalState)
    }

    // MARK: - Game missing locally

    func testGameMissingAndTransferIncompleteFails() {
        let outcome = Machine.outcome(
            failedAt: .pulling,
            error: .serverUnreachable(detail: nil),
            local: .gameMissing,
            pulled: .init(saveStateUsable: true, requiredGameFilesComplete: false, missing: [missingGameFile])
        )
        XCTAssertEqual(outcome, .failed(.insufficientToBoot))
    }

    func testGameMissingButFullyTransferredProceeds() {
        let outcome = Machine.outcome(
            failedAt: .pulling,
            error: .serverUnreachable(detail: nil),
            local: .gameMissing,
            pulled: .init(saveStateUsable: true, requiredGameFilesComplete: true, missing: [missingVMU])
        )
        XCTAssertEqual(outcome, .proceedWithPulledStatePartial(missing: [missingVMU]))
    }

    func testGameMissingFullyTransferredNoStateBootsFresh() {
        let outcome = Machine.outcome(
            failedAt: .pulling,
            error: .serverUnreachable(detail: nil),
            local: .gameMissing,
            pulled: .init(saveStateUsable: false, requiredGameFilesComplete: true)
        )
        XCTAssertEqual(outcome, .bootFresh)
    }

    func testGameMissingNonTransportErrorSurfacesOriginalError() {
        let outcome = Machine.outcome(
            failedAt: .fetchingManifest,
            error: .tokenRejected,
            local: .gameMissing,
            pulled: .nothing
        )
        XCTAssertEqual(outcome, .failed(.tokenRejected))
    }

    func testGameMissingTransportErrorReportsInsufficientToBoot() {
        for error: ContinuityError in [
            .serverUnreachable(detail: "x"),
            .cancelled,
            .checksumMismatch(relativePath: "f")
        ] {
            let outcome = Machine.outcome(
                failedAt: .pulling,
                error: error,
                local: .gameMissing,
                pulled: .nothing
            )
            XCTAssertEqual(outcome, .failed(.insufficientToBoot), "error \(error)")
        }
    }
}
