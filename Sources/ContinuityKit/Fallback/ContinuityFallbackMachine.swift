/// Pure decision table for "the server died / the pull broke — what now?".
/// No I/O, fully deterministic, exhaustively unit-tested.
public enum ContinuityFallbackMachine {
    /// Where in the flow the failure happened.
    public enum Stage: Sendable, Equatable, CaseIterable {
        case fetchingManifest
        case minting
        case pulling
        case verifying
    }

    /// What the receiving device can do on its own.
    public enum LocalCapability: Sendable, Equatable {
        /// Game (all files needed to boot) is available locally.
        case gameAvailable(hasLocalSaveState: Bool)
        case gameMissing
    }

    /// What made it across before the failure.
    public struct PulledArtifacts: Sendable, Equatable {
        /// A save state file arrived AND passed checksum verification. A state
        /// that failed verification counts as not pulled.
        public var saveStateUsable: Bool
        /// Every `required` game + BIOS descriptor arrived and verified.
        public var requiredGameFilesComplete: Bool
        /// Required descriptors that never arrived (or failed verification).
        public var missing: [FileDescriptor]

        public init(saveStateUsable: Bool = false, requiredGameFilesComplete: Bool = false, missing: [FileDescriptor] = []) {
            self.saveStateUsable = saveStateUsable
            self.requiredGameFilesComplete = requiredGameFilesComplete
            self.missing = missing
        }

        public static let nothing = PulledArtifacts()
    }

    /// The ladder: pulled state + bootable game → resume with pulled state;
    /// local game + local state → resume with the latest local state; local
    /// game only → fresh boot; otherwise fail with the triggering error.
    ///
    /// The ladder applies to every error kind — even auth/version failures
    /// degrade to a local boot when one is possible ("if the other device has
    /// the same game, just boot it").
    public static func outcome(
        failedAt stage: Stage,
        error: ContinuityError,
        local: LocalCapability,
        pulled: PulledArtifacts
    ) -> ContinuityOutcome {
        let gameBootable: Bool
        let hasLocalState: Bool
        switch local {
        case .gameAvailable(let hasState):
            gameBootable = true
            hasLocalState = hasState
        case .gameMissing:
            gameBootable = pulled.requiredGameFilesComplete
            hasLocalState = false
        }

        guard gameBootable else {
            // A partial game transfer can never boot; surface the trigger
            // unless it would hide the real problem (nothing to boot).
            switch error {
            case .serverUnreachable, .cancelled, .checksumMismatch:
                return .failed(.insufficientToBoot)
            default:
                return .failed(error)
            }
        }

        if pulled.saveStateUsable {
            return pulled.missing.isEmpty
                ? .proceedWithPulledState
                : .proceedWithPulledStatePartial(missing: pulled.missing)
        }

        return hasLocalState ? .bootWithLatestLocalState : .bootFresh
    }
}
