import Foundation

/// Thrown by ContinuityPuller.execute when a pull dies partway. Carries
/// exactly what ContinuityFallbackMachine needs to pick the fallback rung.
public struct PullFailure: Error, Sendable, Equatable {
    public var underlying: ContinuityError
    /// Descriptors fully downloaded and checksum-verified before the failure.
    public var completed: [FileDescriptor]
    /// Descriptors that never completed (including the failing one).
    public var missing: [FileDescriptor]

    public init(underlying: ContinuityError, completed: [FileDescriptor], missing: [FileDescriptor]) {
        self.underlying = underlying
        self.completed = completed
        self.missing = missing
    }

    public var pulledArtifacts: ContinuityFallbackMachine.PulledArtifacts {
        let saveStateUsable = completed.contains { $0.kind == .saveState }
        let requiredMissing = missing.filter(\.required)
        let gameKinds: Set<FileKind> = [.gameFile, .bios]
        let requiredGameComplete = !requiredMissing.contains { gameKinds.contains($0.kind) }
            && completed.contains { $0.kind == .gameFile }
        return ContinuityFallbackMachine.PulledArtifacts(
            saveStateUsable: saveStateUsable,
            requiredGameFilesComplete: requiredGameComplete,
            missing: requiredMissing
        )
    }
}
